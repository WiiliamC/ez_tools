#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"

cleanup() {
    rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

mkdir -p "${TEST_DIR}/app" "${TEST_DIR}/bin"
cp "${REPO_DIR}/publish_ssh_by_cpolar.sh" "${TEST_DIR}/app/"
printf '%s\n' \
    'tunnels:' \
    '  ssh:' \
    '    proto: tcp' \
    '    addr: "22"' >"${TEST_DIR}/cpolar.yml"

cat >"${TEST_DIR}/bin/cpolar" <<'EOF'
#!/bin/bash
set -euo pipefail
test "$1" = list
test "$2" = "-config=$CPOLAR_CONFIG_FILE"
printf '%s\n' "${CPOLAR_LIST_OUTPUT:-ssh}"
EOF

cat >"${TEST_DIR}/bin/systemctl" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$SYSTEMCTL_CALLS"
case "$1" in
    cat)
        test "$2" = cpolar.service
        ;;
    enable)
        test "$2" = cpolar.service
        test "${SYSTEMCTL_FAILURE:-}" != enable || exit 1
        ;;
    restart)
        test "$2" = cpolar.service
        test "${SYSTEMCTL_FAILURE:-}" != restart || exit 1
        ;;
    is-enabled)
        test "$2" = --quiet
        test "$3" = cpolar.service
        printf 'enabled\n'
        ;;
    is-active)
        test "$2" = --quiet
        test "$3" = cpolar.service
        test "${SYSTEMCTL_FAILURE:-}" != inactive || exit 3
        printf 'active\n'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "${TEST_DIR}/bin/cpolar" "${TEST_DIR}/bin/systemctl" "${TEST_DIR}/app/publish_ssh_by_cpolar.sh"

output="$(
    PATH="${TEST_DIR}/bin:${PATH}" \
    CPOLAR_TEST_MODE=1 \
    CPOLAR_CONFIG_FILE="${TEST_DIR}/cpolar.yml" \
    SYSTEMCTL_CALLS="${TEST_DIR}/systemctl.calls" \
    "${TEST_DIR}/app/publish_ssh_by_cpolar.sh"
)"

grep -q 'cpolar.service is enabled and active' <<<"${output}"
grep -qx 'cat cpolar.service' "${TEST_DIR}/systemctl.calls"
grep -qx 'enable cpolar.service' "${TEST_DIR}/systemctl.calls"
grep -qx 'restart cpolar.service' "${TEST_DIR}/systemctl.calls"
grep -qx 'is-enabled --quiet cpolar.service' "${TEST_DIR}/systemctl.calls"
grep -qx 'is-active --quiet cpolar.service' "${TEST_DIR}/systemctl.calls"
test ! -e "${TEST_DIR}/app/logs/publish_ssh_by_cpolar.pid"

second_output="$(
    PATH="${TEST_DIR}/bin:${PATH}" \
    CPOLAR_TEST_MODE=1 \
    CPOLAR_CONFIG_FILE="${TEST_DIR}/cpolar.yml" \
    SYSTEMCTL_CALLS="${TEST_DIR}/systemctl.calls" \
    "${TEST_DIR}/app/publish_ssh_by_cpolar.sh"
)"
grep -q 'cpolar.service is enabled and active' <<<"${second_output}"
test "$(grep -c '^enable cpolar.service$' "${TEST_DIR}/systemctl.calls")" -eq 2
test "$(grep -c '^restart cpolar.service$' "${TEST_DIR}/systemctl.calls")" -eq 2

if enable_failure="$(PATH="${TEST_DIR}/bin:${PATH}" CPOLAR_TEST_MODE=1 CPOLAR_CONFIG_FILE="${TEST_DIR}/cpolar.yml" SYSTEMCTL_CALLS="${TEST_DIR}/systemctl.calls" SYSTEMCTL_FAILURE=enable "${TEST_DIR}/app/publish_ssh_by_cpolar.sh" 2>&1)"; then
    echo 'expected a systemctl enable failure to fail' >&2
    exit 1
fi
grep -q 'could not enable cpolar.service' <<<"${enable_failure}"
grep -q 'journalctl -u cpolar' <<<"${enable_failure}"

if restart_failure="$(PATH="${TEST_DIR}/bin:${PATH}" CPOLAR_TEST_MODE=1 CPOLAR_CONFIG_FILE="${TEST_DIR}/cpolar.yml" SYSTEMCTL_CALLS="${TEST_DIR}/systemctl.calls" SYSTEMCTL_FAILURE=restart "${TEST_DIR}/app/publish_ssh_by_cpolar.sh" 2>&1)"; then
    echo 'expected a systemctl restart failure to fail' >&2
    exit 1
fi
grep -q 'could not restart cpolar.service' <<<"${restart_failure}"

if inactive_failure="$(PATH="${TEST_DIR}/bin:${PATH}" CPOLAR_TEST_MODE=1 CPOLAR_CONFIG_FILE="${TEST_DIR}/cpolar.yml" SYSTEMCTL_CALLS="${TEST_DIR}/systemctl.calls" SYSTEMCTL_FAILURE=inactive "${TEST_DIR}/app/publish_ssh_by_cpolar.sh" 2>&1)"; then
    echo 'expected an inactive service to fail' >&2
    exit 1
fi
grep -q 'cpolar.service is not active' <<<"${inactive_failure}"
grep -q '/var/log/cpolar/access.log' <<<"${inactive_failure}"

if missing_name="$(PATH="${TEST_DIR}/bin:${PATH}" CPOLAR_TEST_MODE=1 CPOLAR_CONFIG_FILE="${TEST_DIR}/cpolar.yml" CPOLAR_LIST_OUTPUT=ssh-tunnel SYSTEMCTL_CALLS="${TEST_DIR}/systemctl.calls" "${TEST_DIR}/app/publish_ssh_by_cpolar.sh" 2>&1)"; then
    echo 'expected a list without an exact ssh tunnel name to fail' >&2
    exit 1
fi
grep -q 'does not contain a tunnel named ssh' <<<"${missing_name}"
grep -q '^tunnels:$' <<<"${missing_name}"
grep -q 'addr: "22"' <<<"${missing_name}"

printf '%s\n' \
    'tunnels:' \
    '  ssh:' \
    '    proto: http' \
    '    addr: "22"' >"${TEST_DIR}/cpolar.yml"

if bad_output="$(PATH="${TEST_DIR}/bin:${PATH}" CPOLAR_TEST_MODE=1 CPOLAR_CONFIG_FILE="${TEST_DIR}/cpolar.yml" SYSTEMCTL_CALLS="${TEST_DIR}/systemctl.calls" "${TEST_DIR}/app/publish_ssh_by_cpolar.sh" 2>&1)"; then
    echo 'expected a configuration without an ssh tunnel to fail' >&2
    exit 1
fi
grep -q 'ssh:' <<<"${bad_output}"
grep -q 'addr: "22"' <<<"${bad_output}"

echo "publish_ssh_by_cpolar tests passed"
