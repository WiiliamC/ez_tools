#!/bin/bash
# Usage: ./run_in_backend.sh <command> [args...] <log_file>
# Runs a command in the background and redirects stdout/stderr to a log file.

set -euo pipefail

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <command> [args...] <log_file>" >&2
    echo "Example: $0 python3 app.py /tmp/app.log" >&2
    echo "For shell syntax: $0 bash -lc 'npm run dev | cat' /tmp/dev.log" >&2
    exit 1
fi

log_file="${!#}"
cmd=("${@:1:$#-1}")

log_dir="$(dirname -- "$log_file")"
mkdir -p -- "$log_dir"

nohup "${cmd[@]}" > "$log_file" 2>&1 < /dev/null &
pid=$!

echo "Started PID $pid"
echo "Log file: $log_file"
