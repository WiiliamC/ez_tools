#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/kill_process.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/bin"
kill_log="${tmp_dir}/kill.log"
export FAKE_PS_MODE="none"
export FAKE_KILL_LOG="${kill_log}"
export KILL_PROCESS_KILL="${tmp_dir}/bin/kill"

cat >"${tmp_dir}/bin/ps" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${FAKE_PS_MODE:-none}" in
  none)
    printf '%s\n' " 111 1 chan 00:30 S /usr/bin/python app.py"
    ;;
  self_only)
    printf '%s\n' " ${PPID} 1 chan 00:01 S /repo/kill_process.sh needle"
    ;;
  matches)
    printf '%s\n' " ${PPID} 1 chan 00:01 S /repo/kill_process.sh needle"
    printf '%s\n' " 12345 1 chan 01:23 S /usr/bin/python -m service --name needle"
    printf '%s\n' " 23456 1 root 2-03:04 R bash -lc sleep needle"
    printf '%s\n' " 34567 1 chan 00:12 S /usr/bin/other"
    ;;
  wrapper)
    script_pid="${PPID}"
    script_ppid="$(awk '{print $4}' "/proc/${script_pid}/stat")"
    printf '%s\n' " ${script_pid} ${script_ppid} chan 00:01 S /repo/kill_process.sh needle"
    printf '%s\n' " ${script_ppid} 1 chan 00:01 S bash -lc ./kill_process.sh needle"
    printf '%s\n' " 45678 1 chan 00:02 S /usr/bin/python -m target needle"
    ;;
  *)
    echo "unknown FAKE_PS_MODE: ${FAKE_PS_MODE}" >&2
    exit 2
    ;;
esac
EOF

cat >"${tmp_dir}/bin/kill" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_KILL_LOG}"
EOF

chmod +x "${tmp_dir}/bin/ps" "${tmp_dir}/bin/kill"
export PATH="${tmp_dir}/bin:${PATH}"

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'Expected output to contain: %s\nActual output:\n%s\n' "${needle}" "${haystack}" >&2
    exit 1
  fi
}

assert_no_kill() {
  if [[ -s "${kill_log}" ]]; then
    printf 'Expected no kill calls, got:\n' >&2
    cat "${kill_log}" >&2
    exit 1
  fi
}

set +e
output="$("${script}" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected usage error for missing keyword" >&2
  exit 1
fi
assert_contains "${output}" "Usage:"

FAKE_PS_MODE="none"
output="$("${script}" needle)"
assert_contains "${output}" "No matching processes found for keyword: needle"
assert_no_kill

FAKE_PS_MODE="self_only"
output="$("${script}" needle)"
assert_contains "${output}" "No matching processes found for keyword: needle"
assert_no_kill

FAKE_PS_MODE="matches"
output="$(printf 'n\n' | "${script}" needle)"
assert_contains "${output}" "PID"
assert_contains "${output}" "PPID"
assert_contains "${output}" "USER"
assert_contains "${output}" "ETIME"
assert_contains "${output}" "STAT"
assert_contains "${output}" "CMD"
assert_contains "${output}" "12345"
assert_contains "${output}" "/usr/bin/python -m service --name needle"
assert_contains "${output}" "23456"
assert_contains "${output}" "root"
assert_contains "${output}" "bash -lc sleep needle"
assert_no_kill

FAKE_PS_MODE="wrapper"
output="$(printf 'yes\n' | "${script}" needle)"
assert_contains "${output}" "Sending TERM to 1 process(es)."
assert_contains "$(cat "${kill_log}")" "-TERM 45678"
if [[ "${output}" == *"bash -lc ./kill_process.sh needle"* ]]; then
  printf 'Expected wrapper process to be excluded, got:\n%s\n' "${output}" >&2
  exit 1
fi

>"${kill_log}"
FAKE_PS_MODE="matches"
output="$(printf 'yes\n' | "${script}" needle)"
assert_contains "${output}" "Sending TERM to 2 process(es)."
assert_contains "$(cat "${kill_log}")" "-TERM 12345 23456"
