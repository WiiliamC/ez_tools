#!/bin/bash

# Enable the vendor-managed cpolar service after validating its SSH tunnel.

set -euo pipefail

CONFIG_FILE="/usr/local/etc/cpolar/cpolar.yml"
SERVICE_NAME="cpolar.service"

if [ "${CPOLAR_TEST_MODE:-}" = "1" ]; then
    CONFIG_FILE="${CPOLAR_CONFIG_FILE:-${CONFIG_FILE}}"
    SERVICE_NAME="${CPOLAR_SERVICE_NAME:-${SERVICE_NAME}}"
    CPOLAR_COMMAND="${CPOLAR_BIN:-cpolar}"
    SYSTEMCTL_COMMAND="${SYSTEMCTL_BIN:-systemctl}"
else
    CPOLAR_COMMAND="cpolar"
    SYSTEMCTL_COMMAND="systemctl"
fi

failure_help() {
    cat >&2 <<EOF
Check the service with:
  systemctl status cpolar
  journalctl -u cpolar
  /var/log/cpolar/access.log
EOF
}

fail() {
    echo "Error: $*" >&2
    failure_help
    exit 1
}

fail_config() {
    cat >&2 <<EOF
Error: $*
Add this tunnel to the existing configuration (do not replace or expose its authtoken):

tunnels:
  ssh:
    proto: tcp
    addr: "22"
EOF
    failure_help
    exit 1
}

if ! CPOLAR_BIN_PATH="$(command -v "${CPOLAR_COMMAND}")"; then
    fail "cpolar is not installed or is not available in PATH."
fi

if ! SYSTEMCTL_BIN_PATH="$(command -v "${SYSTEMCTL_COMMAND}")"; then
    fail "systemctl is not installed or is not available in PATH."
fi

if [ "${EUID}" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
    fail "sudo is required to manage ${SERVICE_NAME} when not running as root."
fi

run_systemctl() {
    if [ "${CPOLAR_TEST_MODE:-}" = "1" ] || [ "${EUID}" -eq 0 ]; then
        "${SYSTEMCTL_BIN_PATH}" "$@"
    else
        sudo "${SYSTEMCTL_BIN_PATH}" "$@"
    fi
}

if [ ! -r "${CONFIG_FILE}" ]; then
    fail_config "cpolar configuration is unavailable: ${CONFIG_FILE}"
fi

if ! cpolar_tunnels="$("${CPOLAR_BIN_PATH}" list "-config=${CONFIG_FILE}")"; then
    fail "cpolar could not read ${CONFIG_FILE}."
fi

if ! grep -Fxq 'ssh' <<<"${cpolar_tunnels}"; then
    fail_config "${CONFIG_FILE} does not contain a tunnel named ssh."
fi

has_ssh_tunnel() {
    awk '
        /^tunnels:[[:space:]]*(#.*)?$/ { in_tunnels = 1; next }
        in_tunnels && /^[^[:space:]#]/ { in_tunnels = 0 }
        !in_tunnels { next }
        /^[[:space:]]+ssh:[[:space:]]*(#.*)?$/ {
            in_ssh = 1
            match($0, /^[[:space:]]*/)
            ssh_indent = RLENGTH
            next
        }
        in_ssh {
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
            match($0, /^[[:space:]]*/)
            if (RLENGTH <= ssh_indent) in_ssh = 0
            if (in_ssh && $0 ~ /^[[:space:]]*proto:[[:space:]]*tcp([[:space:]]|#|$)/) proto = 1
            if (in_ssh && $0 ~ /^[[:space:]]*addr:[[:space:]]*("22"|\04722\047|22)([[:space:]]|#|$)/) addr = 1
        }
        END { exit !(proto && addr) }
    ' "${CONFIG_FILE}"
}

if ! has_ssh_tunnel; then
    fail_config "${CONFIG_FILE} must define the named ssh tunnel as TCP port 22."
fi

if ! run_systemctl cat "${SERVICE_NAME}" >/dev/null; then
    fail "${SERVICE_NAME} is not installed."
fi

if ! run_systemctl enable "${SERVICE_NAME}"; then
    fail "could not enable ${SERVICE_NAME}."
fi

if ! run_systemctl restart "${SERVICE_NAME}"; then
    fail "could not restart ${SERVICE_NAME}."
fi

if ! run_systemctl is-enabled --quiet "${SERVICE_NAME}"; then
    fail "${SERVICE_NAME} is not enabled."
fi

if ! run_systemctl is-active --quiet "${SERVICE_NAME}"; then
    fail "${SERVICE_NAME} is not active."
fi

echo "${SERVICE_NAME} is enabled and active."
echo "Status: systemctl status cpolar"
echo "Logs: journalctl -u cpolar; /var/log/cpolar/access.log"
