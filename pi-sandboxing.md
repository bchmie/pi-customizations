# Sandboxing Pi — summary

How to run Pi on projects with a filesystem security boundary, and the design
that came out of discussing it. Two interchangeable launchers are provided:

- **`pi-sandbox`** — [bubblewrap](https://github.com/containers/bubblewrap)
  (unprivileged mount namespaces, no image, uses the host's tools directly)
- **`pi-podman`** — [Podman](https://podman.io) (rootless container,
  minimal image, isolated root filesystem)

Both are installed as symlinks in `~/.local/bin` and run from the project
directory they should sandbox.

```console
$ cd ~/Projects/some-project
$ pi-sandbox                 # or: pi-podman
$ pi-sandbox -p "..."       # arguments pass through to pi
$ pi-sandbox -c              # --continue works (shared session history)
```

## Threat model

Pi does not ask for tool approval; every tool call and model-generated command
runs with the permissions of the OS user that started it (see Pi's
`security.md`). We are not worried about credential exfiltration or network
restriction — the goal is:

> The agent must not be able to **read or modify anything outside the current
> project** — system files, `~/.ssh`, `~/.gnupg`, browser profiles, tokens
> under `~/.config`, and all *other* projects.

What an unprivileged agent can actually reach: every file the user can read
(the real secrets are under `$HOME`, not `/etc`), and every file it can write
(home contents, shell rc files, user systemd units, crontab). Note that
watching the transcript, project trust, and reviewing diffs are **not**
security boundaries; only OS-level isolation is.

## The boundary both launchers enforce

| Resource | Access |
|---|---|
| Current project directory | read-write (mounted at the **same absolute path**, so sessions group identically to host runs) |
| `~/.pi/agent/sessions` | read-write — `pi --continue` / `--resume` work normally and interleave with host history |
| `~/.pi/agent/trust.json` | read-write — project-trust decisions persist |
| `~/.pi-sandbox-home` | read-write — persistent sandbox home, **shared by both variants** |
| `auth.json`, `extensions/`, `npm/`, `bin/`, `install/` | read-only — single source of truth; the sandbox cannot tamper with Pi's own config, extensions, or credential |
| Host dev toolchains (`uv`, `cargo`, `nvm`, `pyenv`, `mise`, …) | read-only, mounted at their **original absolute paths** — see "Host toolchains" below |
| `settings.json`, `models-store.json` | **fresh copy each launch** — see "lock dirs" below |
| Everything else under `$HOME` (incl. `~/.cache`, and credential files like `~/.npmrc`, `~/.cargo/credentials.toml`) | hidden (bwrap: shadowed by a tmpfs; Podman: simply not mounted) |
| `/etc`, `/usr`, rest of the system | read-only (bwrap) / container root filesystem (Podman) |
| `/tmp`, `/run` | ephemeral |
| Network | **not isolated** — shares the host network namespace (bwrap) / rootless `pasta` networking (Podman), so the provider API (`opencode.ai`) is reachable |

In the bwrap variant the system is mounted as an explicit **allowlist**
(`/usr` + `/etc` only): `/var`, `/opt`, `/srv` are not mounted at all.

## Host toolchains (uv, cargo, nvm, …)

The sandboxes hide `$HOME`, but host dev toolchains live there and create
**absolute** symlinks. A uv venv, for example, records:

```
.venv/bin/python -> $HOME/.local/share/uv/python/cpython-3.13.5-…/bin/python3.13
```

With `.venv` bind-mounted from the project but `$HOME/.local/share/uv` hidden,
that symlink dangles and `.venv/bin/pytest` cannot exec — the failure that
motivated this layer. (`uv venv --relocatable` does **not** help: the symlink is
still absolute.)

`sandbox-toolchains.sh` fixes this by mounting a curated set of install roots
**read-only at their original absolute paths**. Because the path is identical on
both sides, absolute symlinks resolve, and anything the sandbox creates (a venv,
a virtualenv) records paths that are also valid on the host.

- **Defaults:** `~/.local/bin`, `~/.local/share/uv`, `~/.local/share/pipx`,
  `~/.local/share/{mise,pnpm,fnm,virtualenvs,asdf}`, `~/.cargo/bin`,
  `~/.rustup`, `~/.nvm`, `~/.pyenv`, `~/.bun/bin`, `~/.deno/bin`,
  `~/.volta/bin`, `~/.npm-global/bin`, `~/.dotnet`, `~/.sdkman/candidates`,
  `~/go/bin`. Off-default install locations are picked up from
  `UV_PYTHON_INSTALL_DIR`, `CARGO_HOME`-adjacent vars, `GOPATH`, etc.
- **Credential files are deliberately excluded** — `~/.cargo` is exposed only as
  `bin/` (the rustup shims), so `~/.cargo/credentials.toml`, `~/.npmrc`,
  `~/.m2/settings.xml`, `~/.config/pip`, `~/.config/uv`, `~/.netrc` stay hidden.
- **Caches stay sandbox-local.** `~/.cache/uv`, `~/.cache/pip`, etc. resolve
  under the sandbox home (which shadows the real `$HOME`), so `uv sync`,
  `uv run`, `cargo build` and friends work without writing to the host.
- **Override per machine:** `${XDG_CONFIG_HOME:-~/.config}/pi-sandbox/toolchains.conf`,
  one entry per line — `ro <path>`, `rw <path>`, or `- <path>` to drop a default.
  Paths are absolute or relative to `$HOME`. Example to allow installing a new
  interpreter/tool (writes persist to the host):

  ```
  rw .local/share/uv
  - .dotnet
  ```

`pi-podman` additionally sets the container's home to the **host's `$HOME`**
(not `/root`) so that both the sandbox home and every toolchain mount keep the
same absolute path as on the host. That is what makes the symlinks portable in
both directions.

## Findings that shaped the design

1. **Pi's own runtime lives under `$HOME`.** The `pi` launcher is
   `~/.pi/agent/bin/pi`, a shell script that reads `install/current-version`
   and executes `install/releases/<ver>/node_modules/.bin/pi` with a bundled
   Node runtime from `~/.local/share/pi-node`. Any sandbox must bind
   `bin/`, `install/` (bwrap) or provide a Node image (Podman), or `pi`
   cannot start at all.
2. **Lock dirs.** Pi creates `<file>.lock` *directories* next to
   `settings.json` and `models-store.json`. With those mounted read-only the
   lock fails, Pi discards its settings, falls back to the default provider,
   and reports "No API key found for the selected model". Hence the
   fresh-copy-per-launch approach: copies live in the writable sandbox home,
   refreshed from the host on every run, so host settings changes are always
   picked up.
3. **DNS.** `/etc/resolv.conf` is a symlink into `/run/systemd/resolve/`
   (systemd-resolved). Since `/run` is an ephemeral tmpfs, that dir must be
   re-bound read-only — **after** the `--tmpfs /run` that covers it — or every
   connection fails with "Connection error".
4. **Mount order matters in bwrap.** Every bind exception must come after
   the mount that covers its parent. An early version bound the project
   before `--tmpfs /tmp` and writes silently vanished.
5. **`/home` is a separate btrfs subvolume** on this machine, so
   `--ro-bind / /` never even sees it; the tmpfs-over-`$HOME` shadow is
   belt-and-braces.
6. **Session grouping.** Pi groups sessions under
   `~/.pi/agent/sessions/--<cwd>--/`. Both launchers mount the project at its
   original absolute path (in Podman: `-v "$PWD:$PWD" -w "$PWD"`) so
   sandboxed runs land in exactly the same history bucket as host runs.
7. **Option chosen for sessions:** the sandbox shares the host's
   `~/.pi/agent/sessions` (full `--continue`/`--resume` parity, sessions
   interleaved with host history). The alternative — a sandbox-only history
   via a separate state dir — was rejected, but is a one-line change.
8. **Host toolchains create absolute symlinks.** Hiding `$HOME` breaks
   host-created venvs even when `.venv` is bind-mounted. The fix is to expose
   the install roots read-only at their original paths — and, in Podman, to
   mount the state at the host `$HOME` path rather than `/root` so the paths
   line up. See "Host toolchains" above.

## bwrap vs Podman

| | `pi-sandbox` (bwrap) | `pi-podman` (Podman) |
|---|---|---|
| Startup latency | instant | instant after first `podman build` (~1 min, needs network) |
| Isolation | unprivileged user/pid/ipc/uts/cgroup namespaces | full container namespaces + image layering |
| Tools available | host tools + host dev toolchains (read-only) | image tools (`git`, `ripgrep`) + host dev toolchains (read-only) |
| Home path | `$HOME` (sandbox home shadows it) | `$HOME` (host path; **not** `/root`, so absolute toolchain symlinks resolve) |
| Pi version | always identical to host (bind-mounted) | always identical to host (bind-mounted) |
| Filesystem allowlist | explicit: `/usr`, `/etc` | container rootfs; host not mounted except listed binds |
| SELinux | n/a (no container) | `label=disable` — avoids relabeling host files (`:Z` would relabel `$PWD` and `~/.pi/agent` on the host) |
| Leftovers | `~/.pi-sandbox-home` | same, plus the `pi-sandbox` image and normal podman storage |

Both share the same `~/.pi-sandbox-home` state dir, so caches and any sandbox
state accumulate in one place regardless of which launcher is used.

## Known limitations

- **Network is open.** A model-generated command can reach the internet and
  can read `auth.json` (it must, to authenticate). If this ever becomes a
  concern: filter egress to the provider endpoint (nftables around the run),
  or keep the real key outside the sandbox behind a local proxy that holds
  it and forwards to the provider — the design Pi's `containerization.md`
  documents as "Docker Sandboxes" / "OpenShell" inference routing.
- **Installing new toolchains needs a `rw` mount.** Toolchain roots are
  read-only by default, so `uv python install`, `uv tool install`, `uvx`,
  `rustup update`, `pipx install` fail unless the relevant root is flipped to
  `rw` in `toolchains.conf` (which lets writes escape the project boundary).
  `uv sync` / `uv run` / `cargo build` do **not** need this — they only write
  to the venv and to sandbox-local caches.
- **Podman glibc skew.** The image is Debian, the host is Fedora. uv and
  uv-managed Pythons are built for old glibc and run fine; most Rust and Go
  binaries do too. But a host binary linked against a *newer* glibc than the
  container's will not run there. bwrap has no skew (host binaries).
- **Package installs don't persist.** `pi package add` / new extensions
  inside the sandbox write to read-only mounts; run those unsandboxed.
- **MCP is not exposed.** `mcp.json` / `mcp-auth.json` are not mounted; add
  binds if MCP servers are ever used.
- **`models-store.json` refresh** writes go to the sandbox-home copy; the
  host copy is refreshed only by host runs.
- The first run inside a project with a `.pi/` directory will re-ask for
  project trust if no `trust.json` bind exists yet (the decision is saved
  once it exists and is then shared).

## References

Pi docs (under `~/.pi/agent/install/releases/<ver>/node_modules/@earendil-works/pi-coding-agent/docs/`):
`security.md` (threat model, project trust), `containerization.md`
(isolation options), `configuration.md` (agent directory layout),
`sessions.md` / `session-format.md` (session storage and resume).
