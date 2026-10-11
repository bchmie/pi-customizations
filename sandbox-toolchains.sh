#!/usr/bin/env bash
# sandbox-toolchains.sh — shared host-toolchain passthrough for the Pi sandbox
# launchers (pi-sandbox and pi-podman).
#
# Problem
# -------
# Both sandboxes hide everything under $HOME except an allowlist. But host dev
# toolchains (uv, cargo, nvm, pyenv, mise, …) live under $HOME, and the symlinks
# they create are absolute, e.g.
#
#     .venv/bin/python -> $HOME/.local/share/uv/python/cpython-…/bin/python3.13
#
# Hiding those paths makes every host-created venv unusable inside the sandbox,
# even though .venv itself is bind-mounted read-write from the project.
#
# Fix
# ---
# Expose the toolchain *install roots* read-only at their original absolute
# paths. Because the path is identical on both sides, absolute symlinks keep
# resolving — and anything the sandbox creates (a venv, a virtualenv) records
# the same paths and therefore also works on the host.
#
# Mutate works without touching the host because caches live under the sandbox
# home, which shadows the real $HOME: `uv sync`, `uv run`, `cargo build` write
# to ~/.cache/… inside the sandbox. Only *installing new interpreters or tools*
# (uv python install, uv tool install, rustup update) needs a rw mount — flip
# the relevant entry to `rw` in the config file if you want that.
#
# Security
# --------
# Only install roots are exposed — never files that can carry credentials
# (~/.cargo/credentials.toml, ~/.npmrc, ~/.m2/settings.xml, ~/.config/pip,
# ~/.config/uv, ~/.netrc, ~/.docker, …). That is why ~/.cargo is not exposed as
# a whole; only its bin/ directory (the rustup shims) is.
#
# Usage
# -----
#   source .../sandbox-toolchains.sh
#   toolchain_collect
#   # then read:
#   #   TOOLCHAIN_MOUNT_MODE[i] / TOOLCHAIN_MOUNT_PATH[i]  (parallel arrays)
#   #   TOOLCHAIN_PATH_DIRS[i]                             (PATH additions)
#
# User config: ${XDG_CONFIG_HOME:-$HOME/.config}/pi-sandbox/toolchains.conf
# One entry per line, '#' starts a comment:
#   ro <path>   expose read-only (the default for every entry)
#   rw <path>   expose read-write (writes persist to the host — use sparingly)
#   -  <path>   drop a default entry
# <path> is absolute, or relative to $HOME.

# Default install roots, relative to $HOME. Read-only, same absolute path.
_TOOLCHAIN_DEFAULTS=(
  .local/bin                 # uv, uvx, pipx shims, …
  .local/share/uv            # uv-managed Pythons and uv tools
  .local/share/pipx
  .local/share/mise
  .local/share/pnpm
  .local/share/fnm
  .local/share/virtualenvs
  .local/share/asdf
  .cargo/bin                 # rustup shims only; .cargo may hold credentials
  .rustup
  .nvm
  .pyenv
  .bun/bin
  .deno/bin
  .volta/bin
  .npm-global/bin            # global node_modules; ~/.npmrc stays hidden
  .dotnet
  .sdkman/candidates
  go/bin
)

# Install-root env vars to follow when a manager is configured off the default
# path. Cache vars are deliberately excluded (they must stay sandbox-local), as
# is CARGO_HOME (it can contain credentials.toml).
_TOOLCHAIN_ENV_DIRS=(
  UV_PYTHON_INSTALL_DIR
  RUSTUP_HOME
  GOPATH
  GOMODCACHE
  PNPM_HOME
  BUN_INSTALL
  DENO_INSTALL
  MISE_DATA_DIR
  PYENV_ROOT
  NVM_DIR
  ASDF_DATA_DIR
  VOLTA_HOME
  DOTNET_ROOT
)

toolchain_path_dirs() {
  local d
  for d in \
    "$HOME/.local/bin" \
    "${CARGO_HOME:-$HOME/.cargo}/bin" \
    "${GOPATH:-$HOME/go}/bin" \
    "${PNPM_HOME:-$HOME/.local/share/pnpm}" \
    "${MISE_DATA_DIR:-$HOME/.local/share/mise}/shims" \
    "${BUN_INSTALL:-$HOME/.bun}/bin" \
    "${DENO_INSTALL:-$HOME/.deno}/bin" \
    "${VOLTA_HOME:-$HOME/.volta}/bin" \
    "$HOME/.npm-global/bin" \
    "$HOME/.dotnet"
  do
    [ -d "$d" ] && printf '%s\n' "$d"
  done | awk '!seen[$0]++'
}

toolchain_collect() {
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}/pi-sandbox/toolchains.conf"
  local -A mode=()
  local rel abs var val

  for rel in "${_TOOLCHAIN_DEFAULTS[@]}"; do
    case "$rel" in /*) abs="$rel" ;; *) abs="$HOME/$rel" ;; esac
    mode["$abs"]=ro
  done

  for var in "${_TOOLCHAIN_ENV_DIRS[@]}"; do
    val="${!var:-}"
    [ -n "$val" ] || continue
    case "$val" in /*) mode["$val"]=ro ;; esac
  done

  if [ -f "$conf" ]; then
    local line op path _
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      read -r op path _ <<<"$line" || true
      [ -n "${op:-}" ] && [ -n "${path:-}" ] || continue
      case "$path" in /*) abs="$path" ;; *) abs="$HOME/$path" ;; esac
      case "$op" in
        ro | rw) mode["$abs"]="$op" ;;
        - | remove) unset 'mode[$abs]' ;;
      esac
    done <"$conf"
  fi

  # Emit parents before children so a nested bind always lands on top of its
  # parent (relevant for a ro root with a rw subdirectory).
  local -a keys
  mapfile -t keys < <(
    for abs in "${!mode[@]}"; do
      printf '%d\t%s\n' "$(tr -cd '/' <<<"$abs" | wc -c)" "$abs"
    done | sort -n -k1,1 -k2,2 | cut -f2-
  )

  TOOLCHAIN_MOUNT_MODE=()
  TOOLCHAIN_MOUNT_PATH=()
  for abs in "${keys[@]}"; do
    [ -n "$abs" ] || continue
    [ -e "$abs" ] || continue
    TOOLCHAIN_MOUNT_MODE+=("${mode[$abs]}")
    TOOLCHAIN_MOUNT_PATH+=("$abs")
  done

  mapfile -t TOOLCHAIN_PATH_DIRS < <(toolchain_path_dirs)
}
