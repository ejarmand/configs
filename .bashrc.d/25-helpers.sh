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

if command -v nvidia-smi >/dev/null 2>&1; then
    # Summarize GPU use per user; -v groups by process group, -vv lists processes.
    whogpu() {
        local verbose=0 arg apps pids pgids header
        for arg; do
            case $arg in
                --verbose) verbose=$((verbose + 1)) ;;
                -h|--help)
                    echo 'Usage: whogpu [-v|-vv]  (-v: per process group, -vv: per process)'
                    return 0
                    ;;
                *)
                    if [[ $arg =~ ^-v+$ ]]; then
                        verbose=$((verbose + ${#arg} - 1))
                    else
                        echo 'Usage: whogpu [-v|-vv]  (-v: per process group, -vv: per process)' >&2
                        return 2
                    fi
                    ;;
            esac
        done
        ((verbose > 2)) && verbose=2

        apps="$(command nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader,nounits)" || return
        if [ -z "$apps" ]; then
            echo 'No GPU processes running.'
            return 0
        fi
        pids="$(cut -d, -f2 <<<"$apps" | tr -d ' ' | grep -E '^[0-9]+$' | sort -u | paste -sd,)"
        [ -n "$pids" ] && pgids="$(ps -o pgid= -p "$pids" | tr -d ' ' | sort -u | paste -sd,)"

        case $verbose in
            0) header='user\tgpu(s)\tmemory (mean)\tmemory (total)' ;;
            1) header='user\tpgid\tgpu(s)\tmemory (mean)\tmemory (total)\tcommand' ;;
            2) header='user\tpid\tppid\tgpu(s)\tmemory (mean)\tmemory (total)\tcommand' ;;
        esac

        {
            printf "$header\n"
            {
                command nvidia-smi --query-gpu=index,uuid --format=csv,noheader | tr -d , | sed 's/^/G /'
                [ -n "$pids" ] && ps -o pid=,ppid=,pgid=,user:32=,args= -p "$pids" | sed 's/^ */P /'
                [ -n "$pgids" ] && ps -o pid=,args= -p "$pgids" | sed 's/^ */L /'
                tr -d , <<<"$apps" | sed 's/^/A /'
            } | awk -v level="$verbose" '
                function size(mib) {
                    if (mib >= 10240) return sprintf("%dg", mib / 1024 + 0.5)
                    if (mib >= 1024) return sprintf("%.1fg", mib / 1024)
                    return sprintf("%dm", mib)
                }
                $1 == "G" { order[ngpus++] = $2; gpu[$3] = $2; next }
                $1 == "P" {
                    ppid[$2] = $3; pgid[$2] = $4; user[$2] = $5
                    cmd = $0; sub(/^P +[0-9]+ +[0-9]+ +[0-9]+ +[^ ]+ +/, "", cmd); args[$2] = cmd
                    next
                }
                $1 == "L" { cmd = $0; sub(/^L +[0-9]+ +/, "", cmd); leader[$2] = cmd; next }
                $1 == "A" {
                    pid = $3
                    u = (pid in user) ? user[pid] : "?"
                    if (level == 0) {
                        key = u; label[key] = u
                    } else if (level == 1) {
                        g = (pid in pgid) ? pgid[pid] : "?"
                        key = u SUBSEP g
                        label[key] = u "\t" g
                        command[key] = (g in leader) ? leader[g] : ((pid in args) ? args[pid] : "?")
                    } else {
                        key = u SUBSEP pid
                        label[key] = u "\t" pid "\t" ((pid in ppid) ? ppid[pid] : "?")
                        command[key] = (pid in args) ? args[pid] : "?"
                    }
                    idx = ($2 in gpu) ? gpu[$2] : "?"
                    if (!((key, idx) in used)) { used[key, idx] = 1; count[key]++ }
                    if ($4 ~ /^[0-9]+$/) total[key] += $4; else unknown[key] = 1
                }
                END {
                    for (key in label) {
                        list = ""
                        for (i = 0; i < ngpus; i++)
                            if ((key, order[i]) in used) list = list (list == "" ? "" : ",") order[i]
                        if ((key, "?") in used) list = list (list == "" ? "" : ",") "?"
                        if (key in unknown) { mean = "?"; sum = "?" }
                        else { mean = size(total[key] / count[key]); sum = size(total[key]) }
                        row = label[key] "\t" list "\t" mean "\t" sum
                        if (level > 0) row = row "\t" command[key]
                        print row
                    }
                }
            ' | sort -t "$(printf '\t')" -k1,1 -k2,2n
        } | column -t -s "$(printf '\t')" | if [ -t 1 ]; then cut -c "1-${COLUMNS:-$(tput cols)}"; else cat; fi
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
