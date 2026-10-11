# Homebrew can live outside the inherited PATH on Linux and macOS.
_bashrc_brew=
if command -v brew >/dev/null 2>&1; then
    _bashrc_brew=$(command -v brew)
else
    for _bashrc_candidate in /home/linuxbrew/.linuxbrew/bin/brew /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [[ -x $_bashrc_candidate ]]; then
            _bashrc_brew=$_bashrc_candidate
            break
        fi
    done
fi
if [[ -n $_bashrc_brew ]] && _bashrc_hook=$("$_bashrc_brew" shellenv 2>/dev/null); then
    eval "$_bashrc_hook"
fi
if [[ -n ${HOMEBREW_PREFIX-} && -d $HOMEBREW_PREFIX/opt/grep/libexec/gnubin ]]; then
    bashrc_prepend_path "$HOMEBREW_PREFIX/opt/grep/libexec/gnubin"
fi

if [[ -d ${HYPRKARL_PATH:-$HOME/.local/share/hyprkarl}/bin ]]; then
    bashrc_prepend_path "${HYPRKARL_PATH:-$HOME/.local/share/hyprkarl}/bin"
fi

if [[ -d ${PIXI_HOME:-$HOME/.pixi}/bin ]]; then
    bashrc_prepend_path "${PIXI_HOME:-$HOME/.pixi}/bin"
fi
if [[ -r $HOME/.cargo/env ]]; then
    . "$HOME/.cargo/env"
fi
if [[ -d ${BUN_INSTALL:-$HOME/.bun}/bin ]]; then
    export BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
    bashrc_prepend_path "$BUN_INSTALL/bin"
fi

if _bashrc_mamba=$(type -P micromamba); then
    # The hook defines a micromamba function. Keep MAMBA_EXE pointing to the
    # executable when this file is sourced again.
    export MAMBA_EXE=$_bashrc_mamba
    if [[ -n ${MAMBA_ROOT_PREFIX-} ]]; then
        _bashrc_hook=$("$MAMBA_EXE" shell hook --shell bash --root-prefix "$MAMBA_ROOT_PREFIX" 2>/dev/null) || _bashrc_hook=
    else
        _bashrc_hook=$("$MAMBA_EXE" shell hook --shell bash 2>/dev/null) || _bashrc_hook=
    fi
    if [[ -n $_bashrc_hook ]]; then
        eval "$_bashrc_hook"
    fi
fi

_bashrc_conda=
if [[ -x $HOME/.env/miniconda3/bin/conda ]]; then
    _bashrc_conda="$HOME/.env/miniconda3/bin/conda"
elif _bashrc_conda=$(type -P conda); then
    :
fi
if [[ -n $_bashrc_conda ]]; then
    if _bashrc_hook=$("$_bashrc_conda" shell.bash hook 2>/dev/null); then
        eval "$_bashrc_hook"
    elif [[ -r ${_bashrc_conda%/bin/conda}/etc/profile.d/conda.sh ]]; then
        . "${_bashrc_conda%/bin/conda}/etc/profile.d/conda.sh"
    elif [[ -d ${_bashrc_conda%/conda} ]]; then
        bashrc_prepend_path "${_bashrc_conda%/conda}"
    fi
fi

if [[ -r $HOME/.vite-plus/env ]]; then
    . "$HOME/.vite-plus/env"
fi

# Keep Vite+ before nvm, matching the current local .bashrc.
# nvm loaded last in cuica's old config. Prefer it when both managers exist.
if [[ -z ${NVM_DIR-} ]]; then
    NVM_DIR="$HOME/.nvm"
    if [[ -r /usr/share/nvm/init-nvm.sh && -n ${XDG_CONFIG_HOME-} ]]; then
        NVM_DIR="$XDG_CONFIG_HOME/nvm"
    fi
fi
export NVM_DIR
if [[ -s $NVM_DIR/nvm.sh ]]; then
    . "$NVM_DIR/nvm.sh"
    if [[ -s $NVM_DIR/bash_completion ]]; then
        . "$NVM_DIR/bash_completion"
    elif [[ -r /usr/share/nvm/bash_completion ]]; then
        . /usr/share/nvm/bash_completion
    fi
else
    if [[ -x $HOME/.local/share/fnm/fnm ]]; then
        bashrc_prepend_path "$HOME/.local/share/fnm"
    fi
    if command -v fnm >/dev/null 2>&1 && _bashrc_hook=$(fnm env --shell bash 2>/dev/null); then
        eval "$_bashrc_hook"
    fi
fi

# Keep opencode usable until issue #3 provides the shared binary link.
if ! type -P opencode >/dev/null 2>&1 && [[ -x $HOME/.opencode/bin/opencode ]]; then
    bashrc_prepend_path "$HOME/.opencode/bin"
fi

if command -v lesspipe >/dev/null 2>&1 && _bashrc_hook=$(SHELL=/bin/sh lesspipe 2>/dev/null); then
    eval "$_bashrc_hook"
fi

# Resolve aliases and the prompt against the shared binaries, after tool hooks.
bashrc_prepend_path "$HOME/.local/bin"
unset _bashrc_brew _bashrc_candidate _bashrc_conda _bashrc_mamba _bashrc_hook
