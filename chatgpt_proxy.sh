#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == '-h' || ${1:-} == '--help' ]]; then
    echo "Usage: $0 [PORT] [CHATGPT_ARGS...]"
    echo "Launch chatgpt with an HTTP proxy on localhost (default port: 7890)."
    exit 0
fi

port=${1:-7890}
if (( $# > 0 )); then
    shift
fi

if [[ ! $port =~ ^[0-9]{1,5}$ ]]; then
    echo "Error: port must be an integer from 1 to 65535." >&2
    exit 1
fi
port=$((10#$port))
if (( port < 1 || port > 65535 )); then
    echo "Error: port must be an integer from 1 to 65535." >&2
    exit 1
fi

exec chatgpt "--proxy-server=http://127.0.0.1:$port" "$@"
