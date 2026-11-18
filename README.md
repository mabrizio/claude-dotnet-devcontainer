# Claude Code Dev Container — .NET 10 / ASP.NET Core

A customizable, isolated dev container for running **Claude Code** against a
.NET 10 + ASP.NET Core + SQL Server project. Claude runs *inside* the container, so it
can operate unrestricted (`--dangerously-skip-permissions`) without touching your
host machine. Your repo is bind-mounted, so edits appear live in your editor.

## The idea

The **product here is the container template itself** — a reusable, customizable
dev container that lets you run Claude Code fully unrestricted inside an isolated
Docker container, driven from the VS Code Claude Code extension.

Running Claude unrestricted on your host is risky, and Claude refuses the
unrestricted flag when launched as root. This gives Claude a **non-root sandbox**
where it can install tools and work freely without touching the host, while your
repo stays bind-mounted and live-editable. The **custom image is the point**: you
own the Dockerfile, so you can add any system tools, language runtimes, or CLIs a
project needs.

The .NET 10 (LTS) + ASP.NET Core + SQL Server stack is the *worked example* that ships with
it — a clean starting point — not the end goal.

### Goals

- Run Claude Code unrestricted, safely isolated from the host, connectable from
  the VS Code extension.
- Make the image **easy to customize** — adding tools should be a clean,
  documented one-liner in the Dockerfile (see [Customizing](#customizing)).
- Provide a solid .NET 10 + ASP.NET Core + SQL Server worked example so the container
  is useful out of the box.

## What's in here

```
.
├── .devcontainer/
│   ├── Dockerfile               # the generic image: .NET 10 SDK + tools + Claude Code CLI
│   ├── devcontainer.json        # optional: per-project "Reopen in Container" flow (see below)
│   ├── ssh_config               # SSH client defaults for reaching the remote Docker daemon
│   ├── managed-settings.json    # container-only Claude policy (bypassPermissions)
│   ├── managed-CLAUDE.md        # container-wide rule: Claude takes no attribution/co-author credit
│   ├── local_claude.json        # pre-seeds Claude onboarding/trust so the TUI starts at the prompt
│   ├── inputrc                  # readline history-search on Up/Down
│   └── bash_prompt.sh           # shows the project code name in the shell prompt
├── build-image                  # MAINTAINER: build the image from .devcontainer/
├── claude-box-dotnet               # USERS: run/manage a container per project, then attach
├── build-image.ps1              # Windows (PowerShell 7.4+) port of build-image
├── claude-box-dotnet.ps1        # Windows (PowerShell 7.4+) port of claude-box-dotnet
├── examples/
│   ├── compose.yaml             # sample PROJECT compose (app + SQL Server) to copy into your project
│   ├── .pre-commit-config.yaml  # sample PROJECT pre-commit hooks (dotnet format + guards)
│   └── claude-settings.json     # sample PROJECT .claude/settings.json (format-on-edit hook)
├── CLAUDE.md                    # project context Claude reads automatically
├── HOWTO.md                     # step-by-step usage guide
├── .gitignore
└── README.md
```

No secrets live in this tree. The Docker-host SSH key and the Claude Code token are resolved from
1Password at start time — see [Remote Docker daemon](#remote-docker-daemon).

The **image is generic** — it bundles the .NET 10 SDK and the Claude Code
CLI but no project files. You mount whatever project directory you want at
`/workspace`; that directory holds the solution, `.csproj` files, app code, etc.

## Prerequisites

- Docker (Docker Desktop on macOS/Windows, or Docker Engine on Linux)
- VS Code with the **Dev Containers** extension (the HOWTO's "Set up VS Code" section lists everything,
  including the extensions the image installs for you)
- **C# Dev Kit licensing:** the image asks VS Code to install
  `ms-dotnettools.csdevkit`, which has its own license terms (free for individuals,
  open source and small teams; otherwise it needs a Visual Studio subscription). If
  that doesn't suit you, drop it and keep only the open-source C# extension — see
  [Customizing](#customizing).
- A Claude subscription or Anthropic API access (you sign in on first run)
- A reachable SQL Server instance (external — not managed by this container)
- **Only if you want Docker to work *inside* the container:** a remote Docker
  host reachable over SSH, plus the `op` CLI to fetch its key — see
  [Remote Docker daemon](#remote-docker-daemon). Everything else works without it.

## Quick start

The primary flow: build the generic image once, then run it against any project
directory and attach VS Code to the running container.

1. Clone this repo (it holds the `Dockerfile`, `build-image`, and `claude-box-dotnet`).
2. Build the image once (a few minutes; cached and reused after that):

   ```bash
   ./build-image
   ```

3. Run the helper, pointing it at the project you want to work on:

   ```bash
   ./claude-box-dotnet start /path/to/your/project      # PROJECT_DIR defaults to the current directory
   ```

   This starts a detached container with your project bind-mounted at
   `/workspace`. If the project has a solution or project file, `dotnet restore`
   runs automatically. `claude-box-dotnet` never builds — it errors if the image is missing.
4. In VS Code: **Cmd/Ctrl+Shift+P → Dev Containers: Attach to Running Container**,
   pick `claude-dotnet-<your-project>-<hash>` (the hash is derived from the project's
   absolute path, so same-named folders stay distinct).
5. In the container's integrated terminal, authenticate once, then run unrestricted:

   ```bash
   claude --dangerously-skip-permissions
   ```

   > First login in a container shows a **code** instead of a browser redirect:
   > open the printed URL on your host, then paste the code back into the terminal.

Switch projects anytime by running `./claude-box-dotnet start` against a different
directory — each gets its own container, and they share one Claude login (per org
when `CLAUDE_ORG` is set; see [Namespacing with `CLAUDE_ORG`](#namespacing-with-claude_org)).

The helper takes a subcommand. The container commands take an optional project
directory (default: the current one). `provider` and `seal` act on the project the same
way, and both take `--user` for the per-user default:

| Command | What it does |
| --- | --- |
| `claude-box-dotnet start [DIR]` | Create (first time) or start `DIR`'s container |
| `claude-box-dotnet stop [DIR]` | Stop the running container |
| `claude-box-dotnet rm [DIR]` | Stop and remove it, so the next `start` builds fresh |
| `claude-box-dotnet shell [DIR]` | Open an interactive shell inside it |
| `claude-box-dotnet info [DIR]` | Show status, image, workspace, and mapped port |
| `claude-box-dotnet provider [NAME\|unset] [DIR \| --user]` | Show the effective secrets provider, or set it (`1password` \| `openssl`) for the project; `--user` sets the per-user default instead |
| `claude-box-dotnet seal token [DIR]` | Create the project's openssl-encrypted Claude Code token file (hidden prompt, then a passphrase) |
| `claude-box-dotnet seal ssh-key FILE [DIR\|--user]` | Create the openssl-encrypted Docker-host SSH key file from an existing private key, for the project or as the per-user default |

`provider` and `seal` are explained in [Secrets: 1Password or encrypted
files](#secrets-1password-or-encrypted-files).

## Windows (PowerShell)

On a **Windows** host use the PowerShell ports instead of the bash scripts:
`build-image.ps1` and `claude-box-dotnet.ps1`. They have the same commands and
behavior, and they refuse to run on macOS/Linux/WSL, where you should use the bash
scripts.

**Requirements:** Windows, [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows)
(`pwsh`, not the built-in Windows PowerShell 5.1), Docker Desktop, and `git`. The
1Password CLI (`op`) is only needed if you use the 1Password provider.

```powershell
./build-image.ps1                 # same as ./build-image; options: -Full, -Pull, -Tag NAME
./claude-box-dotnet.ps1 start     # start | stop | rm | shell | info | provider | seal
./claude-box-dotnet.ps1 seal token
./claude-box-dotnet.ps1 seal ssh-key C:\Users\me\.ssh\id_rsa --user
```

Everything in this README that says `claude-box-dotnet <command>` applies; just run it
as `./claude-box-dotnet.ps1 <command>` (or put the repo directory on your `PATH`). A
few Windows-specific points:

- **No openssl needed.** The encrypted secret files use the same format as
  `openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt`, implemented with .NET, so
  `seal` and `start` work without installing openssl. Files made by either script
  can be read by the other.
- **Secrets location:** `%USERPROFILE%\.config\claude-box` (same layout as on Linux/macOS,
  inside your user profile, which Windows already restricts to you).
- **Container names** are `claude-dotnet-<dir>-<8 hex chars>`: a short hash of the
  project path. They are not shared with the bash script's names, so use one set of
  scripts per machine.
- **Execution policy:** if PowerShell refuses to run the scripts, run
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once, or launch them with
  `pwsh -ExecutionPolicy Bypass -File ./claude-box-dotnet.ps1 start`.

## Upgrading Claude Code

The image pins whatever Claude Code version was current when it was built, and
`DISABLE_AUTOUPDATER=1` keeps it there on purpose — no version drift in the middle
of a session. Upgrading is therefore an explicit act:

Building the image is a **separate script**, `build-image`. `claude-box-dotnet` manages
containers and never rebuilds; producing an image is a maintainer task and stays
out of the day-to-day tool.

```bash
./build-image              # newest Claude, cached layers — seconds
./build-image --full       # every layer, fresh base image — minutes
./build-image -t mytag     # build under a different tag
```

It passes a changing `CLAUDE_INSTALL_BUST` build arg, which invalidates the Docker
cache from the Claude install layer down while the apt/tools/ssh layers above it stay
cached, then prints the Claude version that actually landed.

A **running container keeps using the image it was created from**, so building
alone changes nothing. Recreate each container you want moved onto the new image:

```bash
claude-box-dotnet rm    ~/Projects/my-app
claude-box-dotnet start ~/Projects/my-app
```

That's safe — your project files are on the host, and Claude's auth, session, and
shell history live in named volumes that survive. Containers are independent, so
the ones you don't recreate stay on the previous image.

### Without the helpers

`claude-box-dotnet` is a convenience, not a requirement. The equivalent by hand:

```bash
docker build -t claude-dotnet-devcontainer .devcontainer

docker run -d --name claude-dotnet \
  --add-host=host.docker.internal:host-gateway \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -v "$PWD":/workspace \
  -v claude-code-config:/home/vscode/.claude \
  -v claude-dotnet-sessions-mine:/home/vscode/.claude/projects \
  -v claude-dotnet-bash-history-mine:/commandhistory \
  -v claude-nuget-cache:/home/vscode/.nuget/packages \
  -v claude-pre-commit-cache:/home/vscode/.cache/pre-commit \
  -e PRE_COMMIT_HOME=/home/vscode/.cache/pre-commit \
  -e ConnectionStrings__Default="Server=host.docker.internal,1433;Database=app;User Id=sa;Password=Your_strong_Passw0rd;TrustServerCertificate=True" \
  -e PROJECT_CODE_NAME="$(basename "$PWD")" \
  -e DOCKER_HOST="ssh://dockerizer@192.168.122.10" \
  -p 8080 claude-dotnet-devcontainer

# fresh volumes mount as root; Claude runs as vscode and must write there
docker exec -u root claude-dotnet chown vscode:vscode \
  /home/vscode/.claude/projects /home/vscode/.nuget/packages /home/vscode/.cache/pre-commit
```

Two things `claude-box-dotnet` does that this doesn't: it resolves the Claude Code token and
the remote-Docker SSH key from your secrets provider and injects them, so here you would log
in interactively and place `~/.ssh/id_rsa` yourself (mode 600) before `docker`
inside the container can reach the remote daemon.

## How it works

- **Generic image, mounted project.** The image bundles the .NET 10 SDK and the
  Claude Code CLI but **no project files**. Your project dir is bind-mounted at
  `/workspace` at run time, so one image serves many projects and edits appear
  live on the host.
- **Claude Code is baked into the image.** Installed via the official native
  installer (no Node.js) as the `vscode` user, so it lands on `PATH` at
  `~/.local/bin`. (The Dev Containers *feature* only runs under the Dev Containers
  extension, so a plain `docker run` image can't rely on it.)
- **Non-root by design.** The container runs as the `vscode` user — required:
  Claude Code rejects `--dangerously-skip-permissions` when launched as root.
- **Tools install at build time.** The Dockerfile's `RUN` steps run as root, so
  `apt-get`/`dotnet tool` installs have full privileges; at runtime `vscode` still has
  passwordless `sudo` if needed.
- **NuGet cache and build output live outside the mount.** Two things in a .NET
  project can leak between host and container, and the image handles both:
  - *The package cache.* `NUGET_PACKAGES` points at `~/.nuget/packages`, backed by
    the shared named volume `claude-nuget-cache` (it is content-addressed, so
    sharing it across projects is safe). It survives `rm` + `start`, so restores
    after recreating a container are served from the volume, not the network.
  - *`bin/` and `obj/`.* A host-built `obj/project.assets.json` records absolute
    **host** paths and the host's package folder, which breaks restore/build in the
    container (and vice versa). The image sets `ArtifactsPath=/home/vscode/.artifacts`;
    MSBuild reads it from the environment, so **both `bin/` and `obj/`** (including
    `project.assets.json`) go to the container's own filesystem, with no
    `Directory.Build.props` needed. This was checked against a plain
    `dotnet new webapi` + xUnit solution. The honest trade-off: build output is
    ephemeral — it is rebuilt after `claude-box-dotnet rm` — and tools that expect
    `bin/` inside the project (IDE debuggers launched on the host, `dotnet publish`
    output you want to pick up on the host) won't find it there; use
    `dotnet publish -o <dir>` for that. If you'd rather have in-workspace output,
    delete the `ArtifactsPath` line from the Dockerfile's `ENV` block (`bin/` and
    `obj/` are gitignored) and run `dotnet clean` / delete `bin obj` whenever you
    switch between host and container builds.
  `claude-box-dotnet` runs `dotnet restore` for you when the mounted project has a
  solution or project file (`--locked-mode` if a `packages.lock.json` exists).
- **The project stays independent.** The container is only a development
  convenience — it imposes nothing on your project. Nothing in the project's files
  references the container (`ArtifactsPath` and `NUGET_PACKAGES` are set *only* by
  the image's environment). So the same project builds and runs fine **outside**
  the container with plain `dotnet build` / `dotnet run` — on your host, in CI, or
  on a teammate's machine. The container is never a requirement.
- **Claude state persists.** Named volumes hold `~/.claude` (auth, settings) and
  shell history across container recreations, so you don't re-login every time.
- **The prompt names the project.** Every container runs as `vscode` with the
  project at `/workspace`, so the stock prompt looks identical in all of them.
  `claude-box-dotnet start` injects `PROJECT_CODE_NAME` (the project directory's basename)
  and the container's shell puts it where the username was —
  `myproject ➜ /workspace (main) $`. Unset, you get the base image's
  `vscode ➜ …` unchanged, which is what the "Reopen in Container" flow shows.
  Because a container's environment is fixed at creation, an existing container
  needs `claude-box-dotnet rm` + `start` to pick up a new code name; `claude-box-dotnet info`
  prints the one it actually has.
- **Docker inside the container targets a remote daemon.** There's no daemon in
  here — `docker` talks over SSH to a separate host, so containers Claude builds
  never land on your laptop. See [Remote Docker daemon](#remote-docker-daemon).
- **The image holds no secrets.** The Docker-host SSH key and Claude Code token are resolved from
  1Password on the host at start time and injected into the running container.
- **VS Code copies your host `~/.gitconfig` in on attach.** That's the extension's
  own behaviour, not `claude-box-dotnet`. It brings your aliases and pager settings
  along, so **`diff-so-fancy` is installed in the image** — otherwise a
  `core.pager = diff-so-fancy | less …` on your host would point at a missing
  binary in here. It's a self-contained Perl script, so it needs no Node despite
  being distributed via npm, and it's refreshed to the current stable release on
  every `build-image`.
- **Your git identity is mirrored in, but no git credentials are.** `claude-box-dotnet`
  copies your host `user.name`/`user.email` so commits can be made *inside* the
  container; it never puts a key or token for any git host there. Commit in the
  container, review, and push from the host. Override with `GIT_USER_NAME` /
  `GIT_USER_EMAIL`.

## Alternative: per-project Dev Container

If you'd rather use the standard **Dev Containers: Reopen in Container** flow for
a single project, copy `.devcontainer/`, `CLAUDE.md`, and `.gitignore` into that
project root and reopen it in the container. `devcontainer.json` builds the same
image, installs the Claude Code and C# extensions, and runs `dotnet restore` on create
(when a solution or project file exists). Use this
when you want the config versioned alongside one specific project rather than a
shared, mountable image.

> **Docker inside the container does not work in this flow.** The remote-daemon
> SSH key is injected at run time by `claude-box-dotnet start`, and Reopen-in-Container
> has no equivalent hook, so `DOCKER_HOST` is left unset rather than set and
> broken. Everything else — .NET, `dotnet format`, sqlcmd, Claude Code — works normally.
> Use `claude-box-dotnet` if you need Claude to build or run containers.

## Remote Docker daemon

The container runs **no Docker daemon**. It ships only the Docker CLI and the
Compose plugin, with `DOCKER_HOST` pointed at a daemon on a separate machine over
SSH. So when Claude runs `docker build` or `docker compose up` inside the
container, those containers are created **on that remote host**, not on your
laptop.

This is deliberate, and it's what keeps the isolation promise intact. The obvious
alternative — bind-mounting your host's `/var/run/docker.sock` — would hand
anything inside the container root-equivalent access to your host filesystem
(`docker run -v /:/host …`), which is exactly what this project exists to prevent.
A throwaway remote VM absorbs that risk instead.

### What the Docker host is for

The remote Docker host is a machine **you provide** where Claude has a user that is
allowed to run Docker. It is Claude's test bench: while working on your project
inside the container, Claude can use it to:

- `docker build` the project's images and `docker run` them;
- bring up whole stacks with `docker compose up` (app + SQL Server + Redis, message
  brokers, etc.) and run integration or end-to-end tests against them;
- exercise the project's own `Dockerfile` and `compose.yaml` the way CI or
  production would, rather than only running `dotnet run` in the sandbox;
- start throwaway dependencies (databases, mock services) for a test run and tear
  them down afterwards.

Everything it launches runs on that host, not in your dev container and not on your
laptop. Published ports are reachable at the host's address, so Claude (or you)
can hit a stack it started at `http://<REMOTE_DOCKER_HOST>:<port>`.

### The default address is an example — change it

The defaults (`dockerizer@192.168.122.10`) are simply the values of the
environment this template was developed in (a libvirt VM on the default
`192.168.122.0/24` network). **They will not work for you as-is.** Point them at
your own Docker host by setting `REMOTE_DOCKER_USER` and `REMOTE_DOCKER_HOST`
before running `claude-box-dotnet start`:

```bash
export REMOTE_DOCKER_USER=builder
export REMOTE_DOCKER_HOST=docker-vm.example.internal   # hostname or IP
./claude-box-dotnet start ~/Projects/my-app
```

The resulting `DOCKER_HOST` is `ssh://$REMOTE_DOCKER_USER@$REMOTE_DOCKER_HOST`.
Note that `DOCKER_HOST` is fixed when a container is created, so after changing
these run `claude-box-dotnet rm` + `start` for existing containers. (The
"Without the helpers" example above also hard-codes the default; edit it there
too.)

### What the host must provide

- A reachable **Docker Engine** (the daemon, not just the CLI), with a user in the
  `docker` group (or otherwise allowed to use the socket). No root login is needed.
- **SSH access** for that user, via the key described in
  [How the key is handled](#how-the-key-is-handled) — the matching public key must
  be in the user's `authorized_keys`.
- Network reachability from the container to the host on port 22, and from
  wherever you test to the ports your stacks publish.
- Ideally **disposable**: a VM or a dedicated build box. Anything that can reach
  this daemon is effectively root on the host (see
  [Security notes](#security-notes--read-before-using---dangerously-skip-permissions)).

It can be a local VM, a cloud instance, or a shared lab server — whatever you are
comfortable letting Claude run arbitrary containers on. Different projects (or
`CLAUDE_ORG` namespaces) can point at different hosts.

### Configuration

Configure it with these host environment variables (all optional):

| Variable | Default | Purpose |
| --- | --- | --- |
| `REMOTE_DOCKER_USER` | `dockerizer` | SSH user on the Docker host (must be allowed to run Docker) |
| `REMOTE_DOCKER_HOST` | `192.168.122.10` | Address of the Docker host — **the default is specific to the template's dev environment; override it** |
| `DOCKER_SSH_KEY_OP_REF` | *(unset)* | 1Password reference for the SSH **private key**, e.g. `op://Private/dockerizer-ssh/private key` |
| `DOCKER_SSH_KEY` | *(unset)* | The key material directly, bypassing the secrets provider (see [Secrets: 1Password or encrypted files](#secrets-1password-or-encrypted-files)) |
| `OP_SERVICE_ACCOUNT_TOKEN` | *(unset)* | 1Password service-account token, so `op` works non-interactively |

### Namespacing with `CLAUDE_ORG`

Nothing here is tied to a particular company. If you juggle more than one
organization in the same shell and don't want their references colliding, set
`CLAUDE_ORG` and every secret variable gains that prefix:

```bash
export CLAUDE_ORG=acme
export ACME_CLAUDE_TOKEN_OP_REF="op://Acme/Claude Code/credential"
export ACME_DOCKER_SSH_KEY_OP_REF="op://Acme/docker-vm/private key"
export ACME_OP_SERVICE_ACCOUNT_TOKEN="ops_…"
```

Each variable is looked up **prefixed first, then plain** — so with `CLAUDE_ORG` unset
you just use `CLAUDE_TOKEN_OP_REF`, `DOCKER_SSH_KEY_OP_REF`, and
`OP_SERVICE_ACCOUNT_TOKEN`, and with `CLAUDE_ORG` set you can still leave shared values
unprefixed and only override the ones that differ. `CLAUDE_ORG` is upper-cased for you,
so `CLAUDE_ORG=acme` and `CLAUDE_ORG=ACME` behave identically.

For the service-account token the prefixed form may also be spelled
`<CLAUDE_ORG>_1P_TOKEN`, and unprefixed it falls back to `OP_SERVICE_ACCOUNT_TOKEN` —
1Password's own standard variable, so if you already export that for the `op` CLI
this script needs no extra configuration.

#### Keeping Claude logins apart

Picking the right *reference* isn't enough on its own, because Claude persists its
login in `~/.claude`, which is backed by a named volume. So `CLAUDE_ORG` namespaces that
volume too: `claude-code-config-acme` instead of the shared `claude-code-config`.
Without this, an org-scoped token would still be written into — and later read
back out of — one credentials store shared by every container on the machine.

Two further guards:

- **Token precedence is explicit.** An `<CLAUDE_ORG>`-prefixed reference outranks a
  `CLAUDE_CODE_OAUTH_TOKEN` that merely happens to be exported in your shell,
  because naming an org-scoped reference is a deliberate statement about which
  account this project uses. `claude-box-dotnet` prints which source it used, and says so
  when both are present. With no `CLAUDE_ORG` set, an exported token still wins.
- **Org drift is refused.** A container's name derives from the project path
  alone, so starting the same directory under a different `CLAUDE_ORG` would otherwise
  silently reuse the previous org's credentials. Containers are labelled with the
  org that created them, and `claude-box-dotnet start` aborts on a mismatch, telling you
  to `rm` and recreate. `claude-box-dotnet info` shows both the container's org and your
  shell's.

Containers created before this labelling existed have no org recorded; they keep
working as long as `CLAUDE_ORG` is unset, which matches the credentials they already have.

### How the key is handled

The private key is **never committed to this repo and never baked into the
image**. `claude-box-dotnet start` reads it from 1Password on your host (via
`DOCKER_SSH_KEY_OP_REF`, or its `CLAUDE_ORG`-prefixed form) and writes it
into the *running* container over stdin — not via `-e` (which would expose it in
`docker inspect`) and not as an argument (visible in `ps`). It lands at
`~/.ssh/id_rsa` with mode 600, and is re-injected on every `start` so a recreated
container is never left keyless.

The 1Password item holds the private key **base64-encoded**; `claude-box-dotnet` decodes
it inside the container as it writes. A raw PEM key is detected and passed through
unchanged, so `DOCKER_SSH_KEY` can be either form. After writing, the key is
validated with `ssh-keygen -l` and the fingerprint printed — a mis-encoded secret
fails immediately and visibly rather than surfacing later as an opaque SSH
authentication error.

The practical consequences: the image contains no secret, so it can be pulled,
saved, or shared safely; a fresh clone builds with no extra files; and rotating
the key means updating one 1Password item, not rebuilding anything.

If no key is available, `claude-box-dotnet` warns and starts anyway. Everything except
Docker-inside-the-container works fine without it.

### Provisioning a new key

A keypair has **two halves in two places**: the private half in 1Password, and the
public half in the remote host's `authorized_keys`. `claude-box-dotnet` handles the first
and cannot do the second — installing a public key requires access to the host you
don't have yet. That step is one-time, server-side, and manual.

1. **Generate a keypair** on your host, into a temporary location:

   ```bash
   ssh-keygen -t ed25519 -C "claude-box-dotnet docker vm" -f /tmp/newkey -N ""
   ```

2. **Install the public half** on the Docker host, as the user `claude-box-dotnet`
   connects with (`REMOTE_DOCKER_USER`, default `dockerizer`):

   ```bash
   ssh-copy-id -i /tmp/newkey.pub dockerizer@192.168.122.10
   ```

   No `ssh-copy-id`? Append `/tmp/newkey.pub` to `~dockerizer/.ssh/authorized_keys`
   on that host by hand. This needs an existing way in — the current key, console
   access, or your cloud provider's key injection. **Verify it works before
   retiring the old key**, or you can lock yourself out:

   ```bash
   ssh -i /tmp/newkey dockerizer@192.168.122.10 true && echo OK
   ```

3. **Store the private half in 1Password, base64-encoded**, in the item that
   `DOCKER_SSH_KEY_OP_REF` points at:

   ```bash
   base64 -w0 < /tmp/newkey        # Linux
   base64 < /tmp/newkey | tr -d '\n'   # macOS (no -w flag)
   ```

   Paste the single-line output into the item's field.

4. **Shred the local copies** — they've served their purpose:

   ```bash
   shred -u /tmp/newkey /tmp/newkey.pub    # or: rm -f
   ```

5. **Roll it out.** The key is injected on every start, so recreating each
   container picks up the new one:

   ```bash
   claude-box-dotnet rm    ~/Projects/some-app
   claude-box-dotnet start ~/Projects/some-app
   ```

   `start` prints the fingerprint it installed, so you can confirm the new key
   landed. Once every container is on it, remove the old public key from the
   host's `authorized_keys`.

Rotating an existing key is the same process against the same 1Password item —
nothing in this repo or the image needs to change.

## Secrets: 1Password or encrypted files

### The two secrets

- **Claude Code token** (`CLAUDE_CODE_OAUTH_TOKEN`) — **required**. A long-lived
  login token for Claude Code itself, created with `claude setup-token`. The
  container can't be created without it: `claude-box-dotnet start` stops with an
  error explaining how to provide one. It is per project, since you may use several
  Claude accounts.
- **Docker host SSH key** — *optional*. the private key used to connect to a separate host that
  runs OpenSSH and Docker. Containers that Claude builds and runs (to test your
  project, bring up compose stacks, run integration tests) are created **on that
  host**, never on yours; see [Remote Docker daemon](#remote-docker-daemon). If no
  key is defined, that is not a problem: it only means the Docker host isn't
  available for automated testing, and everything else works normally.

### Choosing a provider

Two providers are supported. Each project uses **one** of them (a per-user default
unless the project overrides it), and there is no silent fallback between them. A
`DOCKER_SSH_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` exported directly always wins over
either provider.

| Provider | How secrets are stored | Selected by |
| --- | --- | --- |
| `1password` (default) | `op://` references, read with the `op` CLI | nothing — it is the default |
| `openssl` | files encrypted with `openssl enc` (AES-256-CBC, PBKDF2) in `~/.config/claude-box/` | `claude-box-dotnet provider openssl` |

The provider is chosen the same way the secrets are: per project, with a per-user
default as the fallback. The most specific setting wins:

1. `SECRET_PROVIDER` in the environment (one run only);
2. the **project's** setting, `~/.config/claude-box/projects/<container-name>/config`;
3. the **per-user default**, `~/.config/claude-box/config`;
4. `1password`.

Both files live outside every project and repo (override the directory with
`CLAUDE_BOX_CONFIG_DIR`). One project can use a 1Password token for one Claude
account while another uses an encrypted file for a different account.

Like `seal`, `provider` applies to the **project** by default (the current directory,
or a directory you name), and `--user` selects the per-user default:

```bash
claude-box-dotnet provider                       # effective provider for this project, and where it came from
claude-box-dotnet provider openssl               # set it for THIS project (or: provider openssl ~/Projects/other)
claude-box-dotnet provider unset                 # drop the project's setting (back to the default)
claude-box-dotnet provider openssl --user        # set the per-user default
claude-box-dotnet provider --user                # show the per-user default
claude-box-dotnet provider unset --user          # remove the per-user default (back to 1password)
SECRET_PROVIDER=1password claude-box-dotnet start       # override for one run
```

### Getting the Claude Code token

On the host, run `claude setup-token`. It opens a browser login and prints a
long-lived Claude Code OAuth token (requires a Claude subscription). Store it with either
provider:

- **1Password:** save it in an item and export `CLAUDE_TOKEN_OP_REF`
  (e.g. `op://Private/Claude Code/credential`).
- **openssl:** `claude-box-dotnet seal token` — paste the Claude Code token at the hidden prompt
  (surrounding whitespace and the newline are stripped), then choose a passphrase.

### The openssl provider

```bash
claude-box-dotnet provider openssl
cd ~/Projects/my-app                            # or pass the directory as the last argument
claude-box-dotnet seal token                    # this project's Claude Code token
claude-box-dotnet seal ssh-key ~/.ssh/id_rsa    # this project's Docker-host key
claude-box-dotnet seal ssh-key ~/.ssh/id_rsa --user   # per-user default Docker-host key
```

Where the files go (all under `~/.config/claude-box/`, **outside every project**,
because a project is bind-mounted into the container and a file inside it would be
visible there):

| Secret | Per project | Fallback |
| --- | --- | --- |
| Claude Code token | `projects/<container-name>/claude-token.enc` | none: an account never silently crosses projects |
| Docker-host SSH key | `projects/<container-name>/docker-ssh-key.enc` | `docker-ssh-key.enc` (per user) |

The token is per project because you may work with several Claude accounts. The key
is per project too, with a per-user default for the common case of one Docker host
shared by all your projects.

If a project has no token when `start` creates its container, `start` offers to
**copy the token from another project** (same account) or enter a new one (or cancel).
The token is required, so without one, or without a terminal, `start` stops and prints
what to run.

- `seal` never takes the secret as an argument (it would reach shell history and
  `ps`): the token is typed at a hidden prompt, and the SSH key is read from the file
  you name. The token's surrounding whitespace and newline are stripped. It asks for the passphrase twice, writes the file with mode 600, and
  checks that it decrypts back before keeping it.
- `claude-box-dotnet start` prompts for the passphrase **only when it needs a
  secret**: not when the container is already running with its SSH key. One prompt
  covers both files, and a mistyped passphrase gets 3 tries.
- Use the **same passphrase for both files**. When the other file already exists,
  `seal` asks for its passphrase and reuses it, so you only ever type one. If the
  two differ (you must confirm that), `start` asks for each separately.
- The SSH key file may hold raw PEM (recommended) or base64; both are detected.
- Overrides: `CLAUDE_TOKEN_FILE` / `DOCKER_SSH_KEY_FILE` (also `CLAUDE_ORG`-prefixed)
  set an explicit file path instead of the locations above; `CLAUDE_SECRETS_PASSPHRASE_FILE` or `CLAUDE_SECRETS_PASSPHRASE`
  to skip the prompt in scripts.
- Needs an `openssl` with `-pbkdf2` (OpenSSL 1.1.1+, or LibreSSL 3.1+). `openssl enc`
  is not authenticated, so a wrong passphrase is reported as a failed decrypt and the
  container starts without that secret.
- **Windows hosts:** run `claude-box-dotnet` from WSL2 (recommended) or Git Bash, with
  `openssl` available. Under WSL2 everything above works as on Linux. Under Git Bash
  the config dir is `~/.config/claude-box` in your Windows profile, prompts fall back
  to stdin when there is no `/dev/tty`, and the mode-600 file permissions are best
  effort on NTFS.
- This protects the files at rest. Once decrypted, the values are injected exactly
  as with 1Password. Never commit the `.enc` files (they are gitignored).

## Connecting to your database

The container only needs the `sqlcmd` client (included) and network reachability.

- **DB on your laptop:** `host.docker.internal` resolves to the host (the
  `--add-host` runArg enables this on Linux). The default connection string already
  points there.
- **Remote/hosted DB:** set `DB_CONNECTION_STRING` when starting the container (or
  edit `ConnectionStrings__Default` in `devcontainer.json`). If you enable the
  firewall, add that host to its allowlist.

The string is injected as `ConnectionStrings__Default` — the ASP.NET Core
configuration convention (`__` stands for the `:` section separator), in SqlClient's
key/value format (`Server=host,port;...`). In your app:

```csharp
var cs = builder.Configuration.GetConnectionString("Default");
builder.Services.AddDbContext<AppDbContext>(o => o.UseSqlServer(cs));   // Microsoft.EntityFrameworkCore.SqlServer
```

Test it with `sqlcmd` (it takes its own arguments, not the connection string):
`sqlcmd -S host.docker.internal,1433 -U sa -P 'Your_strong_Passw0rd' -C -Q 'SELECT name FROM sys.databases'`

## Customizing

- **Add system tools:** add an `apt-get install` line to the Dockerfile.
- **Add .NET tools globally:** add a `RUN dotnet tool install --global <pkg>` line
  (they land in `~/.dotnet/tools`, already on `PATH`). `dotnet format` is built into
  the SDK, so it needs no install.
- **Add VS Code extensions:** append to `customizations.vscode.extensions` (both in
  the Dockerfile's `devcontainer.metadata` label and in `devcontainer.json`).
- **Change the .NET version:** change the base image tag in the Dockerfile (e.g.
  `mcr.microsoft.com/devcontainers/dotnet:10.0`) — and the `dotnet --version` check
  right below it, which fails the build if the major isn't 10. In your project, pin
  the SDK with a `global.json` so host, container and CI agree.
- **Dev Kit vs plain C#:** the image installs `ms-dotnettools.csdevkit` (solution
  explorer, test explorer) alongside `ms-dotnettools.csharp`. To avoid the Dev Kit
  license terms, remove `ms-dotnettools.csdevkit` (and the `dotnet.defaultSolution`
  setting) from both lists; you keep the open-source language service.
- **NativeAOT publishing:** uncomment the `clang zlib1g-dev` line in the Dockerfile.

After any change run `./build-image`, then `claude-box-dotnet rm` + `claude-box-dotnet start`
for each container that should pick it up. (In the Reopen-in-Container flow, use
**Dev Containers: Rebuild Container** instead.)

## Security notes — read before using `--dangerously-skip-permissions`

The container protects your **host**, but it is not a vault:

- Claude can modify **any file in the mounted workspace**, including `.env`.
- Git credentials inside the container may allow **pushing to your repos**.
- With the flag set, a malicious repo could **exfiltrate anything reachable
  inside the container**, including Claude's own stored credentials.
- `managed-settings.json` sets `allowManagedPermissionRulesOnly`, which makes
  Claude **ignore every user and project permission rule** — including a project
  `deny`, which nothing else can override. That is the point of the file, but it
  means per-project rules give you no protection in here.
- The **remote Docker SSH key** is injected into the running container, so
  anything inside it can reach that daemon and is effectively root **on the remote
  host**. That host should be disposable, not something you care about.
- **VS Code's attach adds a git credential path that `claude-box-dotnet` does not.**
  Along with copying your `~/.gitconfig`, the Dev Containers extension installs a
  credential-helper that proxies requests back to the host. If you have HTTPS
  credentials stored there, an attached container can obtain them and push to your
  repositories. It returns nothing if you only use SSH remotes, and the
  `IdentitiesOnly` setting in `ssh_config` stops a forwarded SSH agent being used
  for git. If you want no path to your git host at all, turn off the gitconfig
  copy and credential sharing in the Dev Containers extension settings.

Therefore:

- Only run trusted code this way.
- Don't mount host secrets (`~/.ssh`, cloud credential files) into the container.
- Keep the remote Docker host a throwaway. Don't point it at a machine that
  matters, and never at your own Docker socket.
- For unattended runs, add the egress firewall (see below) so a bypassed session
  can only reach domains you've allowed.

## Optional: egress firewall

For hands-off / unattended sessions, add a default-deny firewall. Copy
`init-firewall.sh` from the official reference container
(`anthropics/claude-code/.devcontainer/init-firewall.sh`) into `.devcontainer/`,
keep the `NET_ADMIN`/`NET_RAW` caps already set in `runArgs`, and uncomment the
`postStartCommand` in `devcontainer.json`. Add your DB host, `api.nuget.org` (NuGet also uses other `*.nuget.org` hosts), and
git host to its allowlist.
