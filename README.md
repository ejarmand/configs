# Configs
These are some config files, mostly for [neovim](https://neovim.io/), [starship](https://starship.rs/), and [wezterm](https://wezfurlong.org/wezterm/index.html).

## Setup

From a persistent clone on Linux x86_64 or macOS arm64, run:

```bash
bash ./setup.sh
```

Use the same command for updates. It loads the existing machine settings,
prepares storage and applies any outstanding layout migration, installs or
updates tools, then links configs. It stops on a failed phase and reports it;
fix the error and rerun. Tool-specific setup, including Codex's sudo prompt
and the Claude IPv4 helper, stays in `install-tools.sh`.

Setup needs Git and the installer's download/build commands (`curl`, archive
and checksum tools, and `cc` for the Claude IPv4 hosts). It does not provision
an operating system or distribute credentials. Keep the clone in place while
configs link to it. Open a new shell after setup. Existing login profiles
are preserved; they must source `.bashrc` to load it in login shells.

`link.sh` owns Bash, Neovim, and Starship configuration placement. On Linux
with an installed Hyprkarl checkout (`$HYPRKARL_PATH`, defaulting to
`~/.local/share/hyprkarl`), it also links the desktop overrides listed below.
Those overrides are skipped on headless machines and macOS.

Conflicting managed files are moved into
`${XDG_STATE_HOME:-~/.local/state}/configs/config-backups/` before replacement.
Correct links need no changes. Bash snippets and Git-tracked Neovim files are
linked individually, preserving unrelated snippets, plugins, and the local
`lazy-lock.json`. When a config directory points into an older checkout,
linking copies its contents into a real local directory before replacing its
managed files, keeping the old checkout untouched. Directory links are saved
separately under the same backup directory.

The helpers remain available for focused maintenance, but `setup.sh` is the
normal entry point. New setup requirements belong in its ordered sequence.

Neovim's `lazy-lock.json` is local to each machine and ignored by Git. Before
pulling the commit that first removes the tracked lockfile on another machine,
preserve that machine's copy:

```bash
lazy_lock_backup=$(mktemp)
cp nvim/lazy-lock.json "$lazy_lock_backup"
git restore -- nvim/lazy-lock.json
git pull --ff-only
cp "$lazy_lock_backup" nvim/lazy-lock.json && rm "$lazy_lock_backup"
unset lazy_lock_backup
```

After that transition, later pulls leave the ignored local lockfile alone.

They also hold my personal [Hyprkarl](https://github.com/ejarmand/hyprkarl) settings. Each one sits at its `~/.config/` path and loads over Hyprkarl's shipped defaults:

- `hypr/hyprland.local.lua`: Hyprland input, group borders, Wispr binding and autostarts
- `uwsm/env.local`: session environment (secrets go in the untracked `~/.config/uwsm/env.secrets`)
- `ghostty/local.conf`: Ghostty overrides
- `xdg-terminals.list`: default terminal
- `hyprkarl/apps/t3code.conf`: `hk-app` recipe for T3 Code

`setup.sh` applies these overrides where Hyprkarl is installed.

## Shared Bash

The shared Bash configuration replaces the old WSL startup file. `.bashrc` contains
the PATH helper, history settings, shell options, and system completion.
It loads readable `~/.bashrc.d/*.sh` files in filename order:

- `05-machines.sh`: the audited storage, temp/cache, and PATH settings for
  mediator, luogeng, yixing, and the local pandiero desktop.
- `15-tools.sh`: optional Homebrew, Hyprkarl commands, Pixi, Cargo, Bun,
  micromamba, Conda, Vite+, nvm/fnm, and lesspipe setup, each implemented once.
- `20-aliases.sh`: GNU or macOS color options, `ll`/`la`/`l`, `gitls`, and
  `vi` plus editor defaults when Neovim is installed.
- `25-helpers.sh`: VPN, Docker, notification, and process helpers when their
  commands are available; mediator's htop workaround and CLIProxyAPI wrapper.
- `30-prompt.sh`: Starship when installed with a capable terminal, otherwise
  `user@host:directory`.

Environment variables, PATH, tool initialization, aliases, and functions apply
to noninteractive shells too. Only prompt setup requires an interactive shell.
Aliases are enabled for noninteractive shells with `expand_aliases`. Linux
`.profile` and macOS `.bash_profile` still need to source `.bashrc` for login
shells; the inspected machines already do this. Programs that launch Bash
without reading startup files still need to source `.bashrc` or set `BASH_ENV`.

`link.sh` installs the shared snippets individually, so other files in
`~/.bashrc.d` remain local. Known machine settings use actual short hostnames,
and shared tool setup detects installed tools. No settings are invented for
offline kalimba or inaccessible encoder.
The legacy `.bash_aliases` has been folded into the shared aliases and helpers.

Luogeng and yixing share the same XDG/Pixi redirection code with different
storage roots. Mediator retains its `/data` temp/cache and Apptainer locations.
`claudex` keeps mediator's model mappings and reads the proxy key on invocation.
Credential contents are not stored in this repo.

On cuica, nvm is preferred when both nvm and fnm exist, matching the manager
that loaded last previously. Micromamba and Conda are both retained. The shared
PATH helper avoids duplicate entries, and `~/.local/bin` is restored to the
front after optional tool hooks. `multikill` now uses `pkill -f` with a required,
nonempty process pattern instead of parsing `ps` output.

Binaries are installed and updated by `install-tools.sh` (see below). The Bash configuration
only gives `~/.local/bin` precedence and initializes shell features for
installed tools; it does not restore old WSL paths or a fixed Mac PATH. The
Bash configuration and `install-tools.sh` both use Bash 3.2-compatible syntax.

## Storage machines

luogeng and yixing keep their data on a storage drive. On each one,
`05-machines.sh` gives the drive the same layout a home directory has:
`.local/share` for `XDG_DATA_HOME`, `.local/state` for `XDG_STATE_HOME`, and
`.cache` for `XDG_CACHE_HOME`. luogeng's root disk, which holds `/home` and
`/tmp`, is full, so `TMPDIR` is on its drive too.

Their older setups used the drive's `.local` itself as the data directory.
`setup.sh` runs `migrations/<host>.sh --apply` before installing tools. These
helpers prepare storage only. They require the storage root to exist, and
record a successful migration in `.local/state/configs/storage-layout-v1` so
rerunning setup does not move newly created files in the old locations.
Known source/destination conflicts stop setup for manual reconciliation.
yixing moves recognized application data and leaves unknown or hidden entries
alone. luogeng moves the old less history and backs up its bare Starship binary.

You can inspect storage moves without applying them:

```bash
bash ./migrations/luogeng.sh            # or yixing.sh
```

## Tools

`install-tools.sh` installs Neovim, Codex, opencode, Starship, Pixi, uv, nvm
with Node LTS, Claude Code and the Cursor CLI, or updates them to their latest
release. It installs `rg` and `gh` only when they aren't already on PATH, and
keeps its own copies updated after that.

```bash
bash ./install-tools.sh
```

Each tool is unpacked under `${XDG_DATA_HOME:-~/.local/share}` (`neovim`,
`codex`, `opencode/cli`, `starship`, `pixi`, `uv/bin`, `ripgrep`, `gh/cli`) and
linked into `~/.local/bin`. On Linux `codex` is the fork's build; on macOS it's
upstream's. nvm goes in `$NVM_DIR`, and Claude Code and Cursor wherever their
own installers put them. Cursor's installer always writes to
`~/.local/share/cursor-agent`, so when the data directory is elsewhere, that path
is linked into it first. opencode is v2, which comes from npm rather than GitHub
releases.

The script loads `.bashrc.d/05-machines.sh` itself before installing anything,
so the storage-drive data directory and `NVM_DIR` on luogeng and yixing apply
even from a shell that hasn't read them. That file also picks the default
`NVM_DIR` for both the installer and `15-tools.sh`.

Rerunning skips tools that are already current. Downloads are checked against
the checksums the project publishes, where it publishes them. The script never edits shell
startup files; `.bashrc.d/15-tools.sh` already loads nvm. A real file in the
way in `~/.local/bin` is moved to
`${XDG_STATE_HOME:-~/.local/state}/configs/tool-backups/`. Older copies
elsewhere are left alone and listed at the end so you can remove them by hand.
It runs on Linux x86_64 and macOS arm64.

On Linux, the script links Codex's bundled `bwrap` into `~/.local/bin` so Codex
uses the version shipped in its package. On Ubuntu hosts with AppArmor's
unprivileged user namespace restriction enabled, it uses sudo to copy that
binary into `/usr/local/lib/codex/bwrap` and load `/etc/apparmor.d/codex-bwrap`.
The profile adapts Ubuntu's `bwrap-userns-restrict` profile to this root-owned
path and keeps the child capability restrictions. The install step lives in
`install/codex-sandbox.sh`. It checks the packages, helper, profile, and sandbox
execution first. If setup is needed, it reports what is missing and asks before
running its `setup` subcommand with sudo. That step installs missing `apparmor`
and `apparmor-profiles` packages, updates the protected helper, and loads the
profile. Ubuntu's `bubblewrap` and `apparmor-utils` packages are not required.
Rerunning a configured installation does not prompt or invoke sudo. Declining
setup, or running without an answer on stdin, leaves Codex marked as failed
while the full installer continues with the other tools.

To configure only Codex's sandbox without updating any tools, run:

```bash
./install-tools.sh --codex-sandbox
```

To check the sandbox without changing its setup:

```bash
./install-tools.sh --check-codex-sandbox
```

The check exits successfully only when the helper and profile are current and
the sandbox smoke test passes. These sandbox commands do not update the IPv4
configuration.

On pandiero, tumba and qinto, the script also makes Codex connect over IPv4
only. It adds the fork's `ip_family = "ipv4"` to the top of
`${CODEX_HOME:-~/.codex}/config.toml`, unless the file already sets
`ip_family`, in which case that setting is kept.

### Claude IPv4 workaround

On pandiero, tumba and qinto, ordinary `bash ./install-tools.sh` also installs
`claude-ipv4` after installing or updating native Claude. It requires `cc` and
a dynamically linked glibc binary. Other machines keep their normal networking.
Codex continues to use its native `ip_family` setting.

The existing `15-tools.sh` snippet routes Bash's `claude` command through the
launcher when installed. Open a new shell after setup. For T3 or another GUI
launcher, select the absolute `~/.local/bin/claude-ipv4` path and restart the
provider. Native Claude updates retain ownership of `~/.local/bin/claude`.

The launcher and library live together under
`${XDG_DATA_HOME:-~/.local/share}/configs/claude-ipv4`, so GUI launches do not
need the shell's XDG settings. The library restricts Claude's external
connections to IPv4, preserves local IPv6 loopback, and does not propagate to
commands Claude launches. IPv6-only services may be unreachable from Claude.

To disable it until the next tool installation, remove
`~/.local/bin/claude-ipv4`, open a new shell, and restore the native Claude
executable path in GUI launchers.

Run `python3 network/check-claude-ipv4-install.py` for offline installation
checks. The socket check is `network/check-ai-ipv4.py`, run with the installed
`ai-ipv4.so` in `LD_PRELOAD` and `AI_IPV4_PREVIOUS_PRELOAD` empty.

## Offline checks

Run `python3 tests/check-setup.py` to exercise setup ordering, failures,
reruns, config adoption, and storage migrations in disposable homes. It stubs
tool downloads rather than changing the current machine. The existing network
checks above exercise the tool-specific IPv4 installation separately.
