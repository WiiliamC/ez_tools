#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"

cleanup() {
    if [ -f "${TEST_DIR}/app/logs/publish_ssh_by_cpolar.pid" ]; then
        pid="$(cat "${TEST_DIR}/app/logs/publish_ssh_by_cpolar.pid")"
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    fi
    rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

mkdir -p "${TEST_DIR}/app" "${TEST_DIR}/bin"
cp "${REPO_DIR}/publish_ssh_by_cpolar.sh" "${TEST_DIR}/app/"

cat >"${TEST_DIR}/bin/cpolar" <<'EOF'
#!/bin/bash
printf 'fake cpolar arguments: %s\n' "$*"
sleep 30
EOF
chmod +x "${TEST_DIR}/bin/cpolar" "${TEST_DIR}/app/publish_ssh_by_cpolar.sh"

output="$(
    cd "${TEST_DIR}"
    PATH="${TEST_DIR}/bin:${PATH}" "${TEST_DIR}/app/publish_ssh_by_cpolar.sh"
)"

log_file="${TEST_DIR}/app/logs/publish_ssh_by_cpolar.log"
pid_file="${TEST_DIR}/app/logs/publish_ssh_by_cpolar.pid"

grep -q "started in the background" <<<"${output}"
grep -q "fake cpolar arguments: tcp 22" "${log_file}"
test -s "${pid_file}"

second_output="$(
    cd /
    PATH="${TEST_DIR}/bin:${PATH}" "${TEST_DIR}/app/publish_ssh_by_cpolar.sh"
)"
grep -q "already running" <<<"${second_output}"

echo "publish_ssh_by_cpolar tests passed"
