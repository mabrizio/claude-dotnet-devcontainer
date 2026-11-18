#Requires -Version 7.4
<#
.SYNOPSIS
    build-image for Windows hosts: build the claude-dotnet-devcontainer image.

.DESCRIPTION
    PowerShell port of the bash `build-image` script. Use this on a WINDOWS host
    (PowerShell 7.4+); on macOS/Linux/WSL use the bash script.

      ./build-image.ps1          reuse cached layers, but always reinstall Claude Code
                                 so the image gets the newest release (seconds)
      ./build-image.ps1 -Full    rebuild every layer and refresh the base image (minutes)

    This is the MAINTAINER-facing half of the tooling: it produces the image from
    .devcontainer/. claude-box-dotnet.ps1 manages containers only.

.PARAMETER Full
    Rebuild from scratch: --no-cache and re-pull the base image. (Env: FULL=1)

.PARAMETER Pull
    Only re-pull the base image, keeping the rest of the cache.

.PARAMETER Tag
    Build tag to use instead of the default. (Env: IMAGE)
#>
param(
    [switch]$Full,
    [switch]$Pull,
    [Alias('t')] [string]$Tag = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'

# Windows hosts only. (CLAUDE_BOX_PS_FORCE=1 bypasses this for development/testing of
# the script itself on another OS; it is not a supported configuration.)
if (-not $IsWindows -and $env:CLAUDE_BOX_PS_FORCE -ne '1') {
    [Console]::Error.WriteLine('This is the Windows (PowerShell) version of build-image.')
    [Console]::Error.WriteLine('On macOS, Linux or WSL use the bash script: ./build-image')
    exit 1
}

$image = if ($Tag) { $Tag } elseif ($env:IMAGE) { $env:IMAGE } else { 'claude-dotnet-devcontainer:latest' }
$doFull = $Full.IsPresent -or -not [string]::IsNullOrEmpty($env:FULL)

$context = Join-Path $PSScriptRoot '.devcontainer'
if (-not (Test-Path -LiteralPath (Join-Path $context 'Dockerfile') -PathType Leaf)) {
    [Console]::Error.WriteLine("ERROR: no Dockerfile at $context")
    exit 1
}

# A changing build arg invalidates the cache from the Claude Code install layer down,
# so the installer re-runs and fetches the latest release while the apt/tool/ssh
# layers above stay cached. The Dockerfile's RUN references the arg directly -
# BuildKit only keys a layer on the ARGs it actually uses.
$bust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$buildArgs = @('--build-arg', "CLAUDE_INSTALL_BUST=$bust")
if ($doFull) {
    Write-Host 'Full rebuild: every layer, plus a fresh base image (this takes a while).'
    $buildArgs += @('--no-cache', '--pull')
}
elseif ($Pull) {
    $buildArgs += '--pull'
}

Write-Host "Building '$image' from $context ..."
& docker build @buildArgs -t $image $context
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Report what actually landed, so an upgrade is verifiable rather than assumed.
$versions = & docker run --rm --entrypoint bash $image -lc 'echo "Claude Code $(claude --version)"; echo ".NET SDK $(dotnet --version)"' 2>$null
if ($LASTEXITCODE -ne 0 -or -not $versions) { $versions = @('unknown') }
Write-Host ''
Write-Host "Built '$image':"
foreach ($line in $versions) { Write-Host "  $line" }
Write-Host 'Existing containers keep running their OLD image until recreated:'
Write-Host '  claude-box-dotnet.ps1 rm <project-dir>; claude-box-dotnet.ps1 start <project-dir>'
