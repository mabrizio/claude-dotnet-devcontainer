# HOWTO — Use this container with any project

Step-by-step guide for running Claude Code unrestricted inside the generic
container against a **new** or **existing** project. For the *why* and the
design, see [README.md](README.md).

The model: **one image, built once, mounted into any project directory.** You do
**not** copy files into your projects.

---

## 0. One-time setup (do this once, ever)

1. Keep this repo somewhere stable — it holds `claude-box-dotnet` and `.devcontainer/`:

   ```bash
   git clone <this-repo> ~/tools/claude-dotnet-devcontainer
   ```
2. (Optional but recommended) put the helper on your PATH so you can call it from
   any project as `claude-box-dotnet`:

   ```bash
   ln -s ~/tools/claude-dotnet-devcontainer/claude-box-dotnet ~/.local/bin/claude-box-dotnet
   ```

   The examples below use `claude-box-dotnet`; if you skip this, just call
   `~/tools/claude-dotnet-devcontainer/claude-box-dotnet` instead.

   The helper always takes a subcommand — `start`, `stop`, `rm`, `shell`, or
   `info` — plus an optional project directory (default: the current one).
   Run `claude-box-dotnet help` for the full list.
3. Make sure **Docker** and **VS Code + the Dev Containers extension** are
   installed, then build the image once:

   ```bash
   ~/tools/claude-dotnet-devcontainer/build-image
   ```

   `claude-box-dotnet` runs containers and never builds; it errors if the image is
   missing. The build needs no secrets and no extra files in the repo.
4. (Only if you want `docker` to work **inside** the container) export
   `DOCKER_SSH_KEY_OP_REF` pointing at the SSH private key for your remote Docker
   host, plus `OP_SERVICE_ACCOUNT_TOKEN` so `op` can read it without prompting.
   Working across several organizations? Set `CLAUDE_ORG` and prefix them
   (`ACME_DOCKER_SSH_KEY_OP_REF`) — see the README.
   `claude-box-dotnet start` fetches the key, base64-decodes it, and injects it into the
   running container; it is never written into this repo or into the image. Skip
   this and everything else still works — you just get a warning at start.
   Creating or rotating a key (including putting the **public** half on the remote
   host) is covered by "Provisioning a new key" in the README.

---

## 1. Use it with an EXISTING project

```bash
cd ~/Projects/my-existing-app
claude-box-dotnet start                # or: claude-box-dotnet start ~/Projects/my-existing-app
```

What happens:

- The `claude-dotnet-devcontainer` image must already exist (step 0.3); `claude-box-dotnet`
  errors out rather than building one. The same image serves every project.
- If the project has a solution or project file (`*.sln`, `*.slnx`, `*.csproj`) in
  its root, `claude-box-dotnet` runs `dotnet restore` for you (`--locked-mode` when a
  `packages.lock.json` exists) so the packages are ready when you attach.
- A detached container named `claude-dotnet-my-existing-app-<hash>` starts, with your
  project bind-mounted at `/workspace`. Edits inside the container appear live on
  your host, and vice versa.

Then **attach and run Claude** (see [section 3](#3-attach-and-start-claude)).

---

## 2. Use it with a NEW project

1. Create and enter the project directory on your host:

   ```bash
   mkdir ~/Projects/my-new-app && cd ~/Projects/my-new-app
   ```
2. Start the container:

   ```bash
   claude-box-dotnet start
   ```
3. Attach (section 3), then scaffold the .NET solution **inside the container**
   so the lockfiles and restore state match the Linux environment:

   ```bash
   dotnet new gitignore
   dotnet new sln --format slnx
   dotnet new webapi -n Api -o src/Api
   dotnet sln add src/Api
   dotnet format          # the stock template has one stray trailing space
   ```

   Because the project dir is bind-mounted, the new files also appear on your host
   immediately. Build output (`bin/`, `obj/`) goes to the container's own
   `~/.artifacts`, not into the project — see the README's "How it works".

   For reproducibility, pin the SDK with `dotnet new globaljson --sdk-version
   $(dotnet --version) --roll-forward latestFeature` and, if you use local tools,
   `dotnet new tool-manifest`. To get lockfiles, set
   `<RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>` in a
   `Directory.Build.props`; commit `packages.lock.json`, `global.json` and
   `.editorconfig`.

---

## 3. Attach and start Claude

> **Order matters:** the container must be **running first** (steps 1–2 above
> start it with `claude-box-dotnet start`), *then* VS Code attaches to it. You can have the
> project already open in a normal host VS Code window — handy for running
> `claude-box-dotnet` from its terminal — but that window isn't connected to the
> container; attaching below is a separate step that needs the container up.
> (Want VS Code to launch the container *for* you when you open the folder
> instead? That's the [Reopen-in-Container alternative](#alternative-per-project-dev-container).)

1. In VS Code: **Cmd/Ctrl+Shift+P → "Dev Containers: Attach to Running
   Container"**, then pick `claude-dotnet-<your-project>-<hash>`.
2. VS Code opens a window inside the container. **File → Open Folder →
   `/workspace`** if it doesn't land there.

### Use the Claude Code panel (recommended)

The image asks VS Code to auto-install the **Claude Code** extension on attach
(via image metadata), so you don't have to use the terminal:

1. Click the **Claude Code icon** in the Activity bar (left) or the editor
   title bar to open the panel. (If it's not there yet, give the extension a few
   seconds to install, or reload the window.)
2. **Sign in** on first use — a browser opens on your host; approve, and you're in.
3. To run **unrestricted**, click the **permission-mode indicator** at the bottom
   of the prompt box and choose **Bypass Permissions** (the panel equivalent of
   `--dangerously-skip-permissions`; safe here because the container is isolated).

> **If the extension doesn't auto-install** (some VS Code builds don't apply image
> metadata on attach), add this to your **host** VS Code `settings.json` once — it
> installs the extension into every container you attach to:
>
> ```json
> "dev.containers.defaultExtensions": ["anthropic.claude-code"]
> ```
>
> Or install "Claude Code" manually from the Extensions view in the attached window.

### Or use the terminal

Open a terminal in the attached window (working dir `/workspace`) and run:

```bash
claude --dangerously-skip-permissions
```

**First login only:** the container can't pop a browser, so Claude prints a
**URL + code**. Open the URL on your host browser, approve, and paste the code
back into the terminal. Auth is saved in a named volume (shared with the panel),
so you won't repeat this for other projects.

---

## 4. Multiple projects at the same time

You can run as many as you like **simultaneously**. Each project gets its own
container (named `claude-dotnet-<dir>-<hash>`, so even same-named folders stay
distinct) and its own **auto-assigned host port**, so they never clash:

```bash
cd ~/Projects/project-a && claude-box-dotnet start   # -> claude-dotnet-project-a-<hash>, e.g. host port 32768
cd ~/Projects/project-b && claude-box-dotnet start   # -> claude-dotnet-project-b-<hash>, e.g. host port 32769
```

`claude-box-dotnet` prints the actual port mapped to the container's `:8080` for each. All
containers **share one Claude login** — the `claude-code-config` volume, or
`claude-code-config-<org>` when `CLAUDE_ORG` is set, in which case projects share
a login per org rather than globally. Session and shell history stay per project.
Attach a separate VS Code window to each.

Re-running `claude-box-dotnet start` for a project that already has a container just restarts
it — your shell history and any container-side state come back.

---

## 5. Connecting to a database

The container ships the `sqlcmd` client and maps `host.docker.internal` to your
host.

- **DB on your laptop:** the default connection string
  (`Server=host.docker.internal,1433;Database=app;User Id=sa;Password=Your_strong_Passw0rd;TrustServerCertificate=True`)
  already points there. It reaches your app as `ConnectionStrings__Default`, which
  ASP.NET Core binds to `builder.Configuration.GetConnectionString("Default")`.
  Test connectivity with `sqlcmd`, which takes its own arguments rather than the
  connection string:

  ```bash
  sqlcmd -S host.docker.internal,1433 -U sa -P 'Your_strong_Passw0rd' -C -Q 'SELECT name FROM sys.databases'
  ```
- **Remote/hosted DB:** pass a different SQL Server connection string when starting the
  container (`claude-box-dotnet` masks the password in its status output):

  ```bash
  DB_CONNECTION_STRING='Server=db.example.com,1433;Database=mydb;User Id=user;Password=pass;TrustServerCertificate=True' claude-box-dotnet start
  ```

The database itself is **external** — this container never runs or manages it.

### Or: run your app + a local DB with Compose

If you'd rather spin up the application **and** a throwaway SQL Server for
development, define them in a `compose.yaml` **in your project** (separate from
the dev container). A ready-to-copy example is in
[examples/compose.yaml](examples/compose.yaml):

```bash
cp ~/tools/claude-dotnet-devcontainer/examples/compose.yaml ~/Projects/my-app/compose.yaml
cd ~/Projects/my-app
docker compose up        # starts the app (with live reload) + SQL Server
```

This stays **independent** of the dev container, by design:

- The `api` service bind-mounts the **same project directory** the Claude dev
  container edits, so changes appear live and `dotnet watch` restarts the app.
- `db` publishes `1433` to the host, so the Claude dev container reaches it at the
  default `host.docker.internal:1433`, while `api` reaches it in-network at
  `db:1433`. Two stacks, decoupled.
- The app's NuGet cache and build output live in named volumes (outside the mount),
  so no `bin/` or `obj/` leaks into your repo from the compose stack.

Edit the `command:` in the example to point at your web project's `.csproj`.

Run `claude-box-dotnet start` for the dev container and `docker compose up` for the app —
they coexist. Running several projects with local DBs? Give each project's compose a
different host port (`1434:1433`, …) and start its dev container with a matching
`DB_CONNECTION_STRING=…Server=host.docker.internal,1434… claude-box-dotnet start`.

---

## 6. Stopping and cleaning up

Use the project directory — `claude-box-dotnet` recomputes the container name from it,
so you never need to look one up:

```bash
claude-box-dotnet stop ~/Projects/my-app     # pause; restart later with claude-box-dotnet start
claude-box-dotnet rm   ~/Projects/my-app     # remove (project files are safe — they live on your host)
claude-box-dotnet info ~/Projects/my-app     # status, image, port, org
```

To see everything at once, or to work with a container whose project directory is
gone:

```bash
docker ps -a --filter name=claude-dotnet
```

Volumes persist your login and history. Remove them only for a clean slate:

```bash
docker volume rm claude-code-config                       # forget the Claude login (shared by all projects with no CLAUDE_ORG)
docker volume ls --filter name=claude-code-config         # per-org login volumes, if you use CLAUDE_ORG
docker volume ls --filter name=claude-dotnet-sessions        # per-project Claude session transcripts
docker volume ls --filter name=claude-dotnet-bash-history    # per-project shell history
docker volume rm claude-nuget-cache                       # NuGet package cache (shared; just re-downloads)
docker volume rm claude-pre-commit-cache                  # pre-commit hook environments (shared; just re-downloads)
```

---

## 7. Customizing the image (adding tools)

Edit [.devcontainer/Dockerfile](.devcontainer/Dockerfile), then rebuild:

- **System package:** add to the `apt-get install` list.
- **Global .NET tool:** add a `RUN dotnet tool install --global <pkg>` line (they land
  on `PATH` via `~/.dotnet/tools`). `dotnet format` is built into the SDK.

Then rebuild the image and recreate the container. These are two separate tools on
purpose: `build-image` makes images, `claude-box-dotnet` runs containers.

```bash
./build-image                         # newest Claude, cached layers
./build-image --full                  # every layer, fresh base image

claude-box-dotnet rm                         # drop the old container
claude-box-dotnet start                      # recreate it from the new image
```

`build-image` finds `.devcontainer/` next to itself, following any symlink on your
PATH, so it works from any directory.

## 7b. Getting the newest Claude Code

`build-image` is also how you upgrade Claude itself. The image pins the version
that was current when it was built, and `DISABLE_AUTOUPDATER=1` keeps it pinned so
nothing shifts mid-session — so upgrades are deliberate:

```bash
./build-image                         # prints the Claude version it installed
```

It busts the Docker cache at the Claude install layer only (the apt/tools/ssh layers
above stay cached, so it takes seconds).

A container keeps running the image it was **created** from, so building alone
changes nothing. Move a project onto the new image by recreating its container:

```bash
claude-box-dotnet rm    ~/Projects/my-app
claude-box-dotnet start ~/Projects/my-app
```

Project files are on your host and Claude's auth, sessions, and shell history are
in named volumes, so nothing is lost. Projects you don't recreate keep running the
previous image.

---

## 8. Automatic formatting

Two independent mechanisms, useful together. Both are **opt-in per project** — the
image imposes neither.

### Format as Claude edits

Claude writes files through its own tools, not through the editor, so VS Code's
`editor.formatOnSave` never fires for Claude-authored code. A `PostToolUse` hook
closes that gap by running `dotnet format whitespace` immediately after each edit:

```bash
mkdir -p .claude
cp ~/tools/claude-dotnet-devcontainer/examples/claude-settings.json .claude/settings.json
```

It runs `dotnet format whitespace --folder --include <file>` on `.cs` files only,
ignores everything else, and always exits 0 so it can never block Claude. The
`whitespace` subcommand with `--folder` needs no restore or build, so it is fast
enough to run after every edit; the full `dotnet format` (style + analyzers) is a
solution-level operation, slow, and belongs in the pre-commit hook or CI instead.

### Check at commit time

`pre-commit` is installed globally in the image (via pipx — the only thing Python
is in the image for), so it needs no project dependency. It also catches edits you make by hand, and the same config runs in CI:

```bash
cp ~/tools/claude-dotnet-devcontainer/examples/.pre-commit-config.yaml .
pre-commit install
```

Hook environments are cached in the shared `claude-pre-commit-cache` volume via
`PRE_COMMIT_HOME`, so they survive container recreation instead of re-downloading
after every image rebuild.

> **Expect one extra cycle for whitespace hooks.** `trailing-whitespace` and
> `end-of-file-fixer` rewrite files, so the first `git commit` after such an edit
> fails with "files were modified by this hook"; re-staging and committing again
> succeeds. The `dotnet format` hook does *not* rewrite — it runs with
> `--verify-no-changes` and fails with a diagnostic instead, which avoids a
> double-commit cycle (run `dotnet format` to fix it). It needs a `.sln`/`.slnx` (or
> single `.csproj`) at the repo root. The PostToolUse hook above keeps whitespace
> clean as Claude writes, so failures are rare.

> **Where hooks run.** You commit inside the container, so these execute in the
> sandbox. But `.git/hooks/` lives in the bind mount, so a **`pre-push`** hook
> would run on your *host* when you push. Neither example defines one; if a
> `pre-push` hook ever shows up in a diff, look closely.

---

## Secrets without 1Password

To use openssl-encrypted files instead of 1Password: run `claude setup-token` for a
Claude token, then `claude-box-dotnet provider openssl`, `claude-box-dotnet seal token`
and `claude-box-dotnet seal ssh-key <keyfile>`. `start` then asks for the passphrase
when it needs a secret. Full details are in the README ("Secrets: 1Password or
encrypted files").

## Optional override env vars

`claude-box-dotnet` reads these from your shell:

| Variable         | Default                               | Purpose                                                                                                                                  |
| ---------------- | ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `IMAGE`        | `claude-dotnet-devcontainer:latest` | image tag to run (and to build, for `build-image`)                                                                                       |
| `PORT`         | auto-assigned                         | pin a fixed host port mapped to container`:8080`; by default each container gets a free port automatically, so several can run at once |
| `DB_CONNECTION_STRING` | `Server=host.docker.internal,1433;Database=app;…` | external SQL Server, SqlClient format; injected into the container as `ConnectionStrings__Default`. The password is masked in `claude-box-dotnet` output |
| `CONTAINER_USER` | `vscode` | the non-root user inside the image (change only if you change the Dockerfile's `USERNAME`) |
| `PROJECT_CODE_NAME` | the project directory's basename | label shown in the container's shell prompt in place of the username: `myproject ➜ /workspace (main) $`. Set it when the directory name is unhelpful (`src`, `app`, `repo`) |
| `GIT_USER_NAME`  | your host `git config user.name`  | commit author name inside the container                                                                                                  |
| `GIT_USER_EMAIL` | your host `git config user.email` | commit author email inside the container                                                                                                 |

`build-image` takes its options as flags rather than env vars — `--full`,
`--pull`, `-t TAG`. Run `./build-image --help` for the list.

Secrets, resolved on the host and injected into the running container — never
committed, never baked into the image:

| Variable | Purpose |
| --- | --- |
| `CLAUDE_TOKEN_OP_REF` | 1Password reference for a long-lived Claude OAuth token, so login survives container recreation |
| `DOCKER_SSH_KEY_OP_REF` | 1Password reference for the SSH **private key** (stored base64-encoded) that reaches the remote Docker host |
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password service-account token, so `op` can read the two above non-interactively |
| `DOCKER_SSH_KEY` | the SSH key material directly, bypassing the provider |
| `SECRET_PROVIDER` | `1password` (default) or `openssl`; overrides the saved default (`claude-box-dotnet provider <name>`) for one run |
| `CLAUDE_TOKEN_FILE` / `DOCKER_SSH_KEY_FILE` | openssl provider: paths of the encrypted files (defaults in `~/.config/claude-box/`, created by `claude-box-dotnet seal`) |
| `CLAUDE_SECRETS_PASSPHRASE_FILE` / `CLAUDE_SECRETS_PASSPHRASE` | openssl provider: skip the passphrase prompt (scripting) |
| `REMOTE_DOCKER_USER` / `REMOTE_DOCKER_HOST` | where `DOCKER_HOST=ssh://…` points (defaults `dockerizer` / `192.168.122.10`) |
| `CLAUDE_ORG` | optional prefix for the three variables above, e.g. `CLAUDE_ORG=acme` → `ACME_CLAUDE_TOKEN_OP_REF` |

Set `CLAUDE_ORG` when you work across several organizations and want their references
kept apart. Each variable is looked up **prefixed first, then plain**, so shared
values can stay unprefixed while only the differing ones are namespaced.

`CLAUDE_ORG` also namespaces the volume holding Claude's login
(`claude-code-config-<org>`), so two organizations never share one credentials
store — and `claude-box-dotnet start` refuses to reuse a container that was created under
a different `CLAUDE_ORG` rather than silently mounting the wrong account's credentials.
See the README's "Namespacing with `CLAUDE_ORG`" for the full precedence rules.

Both are optional. Without the Claude token you just log in interactively; without
the SSH key everything works except `docker` **inside** the container, and
`claude-box-dotnet` warns you at start. See the README's "Remote Docker daemon" section
for why Docker is remote at all.

Example: `PORT=8001 claude-box-dotnet start ~/Projects/second-app`

---

## Alternative: per-project Dev Container

If you'd rather version the config alongside one specific project and use VS
Code's **"Reopen in Container"** flow instead of attach-to-running, copy
`.devcontainer/`, `CLAUDE.md`, and `.gitignore` into that project root and reopen
it in the container. Use this only when you want that single project to own its
config; for the general "one image, many projects" workflow, stick with
`claude-box-dotnet`.

Note that **Docker inside the container does not work in this flow** — the
remote-daemon SSH key is injected by `claude-box-dotnet start`, which Reopen-in-Container
never runs. See the README's "Alternative: per-project Dev Container".
