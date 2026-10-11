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
| `~/.pi/sandbox-home` | read-write — persistent sandbox home, **shared by both variants** |
| `auth.json`, `extensions/`, `npm/`, `bin/`, `install/` | read-only — single source of truth; the sandbox cannot tamper with Pi's own config, extensions, or credential |
| `settings.json`, `models-store.json` | **fresh copy each launch** — see "lock dirs" below |
| Everything else under `$HOME` | hidden (bwrap: shadowed by a tmpfs; Podman: simply not mounted) |
| `/etc`, `/usr`, rest of the system | read-only (bwrap) / container root filesystem (Podman) |
| `/tmp`, `/run` | ephemeral |
| Network | **not isolated** — shares the host network namespace (bwrap) / rootless `pasta` networking (Podman), so the provider API (`opencode.ai`) is reachable |

In the bwrap variant the system is mounted as an explicit **allowlist**
(`/usr` + `/etc` only): `/var`, `/opt`, `/srv` are not mounted at all.

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

## bwrap vs Podman

| | `pi-sandbox` (bwrap) | `pi-podman` (Podman) |
|---|---|---|
| Startup latency | instant | instant after first `podman build` (~1 min, needs network) |
| Isolation | unprivileged user/pid/ipc/uts/cgroup namespaces | full container namespaces + image layering |
| Tools available | host tools (`git`, `rg`, compilers) read-only | only what's in the image (git, ripgrep; extend `Containerfile`) |
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
