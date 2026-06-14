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
printf '#!/usr/bin/env bash\nprintf "parent-job:%%s\\n" "$1"\n' >"${work_dir}/bin/job.sh"
printf '#!/usr/bin/env bash\nprintf "cdpath-job:%%s\\n" "$1"\n' >"${cdpath_dir}/scripts/job.sh"
chmod +x "${work_dir}/scripts/mark.sh" "${work_dir}/scripts/job.sh" "${work_dir}/bin/job.sh"

(
  cd "${work_dir}"
  "${script}" add relative.dot 10:11 ./scripts/mark.sh './scripts/not-command.sh' '../arg'
  CDPATH="${cdpath_dir}" "${script}" add relative.plain 10:12 scripts/job.sh plain-arg
  "${script}" add absolute.cmd 10:13 "${work_dir}/scripts/job.sh" absolute-arg
  "${script}" add path.cmd 10:14 bash -lc 'printf path-command'
)
(
  cd "${work_dir}/nested"
  "${script}" add relative.parent 10:15 ../bin/job.sh parent-arg
)

assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ${work_dir}/scripts/mark.sh ./scripts/not-command.sh ../arg"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ${work_dir}/scripts/job.sh plain-arg"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ${work_dir}/scripts/job.sh absolute-arg"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command bash -lc printf\\ path-command"
assert_file_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ${work_dir}/bin/job.sh parent-arg"
assert_file_not_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ./scripts/mark.sh"
assert_file_not_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command scripts/job.sh plain-arg"
assert_file_not_contains "${FAKE_CRONTAB_FILE}" "# daily_task: command ../bin/job.sh"
assert_file_not_contains "${FAKE_CRONTAB_FILE}" "${cdpath_dir}/scripts/job.sh"

relative_wrapper="${HOME}/.daily_task/wrappers/relative.dot.sh"
assert_file_contains "${relative_wrapper}" "cmd=(${work_dir}/scripts/mark.sh ./scripts/not-command.sh ../arg)"

output="$("${script}" list)"
assert_contains "${output}" "relative.dot"
assert_contains "${output}" "${work_dir}/scripts/mark.sh ./scripts/not-command.sh ../arg"
assert_contains "${output}" "relative.plain"
assert_contains "${output}" "${work_dir}/scripts/job.sh plain-arg"
assert_contains "${output}" "absolute.cmd"
assert_contains "${output}" "${work_dir}/scripts/job.sh absolute-arg"
assert_contains "${output}" "path.cmd"
assert_contains "${output}" "bash -lc printf\\ path-command"
assert_contains "${output}" "relative.parent"
assert_contains "${output}" "${work_dir}/bin/job.sh parent-arg"

(
  cd "${tmp_dir}"
  HOME="${tmp_dir}/cron-relative-home" "${relative_wrapper}"
)
relative_log_file="${HOME}/.daily_task/logs/relative.dot/$(date +%F).log"
assert_file_contains "${relative_log_file}" "mark:./scripts/not-command.sh:../arg"

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

cron_home="${tmp_dir}/cron-home"
mkdir -p "${cron_home}"
HOME="${cron_home}" "${wrapper}"
today="$(date +%F)"
log_file="${HOME}/.daily_task/logs/report.job/${today}.log"
cron_log_file="${cron_home}/.daily_task/logs/report.job/${today}.log"
assert_file_contains "${log_file}" "hello world"
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
