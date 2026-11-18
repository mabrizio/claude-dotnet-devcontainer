# Generic .NET 10 dev container that bundles the Claude Code CLI. Designed to run
# detached (`docker run -d ... sleep infinity`) so you can drive Claude from
# VS Code via "Dev Containers: Attach to Running Container", with any project
# directory bind-mounted at /workspace.
#
# The base image ships a non-root `vscode` user (UID 1000), which is REQUIRED:
# Claude Code refuses --dangerously-skip-permissions when launched as root.
# It also ships the .NET 10 SDK (LTS) — we do not install a second one.
FROM mcr.microsoft.com/devcontainers/dotnet:10.0

ARG USERNAME=vscode

# --- System tools -----------------------------------------------------------
# sqlcmd (mssql-tools18, below) -> `sqlcmd` to talk to an external SQL Server
# iptables / ipset / dnsutils  -> needed only by the optional egress firewall
# ripgrep                      -> fast code search
# python3 / pipx               -> ONLY so `pre-commit` can be installed below. Python
#                                 is not a project runtime in this image; don't remove
#                                 it as "unused" without removing pre-commit too.
# the rest are general build/test conveniences
#
# NativeAOT publishing needs a C toolchain. Uncomment to enable it:
#     clang zlib1g-dev \
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get install -y --no-install-recommends \
        iptables ipset dnsutils \
        ripgrep \
        jq \
        less \
        curl \
        git \
        ca-certificates \
        openssh-client \
        iputils-ping \
        net-tools \
        python3 pipx \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- Docker CLI (client only, NO daemon) ------------------------------------
# This container runs no Docker daemon; it drives a REMOTE daemon over SSH via
# DOCKER_HOST=ssh://... (assembled by claude-box-dotnet). We install only the client
# and the Compose plugin from Docker's official apt repo — not docker-ce/dockerd.
# The base image is Ubuntu, hence the linux/ubuntu repository.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- sqlcmd (SQL Server client) ---------------------------------------------
# mssql-tools18 from Microsoft's apt repo (amd64 and arm64). Installing it means
# accepting Microsoft's EULA, hence ACCEPT_EULA=Y. Its binaries live in
# /opt/mssql-tools18/bin; symlink sqlcmd onto PATH. Note this sqlcmd encrypts by
# default, so against a dev server with a self-signed certificate pass `-C`.
RUN . /etc/os-release \
    && curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -o /tmp/pmp.deb \
    && dpkg -i /tmp/pmp.deb && rm /tmp/pmp.deb \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools18 \
    && ln -s /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && sqlcmd -? | head -n 2

# --- .NET SDK check ---------------------------------------------------------
# The SDK comes from the base image. Fail the build loudly if that tag ever stops
# being .NET 10, rather than shipping a container that silently targets another LTS.
RUN dotnet --version | grep -q '^10\.' \
    || { echo "ERROR: expected the .NET 10 SDK, got $(dotnet --version)" >&2; exit 1; }

# Persist shell history across container recreations (quality-of-life).
RUN mkdir -p /commandhistory \
    && touch /commandhistory/.bash_history \
    && chown -R $USERNAME /commandhistory \
    && echo "export HISTFILE=/commandhistory/.bash_history" >> /home/$USERNAME/.bashrc

# Shell quality-of-life: handy aliases and readline history-search on Up/Down.
RUN printf '\nalias ll=%s\nalias s=%s\n' "'ls -Aalh'" "'cd ..'" >> /home/$USERNAME/.bashrc
COPY --chown=$USERNAME:$USERNAME inputrc /home/$USERNAME/.inputrc

# Prompt tweak: swap the username for PROJECT_CODE_NAME when `claude-box-dotnet start`
# injects one, so several attached containers are told apart at a glance. Sourced
# LAST — it rewrites the PS1 the base image's devcontainers theme builds earlier in
# .bashrc, and is a no-op when the variable is unset. See bash_prompt.sh for why it
# patches that PS1 instead of redefining it.
COPY --chown=$USERNAME:$USERNAME bash_prompt.sh /home/$USERNAME/.bash_prompt.sh
RUN printf '\nif [ -f ~/.bash_prompt.sh ]; then . ~/.bash_prompt.sh; fi\n' >> /home/$USERNAME/.bashrc

# Login shells reset PATH via /etc/profile, dropping the sbin dirs where net-tools
# lives (ifconfig, route, arp). Re-add them for login shells so those resolve by
# name (ENV PATH already covers non-login shells).
RUN printf 'export PATH="/usr/sbin:/sbin:$PATH"\n' > /etc/profile.d/10-sbin-path.sh

# The NuGet package cache lives OUTSIDE the mounted workspace (see NUGET_PACKAGES
# below), and is backed by a named volume. Pre-create it OWNED BY the user: a fresh
# named volume mounted here inherits this ownership, otherwise it would be
# root-owned and restore would fail.
RUN mkdir -p /home/$USERNAME/.nuget/packages \
    && chown -R $USERNAME:$USERNAME /home/$USERNAME/.nuget

# Pre-create ~/.claude OWNED BY the user. A fresh named volume mounted here
# inherits this ownership; without it the volume would be root-owned and login
# would fail. This is where Claude stores auth/credentials/settings.
RUN mkdir -p /home/$USERNAME/.claude && chown -R $USERNAME /home/$USERNAME/.claude

# Your project directory gets bind-mounted here at run time.
RUN mkdir -p /workspace && chown $USERNAME /workspace

# --- SSH client setup (NO key material in the image) -------------------------
# The private key is deliberately NOT baked in. `claude-box-dotnet start` resolves it
# from 1Password on the host and writes it into the RUNNING container over stdin,
# so this image contains no secret and can be pulled, saved, or shared freely.
# All we prepare here is the directory — SSH refuses to use a key that sits in a
# loose-permission dir, so it must be 700 and owned by the non-root user.
RUN mkdir -p /home/$USERNAME/.ssh \
    && chmod 700 /home/$USERNAME/.ssh \
    && chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

# SSH client config (see .devcontainer/ssh_config for the settings + rationale).
COPY --chown=$USERNAME:$USERNAME ssh_config /home/$USERNAME/.ssh/config
RUN chmod 600 /home/$USERNAME/.ssh/config

# --- Managed Claude Code policy (container-only) -----------------------------
# Highest-precedence settings, owned by root and living OUTSIDE the workspace, so
# they exist only inside this image and never touch your host or the project's
# .claude/settings.json. `allowManagedPermissionRulesOnly` makes Claude ignore
# ALL user/project allow/ask/deny rules and honor only the managed file — the one
# mechanism that lifts a project `deny` (which otherwise can't be overridden by
# any allow at any scope). Combined with bypassPermissions, this is the "run
# Claude unrestricted in isolation" posture this container exists for.
COPY managed-settings.json /etc/claude-code/managed-settings.json
# Managed memory file, loaded in every project: the no-attribution rule (no Claude
# co-author trailers or "generated with" lines). managed-settings.json also blanks
# Claude Code's built-in commit/PR attribution, so the rule holds in both layers.
COPY managed-CLAUDE.md /etc/claude-code/CLAUDE.md

# --- Environment -------------------------------------------------------------
# DOTNET_CLI_TELEMETRY_OPTOUT / DOTNET_NOLOGO / DOTNET_SKIP_FIRST_TIME_EXPERIENCE
#   silence telemetry and the first-run banner.
# DOTNET_GENERATE_ASPNET_CERTIFICATE=false: there is no browser trust store in the
#   container, so no HTTPS dev certificate — dev runs over plain HTTP.
# DOTNET_USE_POLLING_FILE_WATCHER keeps `dotnet watch` reliable on bind mounts
#   (Docker Desktop on macOS/Windows especially).
# NUGET_PACKAGES puts the package cache outside the workspace (a named volume).
# ASPNETCORE_URLS: 8080 is the ASP.NET Core container convention.
# ArtifactsPath sends bin/ and obj/ to the container's own filesystem, so a
#   host-built obj/project.assets.json (absolute host paths) can never break a
#   container build, and vice versa. Set here only — a project never references it.
#   See the README's "How it works" for the trade-off.
# PATH: ~/.local/bin holds Claude, diff-so-fancy and pipx apps; ~/.dotnet/tools
#   holds global .NET tools.
USER $USERNAME

ENV PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.dotnet/tools:/usr/sbin:/sbin:${PATH}" \
    DOTNET_CLI_TELEMETRY_OPTOUT="1" \
    DOTNET_NOLOGO="1" \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1" \
    DOTNET_GENERATE_ASPNET_CERTIFICATE="false" \
    DOTNET_USE_POLLING_FILE_WATCHER="1" \
    DOTNET_WATCH_SUPPRESS_LAUNCH_BROWSER="1" \
    NUGET_PACKAGES="/home/${USERNAME}/.nuget/packages" \
    ASPNETCORE_URLS="http://0.0.0.0:8080" \
    ArtifactsPath="/home/${USERNAME}/.artifacts" \
    DISABLE_AUTOUPDATER="1"

# --- Global, project-independent dev tools ----------------------------------
# Ready on PATH for every project, no per-project install needed. These sit ABOVE
# the CLAUDE_INSTALL_BUST ARG on purpose, so a routine "newest Claude" rebuild
# stays fast; `build-image --full` is how you refresh them.
#   pre-commit — cross-language git hooks (the only thing python3/pipx is for).
#   dotnet-ef  — EF Core CLI, the natural companion to SQL Server.
# `dotnet format` is built into the SDK, so it is not installed here.
RUN pipx install pre-commit && pre-commit --version
RUN dotnet tool install --global dotnet-ef && dotnet ef --version

# --- Claude Code CLI ---------------------------------------------------------
# Installed as the non-root user via the official native installer (self-contained
# binary, no Node.js). The Dev Containers "feature" only runs under the Dev
# Containers extension, so for a plain `docker run` image we install it ourselves.
# Lands in ~/.local/bin (already on PATH above).
#
# `build-image` passes a changing CLAUDE_INSTALL_BUST so Docker cannot reuse the
# cached layer here and the installer actually re-runs, pulling the newest Claude
# Code. Everything above (apt, tools, ssh) still comes from cache, so an upgrade
# takes seconds instead of a full --no-cache rebuild. The ARG has to be referenced
# by the RUN itself — BuildKit only keys a layer on the ARGs it uses.
ARG CLAUDE_INSTALL_BUST=0
RUN echo "claude install bust: ${CLAUDE_INSTALL_BUST}" >/dev/null \
    && curl -fsSL https://claude.ai/install.sh | bash

# --- diff-so-fancy: readable git diffs ---------------------------------------
# VS Code copies your HOST ~/.gitconfig into the container on attach, so a
# `core.pager = diff-so-fancy | less ...` there would otherwise point at a binary
# that doesn't exist here. Despite being distributed via npm, the released
# artifact is a single fat-packed PERL script — perl ships in the base image, so
# this needs no Node.
#
# The "latest/download" URL always resolves to the current stable release, and
# this layer sits BELOW the CLAUDE_INSTALL_BUST ARG above: everything after that
# ARG is rebuilt on every `build-image` run, which is what keeps this current.
# Moving it above that ARG would silently freeze it at a cached version.
RUN mkdir -p "/home/${USERNAME}/.local/bin" \
    && curl -fsSL -o "/home/${USERNAME}/.local/bin/diff-so-fancy" \
         https://github.com/so-fancy/diff-so-fancy/releases/latest/download/diff-so-fancy \
    && chmod +x "/home/${USERNAME}/.local/bin/diff-so-fancy" \
    # Smoke-test with a real diff: it reads stdin, so --version would just hang.
    && printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' \
         | "/home/${USERNAME}/.local/bin/diff-so-fancy" >/dev/null

# Pre-complete Claude Code's first-run onboarding. Interactively, `claude` runs a
# theme picker + login/auth chooser on first launch, gated on `hasCompletedOnboarding`
# in ~/.claude.json — and it shows even when a valid CLAUDE_CODE_OAUTH_TOKEN is
# already injected (the headless `-p` path skips it, which is why scripted use
# works but the TUI appears to "ignore" the token). Seeding the flags here makes
# the TUI go straight to the prompt and use the injected token. We also pre-accept
# the trust + bypass-permissions dialogs for /workspace (the fixed bind-mount path),
# since running bypassPermissions in this isolated container is the whole point —
# managed-settings.json already forces that mode. This file lives at ~/.claude.json,
# a sibling of the ~/.claude volume mount, so it is baked in the image (not the
# volume) and every fresh container starts non-interactive. Change the theme in the
# TUI at runtime if you prefer light. Claude merges/rewrites this file as you work.
COPY local_claude.json /home/${USERNAME}/.claude.json

# Tell VS Code which extensions/settings to apply when attaching to this image,
# so the Claude Code panel (and C# support) install automatically — no need to
# drive Claude from the terminal. The Dev Containers extension reads this image
# metadata on "Attach to Running Container". If your VS Code build doesn't apply
# it, see the `dev.containers.defaultExtensions` fallback in HOWTO.
LABEL devcontainer.metadata='[{"customizations":{"vscode":{"extensions":["anthropic.claude-code","ms-dotnettools.csdevkit","ms-dotnettools.csharp","editorconfig.editorconfig","ms-azuretools.vscode-docker"],"settings":{"dotnet.defaultSolution":"disable","claudeCode.allowDangerouslySkipPermissions":true,"claudeCode.initialPermissionMode":"bypassPermissions"}}},"remoteUser":"vscode"}]'

WORKDIR /workspace

# Keep the container alive so VS Code can attach.
CMD ["sleep", "infinity"]
