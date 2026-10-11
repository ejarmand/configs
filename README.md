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

Binary installation and updates belong to issue #3. This draft only gives
`~/.local/bin` precedence and initializes shell features for installed tools;
it does not restore old WSL paths or a fixed Mac PATH. Until issue #3 is done,
opencode's old directory is used only if no opencode binary is otherwise found.
It uses Bash 3.2-compatible syntax; the installer planned in #3 requires Bash 4+.

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
