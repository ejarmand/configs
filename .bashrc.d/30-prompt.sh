if [[ -z ${STARSHIP_CONFIG-} && -r ${XDG_STATE_HOME:-$HOME/.local/state}/hyprkarl/starship.toml ]]; then
    export STARSHIP_CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/hyprkarl/starship.toml"
fi

if [[ $- == *i* ]]; then
    PS1='\u@\h:\w\$ '
    if [[ ${TERM:-dumb} != dumb ]] && command -v starship >/dev/null 2>&1; then
        eval "$(starship init bash)"
    fi
fi
