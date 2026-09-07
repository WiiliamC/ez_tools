#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_root/check_port.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
export call_log="$tmp_dir/calls"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Mock the external-command boundary without depending on installed backends.
command() {
  if [[ "$1" == -v ]]; then
    case "$2" in
      ss) [[ "$have_ss" == 1 ]]; return ;;
      netstat) [[ "$have_netstat" == 1 ]]; return ;;
      lsof) [[ "$have_lsof" == 1 ]]; return ;;
    esac
  fi
  builtin command "$@"
}
ss() {
  printf 'ss %s\n' "$*" >> "$call_log"
  printf '%s' "$ss_output"
  [[ "$ss_status" == 0 ]] || printf 'mock ss query failure\n' >&2
  return "$ss_status"
}
netstat() {
  printf 'netstat %s\n' "$*" >> "$call_log"
  printf '%s' "$netstat_output"
  [[ "$netstat_status" == 0 ]] || printf 'mock netstat query failure\n' >&2
  return "$netstat_status"
}
lsof() {
  printf 'lsof %s\n' "$*" >> "$call_log"
  printf '%s' "$lsof_output"
  return "$lsof_status"
}
export -f command ss netstat lsof

reset_backends() {
  export have_ss=1 have_netstat=1 have_lsof=1
  export ss_status=0 netstat_status=0 lsof_status=1
  export ss_output='' netstat_output='' lsof_output=''
}

run_case() {
  local expected_status="$1" expected_text="$2"
  shift 2
  : > "$call_log"
  local actual_status=0
  bash "$script" "$@" > "$tmp_dir/stdout" 2> "$tmp_dir/stderr" || actual_status=$?
  [[ "$actual_status" == "$expected_status" ]] || fail "expected exit $expected_status, got $actual_status"
  output="$(cat "$tmp_dir/stdout")"
  errors="$(cat "$tmp_dir/stderr")"
  calls="$(cat "$call_log")"
  [[ "$output$errors" == *"$expected_text"* ]] || fail "missing expected text: $expected_text"
  if [[ "$expected_status" != 0 ]]; then
    [[ "$output" != *'No TCP listener'* && "$output" != *'available'* ]] || fail 'failure reported as free'
  fi
}

reset_backends
ss_output='LISTEN 0 4096 0.0.0.0:8086 0.0.0.0:*'
run_case 0 'TCP port 8086 has a listener:' 8086
[[ "$calls" == *'ss -H -ltn sport = :8086'* ]] || fail 'ss filter or flags incorrect'
[[ "$calls" != *netstat* ]] || fail 'successful ss query unnecessarily fell back'
[[ "$errors" == '' ]] || fail 'optional missing process details produced an error'

lsof_status=0
lsof_output='COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
example 123 tester 3u IPv4 12345 0t0 TCP *:8086 (LISTEN)'
run_case 0 'Process details:' 8086

reset_backends
ss_output='LISTEN 0 128 [::]:8086 [::]:*'
run_case 0 'TCP port 8086 has a listener:' 8086

reset_backends
run_case 0 'No TCP listener found on port 8086.' 8086
[[ "$calls" != *netstat* && "$calls" != *lsof* ]] || fail 'successful negative socket query fell back'

ss_status=1
netstat_output='Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address Foreign Address State
tcp 0 0 0.0.0.0:8086 0.0.0.0:* LISTEN'
run_case 0 'TCP port 8086 has a listener:' 8086
[[ "$errors" == *'mock ss query failure'* ]] || fail 'query diagnostic lost'
[[ "$calls" == *'netstat -ltn'* ]] || fail 'netstat fallback not called'

have_ss=0
netstat_output='tcp6 0 0 :::8086 :::* LISTEN'
run_case 0 'TCP port 8086 has a listener:' 8086
netstat_output='tcp6 0 0 [::]:8086 [::]:* LISTEN'
run_case 0 'TCP port 8086 has a listener:' 8086
netstat_output='Proto Recv-Q Send-Q Local Address Foreign Address State
tcp 0 0 0.0.0.0:18086 0.0.0.0:* LISTEN
tcp 0 0 127.0.0.1:8086 127.0.0.1:12345 ESTABLISHED
tcp 0 0 127.0.0.1:12345 127.0.0.1:8086 LISTEN'
run_case 0 'No TCP listener found on port 8086.' 8086

reset_backends
ss_status=1
netstat_status=1
# Partial stdout from a failed query is not authoritative.
ss_output='LISTEN 0 128 0.0.0.0:8086 0.0.0.0:*'
run_case 2 'cannot determine TCP port 8086 listening state' 8086
[[ "$errors" == *'mock netstat query failure'* ]] || fail 'netstat diagnostic lost'

have_ss=0
have_netstat=0
lsof_status=0
lsof_output='example 123 tester 3u IPv4 12345 0t0 TCP *:8086 (LISTEN)'
run_case 0 'TCP port 8086 has a listener:' 8086
[[ "$calls" != *$'\nlsof'* ]] || fail 'lsof details queried twice'
lsof_output=''
run_case 2 'cannot determine' 8086
lsof_status=1
run_case 2 'cannot determine' 8086
have_lsof=0
run_case 2 'cannot determine' 8086

reset_backends
for port in 0 65536 -1 abc 1.5 999999999999999999999999999999999999; do
  run_case 1 'port must be an integer' "$port"
  [[ "$calls" == '' ]] || fail 'invalid input queried a backend'
done
run_case 1 'Usage:'
run_case 1 'Usage:' 8086 extra
for port in 1 65535 0008086; do
  run_case 0 'No TCP listener found' "$port"
done
[[ "$calls" == 'ss -H -ltn sport = :8086' ]] || fail 'decimal port not normalized'

printf 'check_port tests passed\n'
