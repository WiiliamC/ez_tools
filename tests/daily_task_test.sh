#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/daily_task.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

export HOME="${tmp_dir}/home"
export FAKE_CRONTAB_FILE="${tmp_dir}/crontab"
mkdir -p "${HOME}" "${tmp_dir}/bin"

cat >"${tmp_dir}/bin/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  -l)
    if [[ -f "${FAKE_CRONTAB_FILE}" ]]; then
      cat "${FAKE_CRONTAB_FILE}"
    else
      echo "no crontab for test-user" >&2
      exit 1
    fi
    ;;
  *)
    if [[ "$#" -eq 1 && -f "$1" ]]; then
      cp "$1" "${FAKE_CRONTAB_FILE}"
    else
      echo "fake crontab unsupported args: $*" >&2
      exit 2
    fi
    ;;
esac
EOF
chmod +x "${tmp_dir}/bin/crontab"
export PATH="${tmp_dir}/bin:${PATH}"

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'Expected output to contain: %s\nActual output:\n%s\n' "${needle}" "${haystack}" >&2
    exit 1
  fi
}

assert_file_contains() {
  local file="$1"
  local needle="$2"

  if ! grep -Fq -- "${needle}" "${file}"; then
    printf 'Expected %s to contain: %s\nActual contents:\n' "${file}" "${needle}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

assert_file_not_contains() {
  local file="$1"
  local needle="$2"

  if grep -Fq -- "${needle}" "${file}"; then
    printf 'Expected %s not to contain: %s\nActual contents:\n' "${file}" "${needle}" >&2
    cat "${file}" >&2
    exit 1
  fi
}

output="$("${script}" list)"
assert_contains "${output}" "No managed daily tasks"

output="$("${script}" --help)"
assert_contains "${output}" "~/.daily_task/logs/{task}/{YYYY-MM-DD}.log"
assert_contains "${output}" "[daily_task]"
assert_contains "${output}" "Command stdout and stderr"
assert_contains "${output}" "add-time working directory"
assert_contains "${output}" "~/.daily_task/locks"
assert_contains "${output}" "previous-run-active"

"${script}" add report.job 09:07 printf 'hello %s\n' world

assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: begin report.job"
assert_file_contains "${FAKE_CRONTAB_FILE}" "7 9 * * *"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: end report.job"

wrapper="${HOME}/.daily_task/wrappers/report.job.sh"
[[ -x "${wrapper}" ]]
assert_file_contains "${wrapper}" "cmd=("
assert_file_contains "${wrapper}" "printf"
assert_file_contains "${wrapper}" "hello\\ %s\\\\n"

output="$("${script}" list)"
assert_contains "${output}" "report.job"
assert_contains "${output}" "09:07"
assert_contains "${output}" "ok"
assert_contains "${output}" "printf"
assert_contains "${output}" "hello\\ %s\\\\n"

work_dir="${tmp_dir}/work"
cdpath_dir="${tmp_dir}/cdpath"
mkdir -p "${work_dir}/scripts" "${work_dir}/bin" "${work_dir}/nested" "${cdpath_dir}/scripts"
printf '#!/usr/bin/env bash\nprintf "mark:%%s:%%s\\n" "$1" "$2"\n' >"${work_dir}/scripts/mark.sh"
printf '#!/usr/bin/env bash\nprintf "job:%%s\\n" "$1"\n' >"${work_dir}/scripts/job.sh"
printf '#!/usr/bin/env bash\nprintf "cwd:%%s\\n" "$(pwd -P)"\n' >"${work_dir}/scripts/cwd.sh"
printf '#!/usr/bin/env bash\nprintf "parent-job:%%s\\n" "$1"\n' >"${work_dir}/bin/job.sh"
printf '#!/usr/bin/env bash\nprintf "cdpath-job:%%s\\n" "$1"\n' >"${cdpath_dir}/scripts/job.sh"
chmod +x "${work_dir}/scripts/mark.sh" "${work_dir}/scripts/job.sh" "${work_dir}/scripts/cwd.sh" "${work_dir}/bin/job.sh"

(
  cd "${work_dir}"
  "${script}" add relative.dot 10:11 ./scripts/mark.sh './scripts/not-command.sh' '../arg'
  CDPATH="${cdpath_dir}" "${script}" add relative.plain 10:12 scripts/job.sh plain-arg
  "${script}" add absolute.cmd 10:13 "${work_dir}/scripts/job.sh" absolute-arg
  "${script}" add path.cmd 10:14 bash -lc 'printf path-command'
  "${script}" add absolute.cwd 10:20 "${work_dir}/scripts/cwd.sh"
)
(
  cd "${work_dir}/nested"
  "${script}" add relative.parent 10:15 ../bin/job.sh parent-arg
)

assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: workdir ${work_dir}"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: workdir ${work_dir}/nested"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ./scripts/mark.sh ./scripts/not-command.sh ../arg"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command scripts/job.sh plain-arg"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ${work_dir}/scripts/job.sh absolute-arg"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ${work_dir}/scripts/cwd.sh"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command bash -lc printf\\ path-command"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ../bin/job.sh parent-arg"
assert_file_not_contains "${FAKE_CRONTAB_FILE}" "${cdpath_dir}/scripts/job.sh"

relative_wrapper="${HOME}/.daily_task/wrappers/relative.dot.sh"
assert_file_contains "${relative_wrapper}" "work_dir=${work_dir}"
assert_file_contains "${relative_wrapper}" "cmd=(./scripts/mark.sh ./scripts/not-command.sh ../arg)"
assert_file_contains "${relative_wrapper}" 'cd -- "${work_dir}"'
assert_file_contains "${HOME}/.daily_task/wrappers/absolute.cmd.sh" 'cd -- "${work_dir}"'
assert_file_contains "${HOME}/.daily_task/wrappers/absolute.cwd.sh" 'cd -- "${work_dir}"'
assert_file_contains "${HOME}/.daily_task/wrappers/path.cmd.sh" 'cd -- "${work_dir}"'

output="$("${script}" list)"
assert_contains "${output}" "relative.dot"
assert_contains "${output}" "./scripts/mark.sh ./scripts/not-command.sh ../arg"
assert_contains "${output}" "relative.plain"
assert_contains "${output}" "scripts/job.sh plain-arg"
assert_contains "${output}" "absolute.cmd"
assert_contains "${output}" "${work_dir}/scripts/job.sh absolute-arg"
assert_contains "${output}" "absolute.cwd"
assert_contains "${output}" "${work_dir}/scripts/cwd.sh"
assert_contains "${output}" "path.cmd"
assert_contains "${output}" "bash -lc printf\\ path-command"
assert_contains "${output}" "relative.parent"
assert_contains "${output}" "../bin/job.sh parent-arg"

(
  cd "${tmp_dir}"
  HOME="${tmp_dir}/cron-relative-home" "${relative_wrapper}"
)
relative_log_file="${HOME}/.daily_task/logs/relative.dot/$(date +%F).log"
assert_file_contains "${relative_log_file}" "mark:./scripts/not-command.sh:../arg"

absolute_cwd_wrapper="${HOME}/.daily_task/wrappers/absolute.cwd.sh"
(
  cd "${tmp_dir}"
  "${absolute_cwd_wrapper}"
)
absolute_cwd_log_file="${HOME}/.daily_task/logs/absolute.cwd/$(date +%F).log"
assert_file_contains "${absolute_cwd_log_file}" "cwd:${work_dir}"

if ! command -v flock >/dev/null 2>&1; then
  echo "Test requires flock to verify generated wrapper locking behavior" >&2
  exit 1
fi

slow_marker="${tmp_dir}/slow.started"
"${script}" add slow.task 10:16 bash -lc "printf 'slow-out\n'; touch '${slow_marker}'; sleep 2"
"${script}" add other.task 10:17 printf 'other-out\n'
slow_wrapper="${HOME}/.daily_task/wrappers/slow.task.sh"
"${slow_wrapper}" &
slow_pid=$!
for _ in {1..50}; do
  [[ -f "${slow_marker}" ]] && break
  sleep 0.1
done
if [[ ! -f "${slow_marker}" ]]; then
  echo "Slow task did not start" >&2
  wait "${slow_pid}" || true
  exit 1
fi

set +e
"${slow_wrapper}"
slow_conflict_status=$?
set -e
if [[ "${slow_conflict_status}" -ne 75 ]]; then
  echo "Expected overlapping same task to exit 75, got ${slow_conflict_status}" >&2
  wait "${slow_pid}" || true
  exit 1
fi

set +e
"${HOME}/.daily_task/wrappers/other.task.sh"
other_status=$?
set -e
if [[ "${other_status}" -ne 0 ]]; then
  echo "Expected different task to run while slow task was active, got ${other_status}" >&2
  wait "${slow_pid}" || true
  exit 1
fi
other_log_file="${HOME}/.daily_task/logs/other.task/$(date +%F).log"
assert_file_contains "${other_log_file}" "other-out"

wait "${slow_pid}"
slow_log_file="${HOME}/.daily_task/logs/slow.task/$(date +%F).log"
assert_file_contains "${slow_log_file}" "[daily_task]"
assert_file_contains "${slow_log_file}" "starting:"
assert_file_contains "${slow_log_file}" "previous-run-active"
assert_file_contains "${slow_log_file}" "exit: 75"
assert_file_contains "${slow_log_file}" "slow-out"
assert_file_not_contains "${slow_log_file}" "[daily_task] slow-out"

"${script}" add background.child 10:19 bash -lc "sleep 2 & printf 'bg-parent-done\n'"
background_wrapper="${HOME}/.daily_task/wrappers/background.child.sh"
"${background_wrapper}"
set +e
"${background_wrapper}"
background_status=$?
set -e
if [[ "${background_status}" -ne 0 ]]; then
  echo "Expected task to rerun after parent command exited, got ${background_status}" >&2
  exit 1
fi
background_log_file="${HOME}/.daily_task/logs/background.child/$(date +%F).log"
assert_file_contains "${background_log_file}" "bg-parent-done"
assert_file_not_contains "${background_log_file}" "previous-run-active"

mv "${wrapper}" "${wrapper}.missing"
output="$("${script}" list)"
assert_contains "${output}" "report.job"
assert_contains "${output}" "missing-wrapper"
mv "${wrapper}.missing" "${wrapper}"

if "${script}" add report.job 10:00 echo duplicate >/tmp/daily_task_duplicate.out 2>&1; then
  echo "Duplicate task add unexpectedly succeeded" >&2
  exit 1
fi
assert_file_contains "${FAKE_CRONTAB_FILE}" "7 9 * * *"

if "${script}" add bad/name 10:00 echo bad >/tmp/daily_task_bad_name.out 2>&1; then
  echo "Invalid task name unexpectedly succeeded" >&2
  exit 1
fi

for dot_task_name in . ..; do
  if "${script}" add "${dot_task_name}" 10:00 echo bad >/tmp/daily_task_dot_name.out 2>&1; then
    echo "Dot-only task name unexpectedly succeeded: ${dot_task_name}" >&2
    exit 1
  fi
done

if "${script}" add valid 24:00 echo bad >/tmp/daily_task_bad_time.out 2>&1; then
  echo "Invalid task time unexpectedly succeeded" >&2
  exit 1
fi

no_flock_bin="${tmp_dir}/no-flock-bin"
mkdir -p "${no_flock_bin}"
for required in env bash dirname pwd mktemp grep rm awk cp chmod mv mkdir cat; do
  required_path="$(command -v "${required}")"
  ln -s "${required_path}" "${no_flock_bin}/${required}"
done
if PATH="${no_flock_bin}" "${script}" add no.flock 10:18 echo bad >"${tmp_dir}/no-flock.out" 2>&1; then
  echo "Add unexpectedly succeeded without flock" >&2
  exit 1
fi
assert_file_contains "${tmp_dir}/no-flock.out" "missing required command: flock"
if [[ -e "${HOME}/.daily_task/wrappers/no.flock.sh" ]]; then
  echo "Wrapper was installed even though flock is unavailable" >&2
  exit 1
fi

cron_home="${tmp_dir}/cron-home"
mkdir -p "${cron_home}"
HOME="${cron_home}" "${wrapper}"
today="$(date +%F)"
log_file="${HOME}/.daily_task/logs/report.job/${today}.log"
cron_log_file="${cron_home}/.daily_task/logs/report.job/${today}.log"
assert_file_contains "${log_file}" "hello world"
assert_file_contains "${log_file}" "[daily_task]"
assert_file_contains "${log_file}" "starting:"
assert_file_contains "${log_file}" "exit: 0"
assert_file_not_contains "${log_file}" "[daily_task] hello world"
[[ ! -e "${cron_log_file}" ]]

delete_home="${tmp_dir}/delete-home"
mkdir -p "${delete_home}"
HOME="${delete_home}" "${script}" delete report.job
if grep -Fq "report.job" "${FAKE_CRONTAB_FILE}"; then
  echo "Deleted task still present in fake crontab" >&2
  cat "${FAKE_CRONTAB_FILE}" >&2
  exit 1
fi
[[ ! -e "${wrapper}" ]]
[[ -f "${log_file}" ]]
