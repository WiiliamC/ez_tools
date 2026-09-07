#!/usr/bin/env bash
set -euo pipefail
repo_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
task_tmp="$(mktemp -d)"
cleanup_test() {
  touch "${task_tmp}/release"
  if [[ -n "${slow_pid:-}" ]]; then wait "${slow_pid}" || true; fi
  rm -rf -- "${task_tmp}"
}
trap cleanup_test EXIT
task_home="${task_tmp}/home"
mkdir -p "${task_home}" "${task_tmp}/bin" "${task_tmp}/work"
export TASK_TEST_CRONTAB="${task_tmp}/crontab"
export TASK_TEST_CLOCK="${task_tmp}/clock"
export TASK_TEST_REAL_DATE="$(command -v date)"
cat >"${task_tmp}/bin/crontab" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TASK_TEST_READ_FAIL:-0}" == 1 && "${1:-}" == -l ]]; then
  echo 'cannot read crontab' >&2
  exit 2
fi
if [[ "${1:-}" == -l ]]; then
  if [[ -f "${TASK_TEST_CRONTAB}" ]]; then
    cat "${TASK_TEST_CRONTAB}"
  else
    echo 'no crontab for test-user' >&2
    exit 1
  fi
else
  [[ "${TASK_TEST_WRITE_FAIL:-0}" != 1 ]] || exit 2
  # Widen the race window to exercise serialization of read/modify/write.
  sleep 0.02
  cp -- "$1" "${TASK_TEST_CRONTAB}"
fi
STUB
cat >"${task_tmp}/bin/date" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == +%s ]]; then
  cat "${TASK_TEST_CLOCK}"
else
  exec "${TASK_TEST_REAL_DATE}" -u -d "@$(cat "${TASK_TEST_CLOCK}")" "$@"
fi
STUB
chmod +x "${task_tmp}/bin/"*
export PATH="${task_tmp}/bin:${PATH}"
task() { env HOME="${task_home}" "${repo_root}/repeat_task.sh" "$@"; }
daily() { env HOME="${task_home}" "${repo_root}/daily_task.sh" "$@"; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
contains() { [[ "$1" == *"$2"* ]] || fail "Missing expected text: $2"; }
reject() {
  if "$@" >"${task_tmp}/rejected.out" 2>&1; then
    fail "Expected command to fail: $*"
  fi
}
anchor=30000143
at() { printf '%s\n' "$(( (anchor + $1) * 60 + ${2:-0} ))" >"${TASK_TEST_CLOCK}"; }
runs() {
  local count=0
  if [[ -f "${task_tmp}/runs" ]]; then count="$(wc -l <"${task_tmp}/runs")"; fi
  [[ "${count}" -eq "$1" ]] || fail "Expected $1 runs, got ${count}"
}
at 0 45
contains "$(task list)" 'No managed repeat tasks'
contains "$(task --help)" '90m'
printf '# unrelated job\n17 3 * * * /usr/bin/true\n' >"${TASK_TEST_CRONTAB}"
cat >"${task_tmp}/work/job.sh" <<'JOB'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$PWD" "$1" "$2" >> "$3"
JOB
chmod +x "${task_tmp}/work/job.sh"
(
  cd "${task_tmp}/work"
  task add hourly 1h ./job.sh 'space argument' '$(literal); * %' "${task_tmp}/runs"
)
wrapper="${task_home}/.repeat_task/wrappers/hourly.sh"
[[ -x "${wrapper}" ]] || fail 'No persistent wrapper'
contains "$(cat "${TASK_TEST_CRONTAB}")" '* * * * * '
contains "$(task list)" 'hourly'
contains "$(task list)" '1h'
contains "$(task list)" 'ok'
for offset in 0 1 59; do at "${offset}"; "${wrapper}"; done
runs 0
at 60
(cd "${task_tmp}"; env HOME="${task_tmp}/different-home" "${wrapper}")
runs 1
contains "$(cat "${task_tmp}/runs")" "${task_tmp}/work|space argument|\$(literal); * %"
# Fresh processes after simulated downtime retain the original phase.
at 181
"${wrapper}"
runs 1
at 239
"${wrapper}"
runs 1
at 240
"${wrapper}"
runs 2
# Normalized intervals cross both clock-hour and date boundaries.
for spec in 1m 90m 7h 2d 0002h; do
  at 0
  task add "case.${spec}" "${spec}" bash -c 'echo run >> "$1"' bash "${task_tmp}/${spec}.runs"
  case "${spec}" in
    1m) minutes=1 ;; 90m) minutes=90 ;; 7h) minutes=420 ;;
    2d) minutes=2880 ;; 0002h) minutes=120 ;;
  esac
  at "$((minutes-1))"
  "${task_home}/.repeat_task/wrappers/case.${spec}.sh"
  [[ ! -e "${task_tmp}/${spec}.runs" ]] || fail 'Task ran early'
  at "${minutes}"
  "${task_home}/.repeat_task/wrappers/case.${spec}.sh"
  at "$((minutes*2))"
  "${task_home}/.repeat_task/wrappers/case.${spec}.sh"
  [[ "$(wc -l <"${task_tmp}/${spec}.runs")" -eq 2 ]] || fail 'Wrong interval'
done
for spec in 0m 000h -1m 1.5h 30s 60 1w 9223372036854775808m 153722867280912931h 6405119470038039d; do
  reject task add invalid "${spec}" true
done
at 0
task add maximum 9223372036854775807m true
reject task add hourly 2h true
reject task add bad/name 1m true
reject task add .. 1m true
reject task delete unknown
# Same name in the two modes remains independent.
daily add hourly 09:07 true
contains "$(daily list)" '09:07'
[[ "$(daily list)" != *case.* ]] || fail 'Daily list included interval tasks'
[[ "$(task list)" != *09:07* ]] || fail 'Repeat list included daily tasks'
# Failure exits are recorded and do not prevent the next scheduled attempt.
task add failure 1m bash -c 'echo failure >> "$1"; exit 75' bash "${task_tmp}/failures"
for offset in 1 2; do
  at "${offset}"
  status=0
  "${task_home}/.repeat_task/wrappers/failure.sh" || status=$?
  [[ "${status}" -eq 75 ]] || fail 'Lost command exit status'
done
[[ "$(wc -l <"${task_tmp}/failures")" -eq 2 ]] || fail 'Failure stopped repetition'
log="${task_home}/.repeat_task/logs/failure/$(date +%F).log"
contains "$(cat "${log}")" 'exit: 75'
[[ "$(cat "${log}")" != *previous-run-active* ]] || fail 'Command exit 75 misclassified'
# Failed crontab operations preserve existing tasks and clean new wrappers.
cp "${TASK_TEST_CRONTAB}" "${task_tmp}/before"
TASK_TEST_WRITE_FAIL=1 reject task add rollback 1m true
[[ ! -e "${task_home}/.repeat_task/wrappers/rollback.sh" ]] || fail 'Failed add left wrapper'
cmp "${TASK_TEST_CRONTAB}" "${task_tmp}/before"
TASK_TEST_WRITE_FAIL=1 reject task delete hourly
[[ -x "${wrapper}" ]] || fail 'Failed delete removed wrapper'
TASK_TEST_READ_FAIL=1 reject task add unreadable 1m true
cmp "${TASK_TEST_CRONTAB}" "${task_tmp}/before"
mv "${wrapper}" "${wrapper}.missing"
contains "$(task list)" 'missing-wrapper'
mv "${wrapper}.missing" "${wrapper}"
# Concurrent adds in both namespaces must not lose either crontab update.
task add concurrent.a 1m true >"${task_tmp}/a.out" &
a_pid=$!
daily add concurrent.b 10:00 true >"${task_tmp}/b.out" &
b_pid=$!
wait "${a_pid}"
wait "${b_pid}"
contains "$(task list)" concurrent.a
contains "$(daily list)" concurrent.b
task delete concurrent.a >"${task_tmp}/a.out" &
a_pid=$!
daily delete concurrent.b >"${task_tmp}/b.out" &
b_pid=$!
wait "${a_pid}"
wait "${b_pid}"
[[ "$(cat "${TASK_TEST_CRONTAB}")" != *concurrent.* ]] || fail 'Concurrent delete lost update'
# Long jobs skip later ticks; deletion does not interrupt an active command.
at 0
task add slow 1m bash -c 'touch "$1"; while [[ ! -e "$2" ]]; do sleep 0.05; done; echo done >> "$3"' bash "${task_tmp}/started" "${task_tmp}/release" "${task_tmp}/finished"
task add independent 1m true
at 1
"${task_home}/.repeat_task/wrappers/slow.sh" &
slow_pid=$!
for _ in {1..100}; do [[ ! -e "${task_tmp}/started" ]] || break; sleep 0.02; done
if [[ ! -e "${task_tmp}/started" ]]; then
  touch "${task_tmp}/release"
  wait "${slow_pid}" || true
  fail 'Slow task did not start'
fi
at 2
status=0
"${task_home}/.repeat_task/wrappers/slow.sh" || status=$?
[[ "${status}" -eq 75 ]] || fail 'Overlap was not skipped'
"${task_home}/.repeat_task/wrappers/independent.sh"
task delete slow
[[ ! -f "${task_tmp}/finished" ]] || fail 'Slow command did not remain active'
touch "${task_tmp}/release"
wait "${slow_pid}"
slow_pid=""
[[ -f "${task_tmp}/finished" ]] || fail 'Delete interrupted active job'
contains "$(cat "${task_home}/.repeat_task/logs/slow/$(date +%F).log")" 'previous-run-active'
task delete hourly
[[ ! -e "${wrapper}" ]] || fail 'Delete retained wrapper'
[[ -d "${task_home}/.repeat_task/logs/hourly" ]] || fail 'Delete removed logs'
contains "$(daily list)" hourly
contains "$(cat "${TASK_TEST_CRONTAB}")" '17 3 * * * /usr/bin/true'
# Old daily metadata/wrappers remain manageable without migration.
legacy="${task_home}/.daily_task/wrappers/legacy.sh"
printf '#!/bin/sh\nexit 0\n' >"${legacy}"
chmod +x "${legacy}"
cat >>"${TASK_TEST_CRONTAB}" <<LEGACY
# daily_task: begin legacy
# daily_task: time 08:05
# daily_task: command true
# daily_task: wrapper ${legacy}
5 8 * * * ${legacy}
# daily_task: end legacy
LEGACY
contains "$(daily list)" legacy
daily delete legacy
[[ ! -e "${legacy}" ]] || fail 'Legacy task not deleted'
# Paths are quoted for /bin/sh, and percent is escaped for cron's preprocessing.
at 0
task_home="${task_tmp}/home space'quote%percent"
mkdir -p "${task_home}"
task add quoted 1m true
cron_line="$(awk '/^\* / {line=$0} END {print line}' "${TASK_TEST_CRONTAB}")"
contains "${cron_line}" '\%'
cron_command="${cron_line#\* \* \* \* \* }"
cron_command="${cron_command//\\%/%}"
at 1
/bin/sh -c "${cron_command}"
printf 'repeat_task tests passed\n'
