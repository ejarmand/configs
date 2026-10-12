# Configs
These are some config files, mostly for [neovim](https://neovim.io/), [starship](https://starship.rs/), and [wezterm](https://wezfurlong.org/wezterm/index.html).

They also hold my personal [Hyprkarl](https://github.com/ejarmand/hyprkarl) settings. Each one sits at its `~/.config/` path and loads over Hyprkarl's shipped defaults:

- `hypr/hyprland.local.lua`: Hyprland input, group borders, Wispr binding and autostarts
- `uwsm/env.local`: session environment (secrets go in the untracked `~/.config/uwsm/env.secrets`)
- `ghostty/local.conf`: Ghostty overrides
- `xdg-terminals.list`: default terminal
- `hyprkarl/apps/t3code.conf`: `hk-app` recipe for T3 Code

Run `./link.sh` to link everything into `~/.config/`.

## Shared Bash draft

The shared Bash draft replaces the old WSL startup file. `.bashrc` contains
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

`link.sh` does not install this draft. `migrate-bash.sh` links each shared
snippet separately, so other files in `~/.bashrc.d` remain local. The draft uses actual short
hostnames for known machine settings, and detects installed tools for shared
setup. No settings are invented for offline kalimba or inaccessible encoder.
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

Binaries are installed and updated by `install-tools.sh` (see below). This
draft only gives `~/.local/bin` precedence and initializes shell features for
installed tools; it does not restore old WSL paths or a fixed Mac PATH. The
draft and `install-tools.sh` both use Bash 3.2-compatible syntax.

### Local migration

Preview the Bash-only changes, then apply them:

```bash
bash ./migrate-bash.sh --dry-run
bash ./migrate-bash.sh --apply
```

The script backs up replaced files under
`${XDG_STATE_HOME:-~/.local/state}/configs/bash-backups/`, leaves unrelated
snippets and other configs alone, and installs the snippet links before the
`.bashrc` link. Keep this worktree while the links point to it. Open a new
terminal after applying. The existing local `.bash_profile` already reads
`.bashrc`; no profile replacement is needed.

To try the draft without replacing your own startup files, run this from the
repo in a disposable home. Exit the test shell to remove that home:

```bash
bash_draft_repo=$PWD
bash_draft_home=$(mktemp -d)
mkdir -p "$bash_draft_home/.bashrc.d"
ln -s "$bash_draft_repo/.bashrc" "$bash_draft_home/.bashrc"
for bash_draft_snippet in "$bash_draft_repo"/.bashrc.d/*.sh; do
  ln -s "$bash_draft_snippet" "$bash_draft_home/.bashrc.d/"
done
HOME="$bash_draft_home" bash --noprofile --rcfile "$bash_draft_home/.bashrc" -i
rm -rf -- "$bash_draft_home"
unset bash_draft_repo bash_draft_home bash_draft_snippet
```

## Storage machines

luogeng and yixing keep their data on a storage drive. On each one,
`05-machines.sh` gives the drive the same layout a home directory has:
`.local/share` for `XDG_DATA_HOME`, `.local/state` for `XDG_STATE_HOME`, and
`.cache` for `XDG_CACHE_HOME`. luogeng's root disk, which holds `/home` and
`/tmp`, is full, so `TMPDIR` is on its drive too.

Their older setups used the drive's `.local` itself as the data directory.
`migrations/<host>.sh` moves that data into the new layout, then runs
`migrate-bash.sh` and `install-tools.sh`, in that order. Preview first, then
apply:

```bash
bash ./migrations/luogeng.sh            # or yixing.sh
bash ./migrations/luogeng.sh --apply
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
