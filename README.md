# Configs
These are some config files, mostly for [neovim](https://neovim.io/), [starship](https://starship.rs/), and [wezterm](https://wezfurlong.org/wezterm/index.html).

They also hold my personal [Hyprkarl](https://github.com/ejarmand/hyprkarl) settings. Each one sits at its `~/.config/` path and loads over Hyprkarl's shipped defaults:

- `hypr/hyprland.local.lua`: Hyprland input, group borders, Wispr binding and autostarts
- `uwsm/env.local`: session environment (secrets go in the untracked `~/.config/uwsm/env.secrets`)
- `ghostty/local.conf`: Ghostty overrides
- `xdg-terminals.list`: default terminal
- `hyprkarl/apps/t3code.conf`: `hk-app` recipe for T3 Code

Run `./link.sh` to link everything into `~/.config/`.
