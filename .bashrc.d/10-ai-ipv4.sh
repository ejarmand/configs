# Optional Claude launcher, installed by install-tools.sh --claude-ipv4. No desktop
# environment dependency. Functions also cover normal noninteractive SSH use.
if [[ -x $HOME/.local/bin/claude-ipv4 ]]; then
    claude() { "$HOME/.local/bin/claude-ipv4" "$@"; }
fi
