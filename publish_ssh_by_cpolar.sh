#!/bin/bash

# Publish the local SSH service through cpolar in the background.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/publish_ssh_by_cpolar.log"
PID_FILE="${LOG_DIR}/publish_ssh_by_cpolar.pid"

if ! CPOLAR_BIN="$(command -v cpolar)"; then
    echo "Error: cpolar is not installed or is not available in PATH." >&2
    exit 1
fi

mkdir -p -- "${LOG_DIR}"

if [ -f "${PID_FILE}" ]; then
    existing_pid="$(cat -- "${PID_FILE}")"
    if [[ "${existing_pid}" =~ ^[0-9]+$ ]] && kill -0 "${existing_pid}" 2>/dev/null; then
        echo "cpolar SSH tunnel is already running (PID ${existing_pid})."
        echo "Log file: ${LOG_FILE}"
        exit 0
    fi
    rm -f -- "${PID_FILE}"
fi

{
    printf '\n[%s] Starting: cpolar tcp 22\n' "$(date '+%Y-%m-%d %H:%M:%S')"
} >>"${LOG_FILE}"

nohup "${CPOLAR_BIN}" tcp 22 >>"${LOG_FILE}" 2>&1 < /dev/null &
cpolar_pid=$!
printf '%s\n' "${cpolar_pid}" >"${PID_FILE}"

# Catch immediate startup failures while keeping normal execution in background.
sleep 1
if ! kill -0 "${cpolar_pid}" 2>/dev/null; then
    rm -f -- "${PID_FILE}"
    echo "Error: cpolar failed to start. Check the log: ${LOG_FILE}" >&2
    exit 1
fi

echo "cpolar SSH tunnel started in the background (PID ${cpolar_pid})."
echo "Log file: ${LOG_FILE}"
