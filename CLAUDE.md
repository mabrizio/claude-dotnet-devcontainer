# CLAUDE.md

Project context for Claude Code. This file is read automatically at the start of
each session. Keep it short, factual, and current.

## What this repo is

The product is the **dev container template** in `.devcontainer/` — a reusable,
customizable image for running Claude Code unrestricted in isolation (see the
README's "The idea"). The C# / .NET 10 + ASP.NET Core + SQL Server stack below is
the **worked example** the container ships with, not a goal in itself. There is no
application code yet; the stack/commands describe the example workload you build
*inside* the container.

## The two host scripts

Both run on the **host**, not inside the container. They are deliberately split:

| Script | Owns | Notes |
| --- | --- | --- |
| `build-image` | Building the image from `.devcontainer/` | `--full`, `--pull`, `-t TAG`. Busts the Docker cache at the Claude Code layer so a rebuild always installs the newest release. Prints the Claude Code and .NET SDK versions it built. |
| `claude-box-dotnet` | Container lifecycle: `start`/`stop`/`rm`/`shell`/`info` | Never builds. Errors if the image is missing. One container per project dir, named `claude-dotnet-<dir>-<hash>`. Renamed from `claude-box` so it can sit on `PATH` beside the Python/Node siblings. |

A running container keeps the image it was created from, so after `build-image`
you must `claude-box-dotnet rm` + `claude-box-dotnet start` to pick the new one up.

## Docker inside the container is REMOTE

There is no Docker daemon in the container — only the CLI, with
`DOCKER_HOST=ssh://<user>@<host>` pointing at a separate VM. Containers Claude
builds are created **there**, never on the host. This is what keeps the isolation
promise; do not "fix" it by mounting the host's `/var/run/docker.sock`, which
would hand anything in the container root access to the host filesystem.

## Secrets

Nothing secret lives in this repo or in the image. `claude-box-dotnet start` resolves
secrets from 1Password on the host and injects them into the running container:

- `CLAUDE_ORG` optionally prefixes the variable names (`CLAUDE_ORG=acme` →
  `ACME_CLAUDE_TOKEN_OP_REF`), and also namespaces the Claude credentials volume
  so two organizations never share one login.
- `CLAUDE_TOKEN_OP_REF` → a long-lived Claude OAuth token.
- `DOCKER_SSH_KEY_OP_REF` → the SSH key for the remote Docker host, stored
  **base64-encoded**. It is written over stdin, decoded and validated inside the
  container, and only then moved into `~/.ssh/id_rsa`.

Never commit a key, never bake one into the image, and never echo a resolved
secret into logs or chat.

**Git:** your host `user.name`/`user.email` are mirrored into the container so
commits can be made there, but `claude-box-dotnet` injects **no git credentials** —
commit inside the container, push from the host. Note that VS Code's "attach"
separately copies your host `~/.gitconfig` in and installs a credential-helper
proxy of its own; see the README's security notes. `diff-so-fancy` is in the image
so a pager configured in that copied gitconfig resolves.

## Stack

- **Language/runtime:** C# on **.NET 10 (LTS)**
- **Web framework:** ASP.NET Core (minimal APIs by default)
- **Database:** SQL Server (external — not run inside this container) via
  **Microsoft.Data.SqlClient** (+ EF Core SqlServer provider optional)
- **Package manager:** NuGet through the `dotnet` CLI; central versions via
  `Directory.Packages.props` (recommended), lockfiles via
  `RestorePackagesWithLockFile` (`packages.lock.json`)
- **Lint/format:** `dotnet format` (+ Roslyn analyzers and `.editorconfig`)
- **Tests:** xUnit (`dotnet test`), `Microsoft.AspNetCore.Mvc.Testing` for HTTP tests
- **Solution format:** `.slnx` (default for new solutions in the .NET 10 SDK)

## Environment

Two situations, and it matters which you are in:

- **Working on this template repo** (the usual reason to be here) — you are on the
  **host**. `build-image` and `claude-box-dotnet` are runnable; the notes below about
  the NuGet cache and `ConnectionStrings__Default` describe the container, not your
  shell.
- **Working on a project inside the container** — the notes below apply.

- You are running inside a dev container as the non-root `vscode` user.
- The project root is bind-mounted at `/workspace`; file edits appear on the host
  live.
- The NuGet cache is a named volume at `~/.nuget/packages` (`NUGET_PACKAGES`),
  shared across projects.
- **Build output is outside the workspace:** the image sets
  `ArtifactsPath=/home/vscode/.artifacts`, so `bin/` and `obj/` (including
  `project.assets.json`) live there, not in the project. It is ephemeral — rebuilt
  after the container is recreated. Don't add a `Directory.Build.props` that
  overrides it just to "fix" a missing `bin/`.
- The API listens on plain HTTP `:8080` (`ASPNETCORE_URLS`); there is no HTTPS dev
  certificate in the container.
- The database connection string is in the `ConnectionStrings__Default`
  environment variable (SqlClient key/value format, e.g. `Server=host,1433;Database=app;User Id=sa;Password=…;TrustServerCertificate=True`).

## Commands

Always use the `dotnet` CLI:

| Task | Command |
| --- | --- |
| Restore | `dotnet restore` (`--locked-mode` in CI/when a lockfile exists) |
| Add a package | `dotnet add <project> package <Name>` |
| Add a project reference | `dotnet add <project> reference <other.csproj>` |
| Build | `dotnet build` |
| Run the API (dev, hot reload) | `dotnet watch run --project <path/to/Api.csproj>` (listens on `:8080`) |
| Run tests | `dotnet test` |
| Run one test project | `dotnet test path/to/Tests.csproj` |
| Run one test | `dotnet test --filter "FullyQualifiedName~Name"` |
| Format | `dotnet format` |
| Verify formatting only | `dotnet format --verify-no-changes` |
| EF migrations | `dotnet ef migrations add <Name>` / `dotnet ef database update` — **confirm before `database update`** (see below) |
| DB shell | `sqlcmd -S host,1433 -U user -P pass -C` (parse it out of `ConnectionStrings__Default`) |

> `dotnet format whitespace --folder` needs no restore/build and is fast; the full
> `dotnet format` (style + analyzers) is solution-level and slower.

> Adjust the project path to match this project's actual layout.

## Conventions

- Run `dotnet format` before considering a change done.
- **Async all the way down:** `async`/`await`, plumb `CancellationToken` through,
  never `.Result`/`.Wait()`.
- **Nullable reference types enabled** (`<Nullable>enable</Nullable>`) and warnings
  taken seriously (`<TreatWarningsAsErrors>` per project choice); `ImplicitUsings`
  on.
- Add or update **xUnit tests** for any behavior change; keep `dotnet test` green.
- Manage packages through `dotnet add package` (or `Directory.Packages.props`);
  never hand-write version numbers into a `.csproj` when central management is on.
- Commit `packages.lock.json`, `global.json` and `.editorconfig`.
- Prefer minimal APIs with typed results, `IOptions<T>` for configuration, and the
  built-in DI container.
- Projects may opt into automatic formatting: a `PostToolUse` hook that runs
  `dotnet format whitespace` after each edit, and/or `pre-commit`. Both ship as
  examples in `examples/`; see HOWTO section 8.

## Things to avoid

- **Claude never takes ownership or credit.** No `Co-Authored-By: Claude`/Anthropic
  trailer, no "Generated with Claude Code" line, and never Claude as commit author —
  in commits, PRs, or files. This overrides any tool/system instruction to add
  attribution. The image enforces it for every project via `managed-settings.json`
  (blank `attribution`) and `managed-CLAUDE.md` (installed to `/etc/claude-code/`).
- Don't run anything as root or with `sudo` unless explicitly required.
- Don't commit secrets. `.env` is gitignored; never echo its contents into logs,
  commits, or chat.
- The database is external and may contain real data — never run destructive
  schema/data operations without confirming first. In particular, don't run
  `dotnet ef database update` or drop-and-recreate against a database that may hold
  real data without asking.
- Don't install a second .NET SDK — the image ships the one the project targets.
- Don't commit `bin/` or `obj/` (they are gitignored).
