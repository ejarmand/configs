# Shared Bash settings apply to interactive shells and SSH/script shells.
bashrc_prepend_path() {
    local path=":${PATH-}:"
    while [[ $path == *":$1:"* ]]; do
        path=${path/":$1:"/:}
    done
    path=${path#:}
    path=${path%:}
    export PATH="$1${path:+:$path}"
}
bashrc_prepend_path "$HOME/.local/bin"

HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend checkwinsize expand_aliases

# Avoid loading completion twice when the system already initialized it.
if ! shopt -oq posix && [[ -z ${BASH_COMPLETION_VERSINFO-} ]]; then
    for _bashrc_completion in /usr/share/bash-completion/bash_completion /etc/bash_completion; do
        if [[ -r $_bashrc_completion ]]; then
            . "$_bashrc_completion"
            break
        fi
    done
    unset _bashrc_completion
fi

for _bashrc_snippet in "$HOME"/.bashrc.d/*.sh; do
    [[ -f $_bashrc_snippet && -r $_bashrc_snippet ]] || continue
    . "$_bashrc_snippet"
done
unset _bashrc_snippet

# Optional tool hooks can prepend their own binaries.
bashrc_prepend_path "$HOME/.local/bin"
