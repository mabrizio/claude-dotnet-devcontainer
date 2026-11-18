#Requires -Version 7.4
<#
.SYNOPSIS
    claude-box-dotnet for Windows hosts: manage the Claude Code .NET dev container for a project.

.DESCRIPTION
    PowerShell port of the bash `claude-box-dotnet` script, with the same commands and behavior.
    Use this on a WINDOWS host (PowerShell 7.4+); on macOS/Linux/WSL use the bash script.

      claude-box-dotnet.ps1 start    [PROJECT_DIR]   create (first time) or start the container
      claude-box-dotnet.ps1 stop     [PROJECT_DIR]   stop the running container
      claude-box-dotnet.ps1 rm       [PROJECT_DIR]   stop and remove the container
      claude-box-dotnet.ps1 shell    [PROJECT_DIR]   open a bash shell inside it
      claude-box-dotnet.ps1 info     [PROJECT_DIR]   show status/details
      claude-box-dotnet.ps1 provider [NAME]          show/set the secrets provider (1password | openssl)
      claude-box-dotnet.ps1 seal token [DIR]         create this project's encrypted Claude Code token
      claude-box-dotnet.ps1 seal ssh-key FILE [DIR | --user]
                                                     create an encrypted Docker-host SSH key

    Manages containers only; the image is built by build-image.ps1.

    Env overrides (same names as the bash script):
      IMAGE, PORT, DB_CONNECTION_STRING, CONTAINER_USER, PROJECT_CODE_NAME, CLAUDE_ORG,
      REMOTE_DOCKER_USER, REMOTE_DOCKER_HOST, GIT_USER_NAME, GIT_USER_EMAIL,
      SECRET_PROVIDER, CLAUDE_TOKEN_OP_REF, DOCKER_SSH_KEY_OP_REF, OP_SERVICE_ACCOUNT_TOKEN,
      DOCKER_SSH_KEY, CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_TOKEN_FILE, DOCKER_SSH_KEY_FILE,
      CLAUDE_SECRETS_PASSPHRASE_FILE, CLAUDE_SECRETS_PASSPHRASE, CLAUDE_BOX_CONFIG_DIR.

    The encrypted secret files are byte-compatible with `openssl enc -aes-256-cbc -pbkdf2
    -iter 600000 -salt` (and so with the bash script), but no openssl is needed here: the
    format is implemented with .NET.
#>
param(
    [Parameter(Position = 0)] [string]$Command = '',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]]$Rest = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'

# Windows hosts only. (CLAUDE_BOX_PS_FORCE=1 bypasses this for development/testing of
# the script itself on another OS; it is not a supported configuration.)
if (-not $IsWindows -and $env:CLAUDE_BOX_PS_FORCE -ne '1') {
    [Console]::Error.WriteLine('This is the Windows (PowerShell) version of claude-box-dotnet.')
    [Console]::Error.WriteLine('On macOS, Linux or WSL use the bash script: ./claude-box-dotnet')
    exit 1
}

# --- small helpers ------------------------------------------------------------

function Write-Err([string]$Message) { [Console]::Error.WriteLine($Message) }

function Stop-Script([string]$Message, [int]$Code = 1) {
    if ($Message) { Write-Err $Message }
    exit $Code
}

# Value of an environment variable, or $Default when it is unset/empty.
function Get-Env([string]$Name, [string]$Default = '') {
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrEmpty($v)) { return $Default }
    return $v
}

# --- configuration -------------------------------------------------------------

$Image = Get-Env 'IMAGE' 'claude-dotnet-devcontainer:latest'
$DbConnectionString = Get-Env 'DB_CONNECTION_STRING' 'Server=host.docker.internal,1433;Database=app;User Id=sa;Password=Your_strong_Passw0rd;TrustServerCertificate=True'
$ContainerUser = Get-Env 'CONTAINER_USER' 'vscode'
$RemoteDockerUser = Get-Env 'REMOTE_DOCKER_USER' 'dockerizer'
$RemoteDockerHost = Get-Env 'REMOTE_DOCKER_HOST' '192.168.122.10'

# Optional namespace for the secret variables (CLAUDE_ORG=acme -> ACME_CLAUDE_TOKEN_OP_REF).
$ClaudeOrg = ((Get-Env 'CLAUDE_ORG').ToUpperInvariant()) -replace '[^A-Z0-9_]', '_'

# Claude's login lives in a named volume, namespaced by org so two organizations never
# share one credentials store. Unset CLAUDE_ORG keeps the original volume name.
$ConfigVolume = 'claude-code-config' + $(if ($ClaudeOrg) { '-' + $ClaudeOrg.ToLowerInvariant() } else { '' })

$BuildScript = Join-Path $PSScriptRoot 'build-image.ps1'

$ConfigDir = Get-Env 'CLAUDE_BOX_CONFIG_DIR' ''
if (-not $ConfigDir) {
    $xdg = Get-Env 'XDG_CONFIG_HOME' ''
    $ConfigDir = Join-Path $(if ($xdg) { $xdg } else { Join-Path $HOME '.config' }) 'claude-box'
}
$ConfigFile = Join-Path $ConfigDir 'config'

# State set by the functions below (initialised so StrictMode is happy).
$Workspace = ''; $Hash = ''; $Name = ''; $ProjectCodeName = ''
$Provider = '1password'
$ClaudeToken = ''
$SshKey = ''
$GitName = ''; $GitEmail = ''
$SecretsPassphrase = ''
$PassphrasePrompted = $false

function Show-Usage([int]$Code = 2) {
    Write-Err @'
Usage: claude-box-dotnet.ps1 <command> [PROJECT_DIR]

Commands:
  start   [DIR]   Create (first time) or start the container for DIR (default: cwd)
  stop    [DIR]   Stop the running container for DIR
  rm      [DIR]   Stop and remove the container for DIR (fresh start next time)
  shell   [DIR]   Open an interactive bash shell inside DIR's container
  info    [DIR]   Show status and details for DIR's container
  provider [NAME] Show, or set, the default secrets provider (1password | openssl)
  seal    token [DIR] | ssh-key FILE [DIR | --user]
                  Create an openssl-compatible encrypted secret file (openssl provider):
                  per project; the SSH key can also be a per-user default (--user)

PROJECT_DIR defaults to the current directory.
'@
    exit $Code
}

# Prefix a variable name with CLAUDE_ORG when one is set.
function Get-OrgVar([string]$VarName) {
    if ($ClaudeOrg) { return "${ClaudeOrg}_$VarName" }
    return $VarName
}

# First non-empty environment variable among the names, or '' if none.
function Get-FirstEnv([string[]]$Names) {
    foreach ($n in $Names) {
        $v = Get-Env $n ''
        if ($v) { return $v }
    }
    return ''
}

function Get-OpServiceToken {
    Get-FirstEnv @((Get-OrgVar '1P_TOKEN'), (Get-OrgVar 'OP_SERVICE_ACCOUNT_TOKEN'), 'OP_SERVICE_ACCOUNT_TOKEN')
}

# --- docker helpers ------------------------------------------------------------

# Run docker, discarding output; $true on exit code 0.
function Test-Docker([string[]]$DockerArgs) {
    & docker @DockerArgs 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# Run docker and return its trimmed stdout, or $null on failure.
function Get-DockerOutput([string[]]$DockerArgs) {
    $out = & docker @DockerArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($out | Out-String).Trim())
}

function Test-ContainerExists { Test-Docker @('container', 'inspect', $Name) }

# Run docker with exact bytes on stdin (no PowerShell newline translation).
# Returns the exit code.
function Invoke-DockerStdin([string[]]$DockerArgs, [string]$InputText) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('docker')
    foreach ($a in $DockerArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($InputText)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $p.WaitForExit()
    [void]$so.Result; [void]$se.Result
    return $p.ExitCode
}

# --- target resolution ----------------------------------------------------------

# Compute Workspace / Hash / Name / ProjectCodeName from an optional directory. The
# container name is deterministic from the project's absolute path
# (claude-dotnet-<dir>-<hash>), so stop/info/rm need no saved state. The hash is 8 hex
# characters of SHA-256 over the (Windows: lower-cased) path.
function Resolve-Target([string]$Dir) {
    $path = if ($Dir) { $Dir } else { (Get-Location).Path }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Stop-Script "ERROR: not a directory: $path"
    }
    $full = (Resolve-Path -LiteralPath $path).ProviderPath
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
    $script:Workspace = $full
    $key = if ($IsWindows) { $full.ToLowerInvariant() } else { $full }
    $sha = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($key))
    $script:Hash = ([System.BitConverter]::ToString($sha).Replace('-', '').ToLowerInvariant()).Substring(0, 8)
    $base = Split-Path -Leaf $full
    if (-not $base) { $base = 'root' }
    # Docker container names allow only [a-zA-Z0-9_.-].
    $safe = $base -replace '[^a-zA-Z0-9_.-]', '-'
    $script:Name = "claude-dotnet-$safe-$($script:Hash)"
    $script:ProjectCodeName = Get-Env 'PROJECT_CODE_NAME' $base
}

# --- secret providers -------------------------------------------------------------
# Secrets come from ONE provider, chosen per user (never per repo):
#   1password  `op read` of an op:// reference (the default)
#   openssl    a file encrypted in openssl's `enc -pbkdf2` format (create it with `seal`)
# Selection: $env:SECRET_PROVIDER, else SECRET_PROVIDER= in the config file, else
# 1password. There is no silent fallback between providers.

# Read KEY from the config file. Plain KEY=VALUE lines, never executed.
function Get-ConfigValue([string]$Key) {
    if (-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)) { return '' }
    $line = Get-Content -LiteralPath $ConfigFile | Where-Object { $_ -like "$Key=*" } | Select-Object -Last 1
    if (-not $line) { return '' }
    return $line.Substring($Key.Length + 1).Trim()
}

function Initialize-Provider {
    $p = Get-Env 'SECRET_PROVIDER'
    if (-not $p) { $p = Get-ConfigValue 'SECRET_PROVIDER' }
    if (-not $p) { $p = '1password' }
    $p = $p.ToLowerInvariant()
    if ($p -notin @('1password', 'openssl')) {
        Stop-Script "ERROR: unknown SECRET_PROVIDER '$p' (use 1password or openssl)."
    }
    $script:Provider = $p
}

# Read one secret from 1Password. $null if `op` is missing or the read fails.
function Invoke-OpRead([string]$Ref) {
    if (-not (Get-Command op -ErrorAction SilentlyContinue)) { return $null }
    $tok = Get-OpServiceToken
    $old = $env:OP_SERVICE_ACCOUNT_TOKEN
    try {
        if ($tok) { $env:OP_SERVICE_ACCOUNT_TOKEN = $tok }
        $out = & op read $Ref 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (($out | Out-String).TrimEnd("`r", "`n"))
    }
    finally { $env:OP_SERVICE_ACCOUNT_TOKEN = $old }
}

# Each project has its own Claude Code token (several Claude accounts can coexist),
# kept OUTSIDE the project directory: the project is bind-mounted into the container,
# so a file there would be visible to it. Keyed by the container name.
function Get-ProjectSecretDir { Join-Path (Join-Path $ConfigDir 'projects') $Name }

# The token file for the current project; CLAUDE_TOKEN_FILE (also CLAUDE_ORG-prefixed)
# is an explicit path override.
function Get-TokenFile {
    $f = Get-FirstEnv @((Get-OrgVar 'CLAUDE_TOKEN_FILE'), 'CLAUDE_TOKEN_FILE')
    if (-not $f) { $f = Join-Path (Get-ProjectSecretDir) 'claude-token.enc' }
    return $f
}

# The Docker-host SSH key: per project first, then a per-user default.
function Get-SshKeyProjectFile { Join-Path (Get-ProjectSecretDir) 'docker-ssh-key.enc' }
function Get-SshKeyUserFile { Join-Path $ConfigDir 'docker-ssh-key.enc' }
function Get-SshKeyFile {
    $f = Get-FirstEnv @((Get-OrgVar 'DOCKER_SSH_KEY_FILE'), 'DOCKER_SSH_KEY_FILE')
    if (-not $f) {
        $f = Get-SshKeyProjectFile
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { $f = Get-SshKeyUserFile }
    }
    return $f
}

function Get-FullPathSafe([string]$P) { [System.IO.Path]::GetFullPath($P) }

# Other projects' token files.
function Get-OtherTokenFiles {
    $own = Get-FullPathSafe (Get-TokenFile)
    $root = Join-Path $ConfigDir 'projects'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $found = foreach ($d in Get-ChildItem -LiteralPath $root -Directory) {
        $f = Join-Path $d.FullName 'claude-token.enc'
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and ((Get-FullPathSafe $f) -ne $own)) { $f }
    }
    return @($found)
}

# Remember which directory a project's secret dir belongs to, so "copy from another
# project" can show something readable.
function Save-WorkspaceNote([string]$File) {
    $projects = Get-FullPathSafe (Join-Path $ConfigDir 'projects')
    $full = Get-FullPathSafe $File
    if ($full.StartsWith($projects, [System.StringComparison]::OrdinalIgnoreCase)) {
        Set-Content -LiteralPath (Join-Path (Split-Path -Parent $full) 'workspace') -Value $Workspace
    }
}

function Set-PrivateMode([string]$Path, [switch]$Directory) {
    if ($IsWindows) { return }   # the user-profile ACL already restricts access
    $mode = if ($Directory) { 'UserRead, UserWrite, UserExecute' } else { 'UserRead, UserWrite' }
    try { [System.IO.File]::SetUnixFileMode($Path, [System.IO.UnixFileMode]$mode) } catch { }
}

# --- prompts ------------------------------------------------------------------------

function Test-Interactive { -not [Console]::IsInputRedirected }

# Prompt on the terminal; returns the reply or $null when there is no terminal.
# Whitespace is left for the caller to strip. Read-Host appends ": ".
function Read-Prompt([string]$Prompt, [switch]$Hidden) {
    if (-not (Test-Interactive)) {
        Write-Err "ERROR: no terminal available to prompt for: $Prompt"
        return $null
    }
    if ($Hidden) {
        $ss = Read-Host -Prompt $Prompt -AsSecureString
        if ($null -eq $ss) { return $null }
        return [System.Net.NetworkCredential]::new('', $ss).Password
    }
    return Read-Host -Prompt $Prompt
}

# The passphrase for the encrypted files, asked for ONCE per command and reused.
# Non-interactive override: CLAUDE_SECRETS_PASSPHRASE_FILE, then CLAUDE_SECRETS_PASSPHRASE.
function Get-Passphrase {
    if ($script:SecretsPassphrase) { return $true }
    $pf = Get-Env 'CLAUDE_SECRETS_PASSPHRASE_FILE'
    if ($pf) {
        $first = Get-Content -LiteralPath $pf -TotalCount 1 -ErrorAction SilentlyContinue
        $script:SecretsPassphrase = if ($first) { ([string]$first).TrimEnd("`r") } else { '' }
    }
    elseif (Get-Env 'CLAUDE_SECRETS_PASSPHRASE') {
        $script:SecretsPassphrase = Get-Env 'CLAUDE_SECRETS_PASSPHRASE'
    }
    else {
        $p = Read-Prompt 'Passphrase for the encrypted secrets' -Hidden
        if ($null -eq $p) { return $false }
        $script:SecretsPassphrase = $p
        $script:PassphrasePrompted = $true
    }
    return [bool]$script:SecretsPassphrase
}

# --- encryption (openssl `enc -aes-256-cbc -pbkdf2 -iter 600000 -salt` format) -----
# File layout: "Salted__" + 8-byte salt + AES-256-CBC(PKCS7) ciphertext. Key (32 bytes)
# and IV (16 bytes) come from PBKDF2-HMAC-SHA256(passphrase, salt, 600000 iterations).

$SaltedMagic = [System.Text.Encoding]::ASCII.GetBytes('Salted__')
$Pbkdf2Iterations = 600000

function New-AesFromPassphrase([string]$Pass, [byte[]]$Salt) {
    $dk = [System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
        [System.Text.Encoding]::UTF8.GetBytes($Pass), $Salt, $Pbkdf2Iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256, 48)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [byte[]]$dk[0..31]
    $aes.IV = [byte[]]$dk[32..47]
    return $aes
}

function Protect-Text([string]$Plain, [string]$Pass) {
    $salt = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(8)
    $aes = New-AesFromPassphrase $Pass $salt
    try {
        $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
        $enc = $aes.CreateEncryptor().TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    }
    finally { $aes.Dispose() }
    return [byte[]]($SaltedMagic + $salt + $enc)
}

# Decrypt; $null on a bad header, wrong passphrase or corrupt data.
function Unprotect-Bytes([byte[]]$Data, [string]$Pass) {
    if ($Data.Length -lt 32) { return $null }
    for ($i = 0; $i -lt 8; $i++) { if ($Data[$i] -ne $SaltedMagic[$i]) { return $null } }
    $salt = [byte[]]$Data[8..15]
    $cipher = [byte[]]$Data[16..($Data.Length - 1)]
    $aes = New-AesFromPassphrase $Pass $salt
    try {
        $plain = $aes.CreateDecryptor().TransformFinalBlock($cipher, 0, $cipher.Length)
        return [System.Text.UTF8Encoding]::new($false, $true).GetString($plain)
    }
    catch { return $null }
    finally { $aes.Dispose() }
}

# Decrypt a file and return the text, or $null. A passphrase typed at the prompt gets
# 3 tries; one from a file/variable, 1.
function Read-EncryptedFile([string]$File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($File)
    $tries = 0
    while ($true) {
        if (-not (Get-Passphrase)) { return $null }
        $tries++
        $plain = Unprotect-Bytes $bytes $script:SecretsPassphrase
        if ($null -ne $plain) { return $plain }
        $script:SecretsPassphrase = ''
        if ($script:PassphrasePrompted -and $tries -lt 3) {
            Write-Err "Wrong passphrase for $(Split-Path -Leaf $File); try again."
        }
        else { return $null }
    }
}

# --- token and SSH key resolution ---------------------------------------------------

# Offered when a project has no token and we are creating its container (the token is
# REQUIRED): copy another project's token file or enter a new one. $true only when a
# token file now exists for this project.
function Invoke-OfferTokenSetup {
    $target = Get-TokenFile
    if (-not (Test-Interactive)) {
        Write-Err 'No Claude Code token is stored for this project; store one with:'
        Write-Err "  claude-box-dotnet.ps1 seal token `"$Workspace`""
        return $false
    }
    $files = @(Get-OtherTokenFiles)
    $labels = @(foreach ($f in $files) {
            $note = Join-Path (Split-Path -Parent $f) 'workspace'
            if (Test-Path -LiteralPath $note) { (Get-Content -LiteralPath $note -TotalCount 1) } else { Split-Path -Leaf (Split-Path -Parent $f) }
        })
    while ($true) {
        Write-Err "No Claude Code token is stored for this project ($Workspace); one is required."
        for ($i = 0; $i -lt $files.Count; $i++) { Write-Err "  [$($i + 1)] copy the token from $($labels[$i])" }
        Write-Err '  [s] enter a new token for this project'
        Write-Err '  [q] cancel'
        $choice = Read-Prompt 'Choice'
        if ($null -eq $choice) { return $false }
        if ($choice -in @('s', 'S')) {
            return ((Invoke-Seal @('token', $Workspace)) -eq 0)
        }
        if ($choice -in @('q', 'Q')) { return $false }
        $n = 0
        if ([int]::TryParse($choice, [ref]$n) -and $n -ge 1 -and $n -le $files.Count) {
            $dir = Split-Path -Parent $target
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            Copy-Item -LiteralPath $files[$n - 1] -Destination $target -Force
            Set-PrivateMode $target
            Save-WorkspaceNote $target
            Write-Err "Copied the token from $($labels[$n - 1])."
            return (Test-Path -LiteralPath $target -PathType Leaf)
        }
        Write-Err 'Unrecognized choice.'
    }
}

# Resolve the long-lived Claude Code OAuth token into $ClaudeToken. It is REQUIRED;
# `start` refuses to create a container without it. Precedence, most specific first:
#   1. an org-scoped / per-project source (${CLAUDE_ORG}_CLAUDE_TOKEN_OP_REF, or the
#      project's token file) - deliberate, so it outranks the ambient environment;
#   2. CLAUDE_CODE_OAUTH_TOKEN already exported;
#   3. the unprefixed source (CLAUDE_TOKEN_OP_REF).
function Resolve-Token {
    $ambient = Get-Env 'CLAUDE_CODE_OAUTH_TOKEN'
    $src = ''; $orgSrc = ''
    $script:ClaudeToken = ''

    if ($Provider -eq 'openssl') {
        $src = Get-TokenFile
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            $src = ''
            # Only worth asking when we are about to create the container (the only
            # time the token is used) and nothing else supplies one.
            if (-not $ambient -and -not (Test-ContainerExists) -and (Invoke-OfferTokenSetup)) {
                $src = Get-TokenFile
            }
        }
        $orgSrc = $src
    }
    else {
        if ($ClaudeOrg) { $orgSrc = Get-FirstEnv @((Get-OrgVar 'CLAUDE_TOKEN_OP_REF')) }
        $src = $orgSrc
        if (-not $src) { $src = Get-FirstEnv @('CLAUDE_TOKEN_OP_REF') }
    }

    if ($orgSrc -and $ambient) {
        Write-Host 'NOTE: CLAUDE_CODE_OAUTH_TOKEN is already exported, but'
        Write-Host "      a more specific token is configured for this project ($src) -"
        Write-Host '      using that one.'
    }
    elseif ($ambient) {
        Write-Host 'Using the Claude token already exported as CLAUDE_CODE_OAUTH_TOKEN.'
        $script:ClaudeToken = $ambient
        return
    }

    if (-not $src) { return }

    if ($Provider -eq 'openssl') {
        $plain = Read-EncryptedFile $src
        $tok = if ($null -ne $plain) { $plain -replace '\s', '' } else { '' }
        if (-not $tok) {
            Write-Err "WARNING: could not decrypt $src (wrong passphrase?)."
            return
        }
        $script:ClaudeToken = $tok
        Write-Host "Resolved Claude token from the encrypted file ($src)."
        return
    }

    if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        Write-Err "WARNING: a Claude token reference is set but the 'op' CLI isn't installed."
        return
    }
    $tok = Invoke-OpRead $src
    if (-not $tok) {
        Write-Err "WARNING: could not read $src from 1Password."
        return
    }
    $script:ClaudeToken = $tok
    Write-Host "Resolved Claude token from 1Password ($src)."
}

# Resolve the SSH private key that reaches the remote Docker VM into $SshKey. Optional:
# without it the remote Docker host is just unavailable for automated testing.
# DOCKER_SSH_KEY set directly skips the provider.
function Resolve-SshKey {
    $script:SshKey = Get-Env 'DOCKER_SSH_KEY'
    if ($script:SshKey) { return }

    if ($Provider -eq 'openssl') {
        $ref = Get-SshKeyFile
        if (-not (Test-Path -LiteralPath $ref -PathType Leaf)) { return }
        $plain = Read-EncryptedFile $ref
        if (-not $plain) {
            Write-Err "WARNING: could not decrypt $ref (wrong passphrase?)."
            return
        }
        $script:SshKey = $plain
        Write-Host "Resolved remote-Docker SSH key from the encrypted file ($ref)."
        return
    }

    $ref = Get-FirstEnv @((Get-OrgVar 'DOCKER_SSH_KEY_OP_REF'), 'DOCKER_SSH_KEY_OP_REF')
    if (-not $ref) { return }
    if (-not (Get-Command op -ErrorAction SilentlyContinue)) {
        Write-Err "WARNING: an SSH key reference is set but the 'op' CLI isn't installed."
        return
    }
    $val = Invoke-OpRead $ref
    if (-not $val) {
        Write-Err "WARNING: could not read $ref from 1Password."
        return
    }
    $script:SshKey = $val
    Write-Host "Resolved remote-Docker SSH key from 1Password ($ref)."
}

# The in-container installer for the SSH key (runs under `bash -c`). Decodes and
# validates into a TEMP file and only moves it into place once ssh-keygen accepts it.
$SshInstallScript = @'
umask 077
mkdir -p ~/.ssh
tmp=~/.ssh/.id_rsa.incoming
trap "rm -f $tmp" EXIT
if [ "$1" = base64 ]; then
  tr -d "[:space:]" | base64 -d > "$tmp" 2>/dev/null || exit 2
else
  cat > "$tmp"
fi
[ -s "$tmp" ] || exit 3
[ "$(tail -c1 "$tmp" | wc -l)" -eq 1 ] || printf "\n" >> "$tmp"
ssh-keygen -l -f "$tmp" >/dev/null 2>&1 || exit 4
mv "$tmp" ~/.ssh/id_rsa
'@ -replace "`r", ''

# Write the resolved key into the RUNNING container over STDIN (not -e, not an
# argument), decoded and validated inside. Idempotent; run on every start.
function Install-SshKey {
    if (-not $script:SshKey) { return }
    $mode = if ($script:SshKey -match '-----BEGIN') { 'raw' } else { 'base64' }
    $keyText = $script:SshKey -replace "`r", ''
    $rc = Invoke-DockerStdin @('exec', '-i', '-u', $ContainerUser, $Name, 'bash', '-c', $SshInstallScript, '_', $mode) $keyText
    if ($rc -ne 0) {
        switch ($rc) {
            2 { Write-Err 'WARNING: the SSH key value did not decode as base64.' }
            3 { Write-Err 'WARNING: the SSH key value was empty after decoding.' }
            4 { Write-Err 'WARNING: the SSH key value is not a valid private key.' }
            default { Write-Err "WARNING: could not install the SSH key into '$Name'." }
        }
        Write-Err "         Any key already in '$Name' was left untouched."
        return
    }
    $fp = Get-DockerOutput @('exec', '-u', $ContainerUser, $Name, 'ssh-keygen', '-l', '-f', "/home/$ContainerUser/.ssh/id_rsa")
    if (-not $fp) { $fp = '?' }
    Write-Host "Installed remote-Docker SSH key into '${Name}': $fp"
}

# Note (not an error) when the container has no usable key.
function Test-SshKeyPresent {
    if (Test-Docker @('exec', '-u', $ContainerUser, $Name, 'test', '-s', "/home/$ContainerUser/.ssh/id_rsa")) { return }
    Write-Err @"

NOTE: no SSH key in '$Name', so the remote Docker host
      (ssh://${RemoteDockerUser}@${RemoteDockerHost}) is not available for
      automated container testing. This is optional; everything else works.
      To enable it, set $(Get-OrgVar 'DOCKER_SSH_KEY_OP_REF') to a 1Password reference,
      or run 'claude-box-dotnet.ps1 seal ssh-key <file>' and 'provider openssl'
      (see the README, "Remote Docker daemon"), or set DOCKER_SSH_KEY, then
      re-run 'claude-box-dotnet.ps1 start'.
"@
}

# --- git identity ------------------------------------------------------------------------

# Mirror the HOST's git identity into the container (identity only, no credentials).
function Resolve-GitIdentity {
    $n = Get-Env 'GIT_USER_NAME'
    if (-not $n) { $n = (& git -C $Workspace config --get user.name 2>$null) }
    $e = Get-Env 'GIT_USER_EMAIL'
    if (-not $e) { $e = (& git -C $Workspace config --get user.email 2>$null) }
    $script:GitName = if ($n) { [string]$n } else { '' }
    $script:GitEmail = if ($e) { [string]$e } else { '' }
}

function Install-GitIdentity {
    if (-not $script:GitName -and -not $script:GitEmail) {
        Write-Err @"
WARNING: no git identity found on the host, so 'git commit' will fail inside
         '$Name'. Set user.name/user.email in your host git config, or set
         GIT_USER_NAME and GIT_USER_EMAIL, then re-run 'claude-box-dotnet.ps1 start'.
"@
        return
    }
    if ($script:GitName) {
        if (-not (Test-Docker @('exec', '-u', $ContainerUser, $Name, 'git', 'config', '--global', 'user.name', $script:GitName))) {
            Write-Err "WARNING: could not set git user.name in '$Name'."
        }
    }
    if ($script:GitEmail) {
        if (-not (Test-Docker @('exec', '-u', $ContainerUser, $Name, 'git', 'config', '--global', 'user.email', $script:GitEmail))) {
            Write-Err "WARNING: could not set git user.email in '$Name'."
        }
    }
    $shownName = if ($script:GitName) { $script:GitName } else { '<unset>' }
    $shownEmail = if ($script:GitEmail) { $script:GitEmail } else { 'unset' }
    Write-Host "Git identity in '${Name}': $shownName <$shownEmail>"
}

# A connection string with its password masked.
function Hide-ConnectionPassword([string]$Conn) {
    $Conn -replace '(?i)(password|pwd)=[^;]*', '$1=***'
}

# The PROJECT_CODE_NAME the container was CREATED with, '' if none.
function Get-ContainerCodeName {
    $env_ = Get-DockerOutput @('inspect', '-f', '{{range .Config.Env}}{{println .}}{{end}}', $Name)
    if (-not $env_) { return '' }
    foreach ($line in ($env_ -split "`n")) {
        if ($line.TrimEnd("`r") -match '^PROJECT_CODE_NAME=(.*)$') { return $Matches[1] }
    }
    return ''
}

# --- commands ----------------------------------------------------------------------------

# Show or set the default secrets provider (per-user config file, outside the repo).
function Invoke-Provider([string]$Want) {
    $want = $Want.ToLowerInvariant()
    if (-not $want) {
        Initialize-Provider
        Write-Host "Secrets provider: $Provider"
        if (Get-Env 'SECRET_PROVIDER') { Write-Host '  (from the SECRET_PROVIDER environment variable)' }
        elseif (Get-ConfigValue 'SECRET_PROVIDER') { Write-Host "  (from $ConfigFile)" }
        else { Write-Host '  (default; set one with: claude-box-dotnet.ps1 provider 1password|openssl)' }
        return
    }
    if ($want -notin @('1password', 'openssl')) { Stop-Script 'ERROR: provider must be 1password or openssl.' 2 }
    New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
    Set-PrivateMode $ConfigDir -Directory
    $keep = @()
    if (Test-Path -LiteralPath $ConfigFile -PathType Leaf) {
        $keep = @(Get-Content -LiteralPath $ConfigFile | Where-Object { $_ -notlike 'SECRET_PROVIDER=*' })
    }
    $tmp = Join-Path $ConfigDir ('.config.' + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $tmp -Value ($keep + "SECRET_PROVIDER=$want")
    Set-PrivateMode $tmp
    Move-Item -LiteralPath $tmp -Destination $ConfigFile -Force
    Write-Host "Default secrets provider set to '$want' ($ConfigFile)."
}

# Create an encrypted secret file for the openssl provider. The secret is never taken
# as an argument (it would land in shell history). Written after a decrypt round-trip
# check. Returns 0 on success (so `start` can call it inline), non-zero otherwise.
#   seal token [DIR]
#   seal ssh-key FILE [DIR | --user]
function Invoke-Seal([string[]]$SealArgs) {
    $kind = if ($SealArgs.Count -gt 0) { $SealArgs[0] } else { '' }
    $arg = if ($SealArgs.Count -gt 1) { $SealArgs[1] } else { '' }
    $dir = ''; $scope = 'project'
    switch ($kind) {
        'token' { $dir = $arg }
        'ssh-key' {
            $dir = if ($SealArgs.Count -gt 2) { $SealArgs[2] } else { '' }
            if ($dir -in @('--user', '-User', '-user')) { $scope = 'user'; $dir = '' }
            if (-not $arg -or -not (Test-Path -LiteralPath $arg -PathType Leaf)) {
                Write-Err 'Usage: claude-box-dotnet.ps1 seal ssh-key <private-key-file> [DIR | --user]'
                return 2
            }
        }
        default {
            Write-Err 'Usage: claude-box-dotnet.ps1 seal token [DIR] | seal ssh-key <private-key-file> [DIR | --user]'
            return 2
        }
    }
    Resolve-Target $dir
    if ($kind -eq 'token') { $target = Get-TokenFile }
    elseif ($scope -eq 'user') { $target = Get-SshKeyUserFile }
    else {
        $target = Get-FirstEnv @((Get-OrgVar 'DOCKER_SSH_KEY_FILE'), 'DOCKER_SSH_KEY_FILE')
        if (-not $target) { $target = Get-SshKeyProjectFile }
    }

    if (Test-Path -LiteralPath $target) {
        $yn = Read-Prompt "$target already exists. Overwrite? [y/N]"
        if ($null -eq $yn) { return 1 }
        if ($yn -notin @('y', 'Y', 'yes')) { Write-Err 'Aborted.'; return 1 }
    }

    if ($kind -eq 'token') {
        $typed = Read-Prompt "Claude Code token for $Workspace (input hidden)" -Hidden
        if ($null -eq $typed) { return 1 }
        $secret = $typed -replace '\s', ''
    }
    else {
        $secret = (Get-Content -LiteralPath $arg -Raw) -replace "`r", ''
    }
    if (-not $secret) { Write-Err 'ERROR: the secret is empty.'; return 1 }

    # `start` asks for ONE passphrase and uses it for every file, so reuse the
    # passphrase of an existing one instead of inventing a new one.
    $targetFull = Get-FullPathSafe $target
    $ref = ''
    foreach ($f in @((Get-SshKeyUserFile), (Get-SshKeyProjectFile), (Get-TokenFile)) + @(Get-OtherTokenFiles)) {
        if ((Test-Path -LiteralPath $f -PathType Leaf) -and ((Get-FullPathSafe $f) -ne $targetFull)) { $ref = $f; break }
    }

    if ((Get-Env 'CLAUDE_SECRETS_PASSPHRASE_FILE') -or (Get-Env 'CLAUDE_SECRETS_PASSPHRASE')) {
        if (-not (Get-Passphrase)) { Write-Err 'ERROR: could not read the passphrase.'; return 1 }
    }
    elseif ($ref) {
        Write-Err "Using the passphrase of the existing $(Split-Path -Leaf $ref) so one prompt unlocks everything."
        if ($null -eq (Read-EncryptedFile $ref)) {
            $yn = Read-Prompt 'That passphrase does not match; use a different one for the new file? [y/N]'
            if ($null -eq $yn) { return 1 }
            if ($yn -notin @('y', 'Y', 'yes')) { Write-Err 'Aborted.'; return 1 }
            $p1 = Read-Prompt 'New passphrase' -Hidden
            $p2 = Read-Prompt 'Repeat passphrase' -Hidden
            if (-not $p1 -or $p1 -ne $p2) { Write-Err 'ERROR: passphrases empty or not matching.'; return 1 }
            $script:SecretsPassphrase = $p1
            Write-Err "NOTE: the files use different passphrases; 'start' will ask for each."
        }
    }
    else {
        $p1 = Read-Prompt 'New passphrase' -Hidden
        if ($null -eq $p1) { return 1 }
        $p2 = Read-Prompt 'Repeat passphrase' -Hidden
        if ($p1 -ne $p2) { Write-Err 'ERROR: passphrases do not match.'; return 1 }
        if (-not $p1) { Write-Err 'ERROR: the passphrase is empty.'; return 1 }
        $script:SecretsPassphrase = $p1
    }

    $targetDir = Split-Path -Parent $targetFull
    New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    Set-PrivateMode $ConfigDir -Directory
    Set-PrivateMode $targetDir -Directory
    $enc = Protect-Text $secret $script:SecretsPassphrase
    $back = Unprotect-Bytes $enc $script:SecretsPassphrase
    if ($back -ne $secret) {
        Write-Err 'ERROR: the encrypted file did not decrypt back to the input; nothing written.'
        return 1
    }
    $tmp = Join-Path $targetDir ('.seal.' + [guid]::NewGuid().ToString('N'))
    [System.IO.File]::WriteAllBytes($tmp, $enc)
    Set-PrivateMode $tmp
    Move-Item -LiteralPath $tmp -Destination $targetFull -Force
    Save-WorkspaceNote $targetFull
    Write-Host "Sealed $kind -> $targetFull"
    Write-Host 'Use it with: claude-box-dotnet.ps1 provider openssl'
    return 0
}

function Invoke-Start([string]$Dir) {
    Resolve-Target $Dir
    Initialize-Provider

    # Secrets (and so the passphrase prompt) are only needed to create the container
    # (token) or to install a missing SSH key. A container that is already running with
    # its key in place needs neither, so don't ask.
    $running = (Get-DockerOutput @('inspect', '-f', '{{.State.Running}}', $Name)) -eq 'true'
    if ($running -and (Test-Docker @('exec', '-u', $ContainerUser, $Name, 'test', '-s', "/home/$ContainerUser/.ssh/id_rsa"))) {
        Write-Host "Container '$Name' is already running with its SSH key; not reading secrets."
        $script:SshKey = ''
        $script:ClaudeToken = ''
    }
    else {
        Resolve-Token
        Resolve-SshKey
    }
    Resolve-GitIdentity

    # Fixed host port if PORT is set, otherwise an auto-assigned one so several
    # projects can run at once without colliding on :8080.
    $portArg = if (Get-Env 'PORT') { @('-p', "$(Get-Env 'PORT'):8080") } else { @('-p', '8080') }

    # This tool runs containers and never builds. A missing image is a hard error.
    if (-not (Test-Docker @('image', 'inspect', $Image))) {
        Stop-Script "ERROR: image '$Image' does not exist. Build it with: $BuildScript"
    }

    # The Claude Code token is REQUIRED to create the container. (An already-created
    # container has its token baked in, so restarting one needs nothing here.)
    if (-not $script:ClaudeToken -and -not (Test-ContainerExists)) {
        Stop-Script @"
ERROR: no Claude Code token, and the container can't be created without one.
       1. On the host run:  claude setup-token   (prints a long-lived token)
       2. Store it, then re-run 'claude-box-dotnet.ps1 start':
            openssl:   claude-box-dotnet.ps1 provider openssl
                       claude-box-dotnet.ps1 seal token "$Workspace"
            1Password: set $(Get-OrgVar 'CLAUDE_TOKEN_OP_REF') to "op://<vault>/<item>/<field>"
            or set CLAUDE_CODE_OAUTH_TOKEN directly.
"@
    }

    if (Test-ContainerExists) {
        # Guard against CLAUDE_ORG drift: the name derives from the path alone, so the
        # same directory under a different org would silently reuse the other org's
        # credentials volume.
        $existingOrg = Get-DockerOutput @('inspect', '-f', '{{index .Config.Labels "claude-box.org"}}', $Name)
        if ($existingOrg -eq '<no value>' -or $null -eq $existingOrg) { $existingOrg = '' }
        if ($existingOrg -ne $ClaudeOrg) {
            $a = if ($existingOrg) { $existingOrg } else { '<none>' }
            $b = if ($ClaudeOrg) { $ClaudeOrg } else { '<none>' }
            Stop-Script @"
ERROR: container '$Name' was created with
       CLAUDE_ORG='$a', but you are running with
       CLAUDE_ORG='$b'. Reusing it would mount the other org's
       Claude credentials. Recreate it for this org:

         claude-box-dotnet.ps1 rm    "$Workspace"
         claude-box-dotnet.ps1 start "$Workspace"
"@
        }
        Write-Host "Reusing existing container '$Name' (starting it)..."
        [void](Test-Docker @('start', $Name))
    }
    else {
        Write-Host "Creating container '$Name' for $Workspace ..."
        $runArgs = @(
            'run', '-d',
            '--name', $Name,
            '--hostname', $Name,
            '--label', "claude-box.org=$ClaudeOrg",
            '--add-host=host.docker.internal:host-gateway',
            '--cap-add=NET_ADMIN', '--cap-add=NET_RAW',
            '-v', "${Workspace}:/workspace",
            '-v', "${ConfigVolume}:/home/$ContainerUser/.claude",
            '-v', "claude-dotnet-sessions-$($script:Hash):/home/$ContainerUser/.claude/projects",
            '-v', "claude-dotnet-bash-history-$($script:Hash):/commandhistory",
            '-v', "claude-nuget-cache:/home/$ContainerUser/.nuget/packages",
            '-v', "claude-pre-commit-cache:/home/$ContainerUser/.cache/pre-commit",
            '-e', "PRE_COMMIT_HOME=/home/$ContainerUser/.cache/pre-commit",
            '-e', "ConnectionStrings__Default=$DbConnectionString",
            '-e', "PROJECT_CODE_NAME=$ProjectCodeName"
        )
        # Only pass the token when we have one: an empty -e still CREATES the variable.
        if ($script:ClaudeToken) { $runArgs += @('-e', "CLAUDE_CODE_OAUTH_TOKEN=$($script:ClaudeToken)") }
        $runArgs += @(
            '-e', "REMOTE_DOCKER_USER=$RemoteDockerUser",
            '-e', "REMOTE_DOCKER_HOST=$RemoteDockerHost",
            '-e', "DOCKER_HOST=ssh://${RemoteDockerUser}@${RemoteDockerHost}"
        )
        $runArgs += $portArg
        $runArgs += $Image
        & docker @runArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { Stop-Script "ERROR: docker run failed for '$Name'." }

        # Fresh named volumes mount as root:root; fix ownership once after create.
        & docker exec -u root $Name chown "${ContainerUser}:${ContainerUser}" `
            "/home/$ContainerUser/.claude/projects" `
            "/home/$ContainerUser/.nuget/packages" `
            "/home/$ContainerUser/.cache/pre-commit"
        if ($LASTEXITCODE -ne 0) { Write-Err 'WARNING: could not fix volume ownership.' }

        # Restore a solution/project now (into the volume caches, nothing leaks into
        # the project). Never abort the start on failure.
        $hasProject = @(Get-ChildItem -LiteralPath $Workspace -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.sln', '.slnx', '.csproj') }).Count -gt 0
        if ($hasProject) {
            Write-Host "Found a solution/project file; running 'dotnet restore' inside the container..."
            & docker exec $Name bash -lc 'if find . -maxdepth 2 -name packages.lock.json | grep -q .; then dotnet restore --locked-mode; else dotnet restore; fi'
            if ($LASTEXITCODE -ne 0) { Write-Host '  (dotnet restore failed - run it yourself after attaching)' }
        }
    }

    # Inject the key on EVERY start: it lives in the container's writable layer.
    Install-SshKey
    Test-SshKeyPresent
    Install-GitIdentity

    $mapped = Get-DockerOutput @('port', $Name, '8080')
    if ($mapped) { $mapped = ($mapped -split "`n")[0].Trim() }
    $actual = Get-ContainerCodeName
    $codeReport = if ($actual) { $actual } else {
        "<none> (prompt shows '$ContainerUser'; 'claude-box-dotnet.ps1 rm' + 'start' applies '$ProjectCodeName')"
    }
    $portShown = if ($mapped) { $mapped } else { '<none>' }
    $orgShown = if ($ClaudeOrg) { $ClaudeOrg } else { '<none>' }

    Write-Host @"

Container '$Name' is running.
  workspace : $Workspace  ->  /workspace
  code name : $codeReport  (shell prompt)
  database  : $(Hide-ConnectionPassword $DbConnectionString)
  port      : $portShown  ->  container :8080
  org       : $orgShown  (Claude credentials volume: $ConfigVolume)

Next:
  1. VS Code -> "Dev Containers: Attach to Running Container" -> $Name
  2. Start a Claude conversation in the extension.

Stop when done:  claude-box-dotnet.ps1 stop $Workspace
"@
}

function Invoke-Stop([string]$Dir) {
    Resolve-Target $Dir
    if (-not (Test-ContainerExists)) { Stop-Script "No container for this project ($Name)." }
    Write-Host "Stopping '$Name' ..."
    [void](Test-Docker @('stop', $Name))
    Write-Host 'Stopped.'
}

function Invoke-Rm([string]$Dir) {
    Resolve-Target $Dir
    if (-not (Test-ContainerExists)) { Stop-Script "No container for this project ($Name)." }
    Write-Host "Removing '$Name' (stopping if running) ..."
    [void](Test-Docker @('rm', '-f', $Name))
    Write-Host "Removed. Next 'claude-box-dotnet.ps1 start' will create a fresh one (picking up any rebuilt image)."
}

function Invoke-Shell([string]$Dir) {
    Resolve-Target $Dir
    if (-not (Test-ContainerExists)) {
        Stop-Script "No container for this project ($Name). Start it with: claude-box-dotnet.ps1 start $Workspace"
    }
    if ((Get-DockerOutput @('inspect', '-f', '{{.State.Running}}', $Name)) -ne 'true') {
        Write-Host "Container '$Name' is stopped; starting it ..."
        [void](Test-Docker @('start', $Name))
    }
    & docker exec -it -w /workspace $Name bash -l
    exit $LASTEXITCODE
}

function Invoke-Info([string]$Dir) {
    Resolve-Target $Dir
    if (-not (Test-ContainerExists)) {
        Write-Host @"
Container   : $Name
Status      : absent (not created)
Workspace   : $Workspace
Start it with:  claude-box-dotnet.ps1 start $Workspace
"@
        return
    }
    $status = Get-DockerOutput @('inspect', '-f', '{{.State.Status}}', $Name); if (-not $status) { $status = 'unknown' }
    $started = Get-DockerOutput @('inspect', '-f', '{{.State.StartedAt}}', $Name)
    $img = Get-DockerOutput @('inspect', '-f', '{{.Config.Image}}', $Name)
    $mapped = Get-DockerOutput @('port', $Name, '8080')
    if ($mapped) { $mapped = ($mapped -split "`n")[0].Trim() }
    $cOrg = Get-DockerOutput @('inspect', '-f', '{{index .Config.Labels "claude-box.org"}}', $Name)
    if ($cOrg -eq '<no value>' -or $null -eq $cOrg) { $cOrg = '' }
    $cCode = Get-ContainerCodeName
    $d = { param($v) if ($v) { $v } else { '<none>' } }
    Write-Host @"
Container   : $Name
Status      : $status (since $started)
Image       : $img
Workspace   : $Workspace  ->  /workspace
Code name   : $(& $d $cCode) (created with; shown in the shell prompt)
Port        : $(& $d $mapped)  ->  container :8080
Org         : $(& $d $cOrg) (created with)
Shell org   : $(& $d $ClaudeOrg) (CLAUDE_ORG in this shell)
"@
}

# --- dispatch -----------------------------------------------------------------------------

if (-not $Command) { Show-Usage 2 }
$first = if ($Rest.Count -gt 0) { $Rest[0] } else { '' }
switch ($Command) {
    'start' { Invoke-Start $first }
    'stop' { Invoke-Stop $first }
    'rm' { Invoke-Rm $first }
    'shell' { Invoke-Shell $first }
    'info' { Invoke-Info $first }
    'provider' { Invoke-Provider $first }
    'seal' {
        $rc = Invoke-Seal $Rest
        exit $rc
    }
    { $_ -in @('-h', '--help', 'help', '-help', '-?') } { Show-Usage 0 }
    default { Write-Err "Unknown command: $Command"; Show-Usage 2 }
}
