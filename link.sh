#!/bin/bash
# Link these configs into ~/.config. Safe to rerun: an existing link is
# replaced, but a real file is left alone so nothing personal is lost.

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}

links=(
  nvim
  starship.toml
  hypr/hyprland.local.lua
  uwsm/env.local
  ghostty/local.conf
  xdg-terminals.list
  hyprkarl/apps/t3code.conf
)

status=0
for path in "${links[@]}"; do
  target="$CONFIG_HOME/$path"
  if [[ -e "$target" && ! -L "$target" ]]; then
    printf 'Skipping %s: a real file is there; move it into %s first.\n' "$target" "$REPO" >&2
    status=1
    continue
  fi
  mkdir -p "$(dirname "$target")"
  ln -sfn "$REPO/$path" "$target"
done
exit $status
