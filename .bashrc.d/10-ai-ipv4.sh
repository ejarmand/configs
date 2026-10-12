# User-level Linux launchers, installed by install-ai-ipv4.sh. No desktop
# environment dependency. Functions also cover normal noninteractive SSH use.
if [[ -x $HOME/.local/bin/codex-ipv4 ]]; then
    codex() { "$HOME/.local/bin/codex-ipv4" "$@"; }
fi
if [[ -x $HOME/.local/bin/claude-ipv4 ]]; then
    claude() { "$HOME/.local/bin/claude-ipv4" "$@"; }
fi
