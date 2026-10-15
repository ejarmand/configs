# Shared helpers appear wherever their commands are installed.
if command -v sudo >/dev/null 2>&1 && command -v openconnect >/dev/null 2>&1; then
    alias vpn='sudo openconnect --authgroup="2-Step Secured - split" --protocol=anyconnect --user=earmand vpn.ucsd.edu'
    alias vpnall='sudo openconnect --authgroup="2-Step Secured - allthruucsd" --protocol=anyconnect --user=earmand vpn.ucsd.edu'
fi

if command -v sudo >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    dstat() {
        echo "Running containers:"
        sudo docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
        echo
        echo "All local images:"
        sudo docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
    }
fi

if command -v pkill >/dev/null 2>&1; then
    multikill() {
        if [[ $# != 1 || -z $1 ]]; then
            echo 'Usage: multikill <process-pattern>' >&2
            return 2
        fi
        command pkill -f -- "$1"
    }
fi

if [[ ${HOSTNAME%%.*} == mediator ]]; then
    if command -v htop >/dev/null 2>&1; then
        alias htop="LD_LIBRARY_PATH='' htop"
    fi
    if command -v claude >/dev/null 2>&1; then
        claudex() {
            local cliproxy_config="${CLIPROXY_CONFIG:-$HOME/.config/cliproxyapi/config.yaml}"
            local cliproxy_key

            if [ ! -r "$cliproxy_config" ]; then
                echo "claudex: cannot read CLIProxyAPI config: $cliproxy_config" >&2
                return 1
            fi

            cliproxy_key="$(awk '
                /^api-keys:/ { in_keys = 1; next }
                in_keys && /^[^[:space:]]/ { exit }
                in_keys && /^[[:space:]]*-[[:space:]]*/ {
                    key = $0
                    sub(/^[[:space:]]*-[[:space:]]*"?/, "", key)
                    sub(/"?[[:space:]]*$/, "", key)
                    print key
                    exit
                }
            ' "$cliproxy_config")"

            if [ -z "$cliproxy_key" ]; then
                echo "claudex: no client API key found in $cliproxy_config" >&2
                return 1
            fi

            ANTHROPIC_BASE_URL=http://127.0.0.1:8317 \
            ANTHROPIC_AUTH_TOKEN="$cliproxy_key" \
            ANTHROPIC_DEFAULT_OPUS_MODEL=gpt-5.6-sol \
            ANTHROPIC_DEFAULT_SONNET_MODEL=gpt-5.6-terra \
            ANTHROPIC_DEFAULT_HAIKU_MODEL=gpt-5.6-luna \
            CLAUDE_CODE_AUTO_MODE_MODEL=gpt-5.6-luna \
            CLAUDE_CODE_SUBAGENT_MODEL=gpt-5.6-terra \
            CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1 \
            CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3 \
            ENABLE_TOOL_SEARCH=false \
            command claude --model gpt-5.6-sol "$@"
        }
    fi
fi

if command -v notify-send >/dev/null 2>&1; then
    alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'
fi
