# Use GNU color options only when the selected command supports them.
if command ls --color=auto -d / >/dev/null 2>&1; then
    alias ls='ls --color=auto'
    if command -v dircolors >/dev/null 2>&1; then
        if [[ -r $HOME/.dircolors ]]; then
            eval "$(dircolors -b "$HOME/.dircolors")"
        else
            eval "$(dircolors -b)"
        fi
    fi
elif [[ $(uname -s) == Darwin ]]; then
    alias ls='ls -G'
fi

if command grep --color=auto --help >/dev/null 2>&1; then
    alias grep='grep --color=auto'
    alias fgrep='grep -F --color=auto'
    alias egrep='grep -E --color=auto'
fi

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
if command -v nvim >/dev/null 2>&1; then
    alias vi='nvim'
    export EDITOR=nvim
    export VISUAL=nvim
fi

alias gitls='git ls-tree -r --name-only -z HEAD | xargs -0 -I{} git log -1 --format="%ai %an {}" -- "{}"'
