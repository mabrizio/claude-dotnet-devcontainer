# Show a project code name instead of the username in the bash prompt.
#
#   vscode ➜ /workspace (main) $        with PROJECT_CODE_NAME unset
#   man-bff-api ➜ /workspace (main) $   with PROJECT_CODE_NAME=man-bff-api
#
# `claude-box-dotnet start` injects PROJECT_CODE_NAME (the project directory's basename)
# into the container. Unset — the "Reopen in Container" flow, or a plain
# `docker run` — the prompt stays exactly as the base image made it.
[ -n "${PROJECT_CODE_NAME:-}" ] || return 0

# The base image (mcr.microsoft.com/devcontainers/*) assembles PS1 in a
# __bash_prompt function partway through ~/.bashrc: user, exit-status arrow, cwd,
# git branch. We are sourced at the END of that file, once PS1 already exists, and
# rewrite only the user segment — so the arrow colouring, the branch lookup and its
# devcontainers-theme.* switches keep coming from upstream rather than being
# duplicated (and left to drift) here.
#
# That segment is upstream's green SGR sequence followed by \u, bash's "username"
# prompt escape — and we replace both, so the code name is dark orange (256-colour
# palette index 208) rather than the green a stock devcontainer prompt uses. The
# arrow that follows sets its own colour, so nothing here needs a reset. Both
# strings appear exactly once in this form; the \u is what makes them unambiguous,
# since the green sequence alone also opens upstream's GITHUB_USER branch.
#
# Substituting a ${...} reference rather than the value keeps the name LIVE: bash
# re-expands PS1 before every prompt, so reassigning PROJECT_CODE_NAME in a running
# shell takes effect immediately.
#
# Both expansions stay QUOTED inside the substitution, which makes bash match them
# literally. Unquoted, the brackets in the colour sequence would be read as a glob
# character class and \u as an escaped plain "u" — matching the wrong text or
# nothing at all.
#
# Should upstream ever restructure the prompt, the substitution simply finds
# nothing and you keep the stock username — never a broken PS1.
#
# Not GITHUB_USER, which upstream also honours: that path prefixes an "@" and is
# meant to carry a real account name.
__pcn_from='\[\033[0;32m\]\u'
__pcn_to='\[\033[38;5;208m\]${PROJECT_CODE_NAME}'
PS1="${PS1/"$__pcn_from"/"$__pcn_to"}"
unset __pcn_from __pcn_to
