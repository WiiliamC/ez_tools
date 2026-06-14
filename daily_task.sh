#!/usr/bin/env bash

set -euo pipefail

TAG="[daily-task]"
STATE_DIR="${HOME}/.daily_task"
WRAPPER_DIR="${STATE_DIR}/wrappers"
LOG_DIR="${STATE_DIR}/logs"
LOCK_DIR="${STATE_DIR}/locks"
MARKER_PREFIX="# daily_task:"

usage() {
  cat <<'EOF'
Usage:
  ./daily_task.sh add <task_name> <HH:MM> <command> [args...]
  ./daily_task.sh delete <task_name>
  ./daily_task.sh list
  ./daily_task.sh -h|--help

Commands:
  add     Create a daily cron task for the current user at HH:MM
  delete  Remove one managed task from crontab and delete its wrapper
  list    Show all managed daily tasks

Task names:
  Use only letters, digits, underscore, dot, and hyphen.
  Examples: backup, report.job, sync-home_1

Time format:
  Use 24-hour HH:MM, from 00:00 through 23:59. Cron runs tasks precise to the minute.

Command behavior:
  Commands use argument-array semantics. The command and each argument are preserved
  as separate arguments; shell syntax is not interpreted unless you explicitly run a shell.

Examples:
  ./daily_task.sh add backup 02:30 /usr/local/bin/backup --full
  ./daily_task.sh add report 09:00 python3 /opt/tools/report.py --daily
  ./daily_task.sh add shell_job 18:15 bash -lc 'date >> ~/daily.txt && echo done'
  ./daily_task.sh list
  ./daily_task.sh delete backup

Logs:
  Wrapper records and command output share one log file:
    ~/.daily_task/logs/{task}/{YYYY-MM-DD}.log
  Wrapper-owned records are prefixed with [daily_task]. Command stdout and stderr
  are appended unchanged.

Non-overlap:
  Each generated wrapper uses a per-task nonblocking flock under
  ~/.daily_task/locks. If the same task is still running, the later run logs a
  [daily_task] skipped previous-run-active record, logs exit status 75, and
  exits 75. Different task names use different locks and do not block each other.

Notes:
  This utility edits only crontab entries between its own clear markers and leaves
  unrelated crontab entries unchanged.
EOF
}

log() {
  printf '%s %s\n' "${TAG}" "$*"
}

die() {
  printf '%s ERROR: %s\n' "${TAG}" "$*" >&2
  exit 1
}

need_crontab() {
  command -v crontab >/dev/null 2>&1 || die "missing required command: crontab"
}

need_flock() {
  command -v flock >/dev/null 2>&1 || die "missing required command: flock"
}

validate_task_name() {
  local task_name="$1"

  [[ -n "${task_name}" ]] || die "task name is required"
  [[ "${task_name}" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || die "invalid task name '${task_name}'; use only letters, digits, underscore, dot, and hyphen"
  [[ "${task_name}" != "." && "${task_name}" != ".." ]] \
    || die "invalid task name '${task_name}'; task name cannot be '.' or '..'"
}

validate_time() {
  local time="$1"

  [[ "${time}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || die "invalid time '${time}'; expected HH:MM from 00:00 through 23:59"
}

quote_args() {
  local arg

  printf '%q' "$1"
  shift
  for arg in "$@"; do
    printf ' %q' "${arg}"
  done
}

resolve_relative_command_path() {
  local command_path="$1"
  local command_dir="${command_path%/*}"
  local command_name="${command_path##*/}"
  local resolved_dir

  if resolved_dir="$(unset CDPATH; cd -- "${command_dir}" 2>/dev/null && pwd -P)"; then
    printf '%s/%s' "${resolved_dir}" "${command_name}"
    return
  fi

  printf '%s/%s' "$(pwd -P)" "${command_path}"
}

normalize_command_path() {
  local command_path="$1"

  if [[ "${command_path}" == */* && "${command_path}" != /* ]]; then
    resolve_relative_command_path "${command_path}"
    return
  fi

  printf '%s' "${command_path}"
}

read_current_crontab_to() {
  local output_file="$1"
  local err_file

  need_crontab
  err_file="$(mktemp)"
  if crontab -l >"${output_file}" 2>"${err_file}"; then
    rm -f "${err_file}"
    return
  fi

  if grep -Eiq 'no crontab|no crontab for' "${err_file}"; then
    : >"${output_file}"
    rm -f "${err_file}"
    return
  fi

  local err
  err="$(<"${err_file}")"
  rm -f "${err_file}"
  die "failed to read current crontab: ${err:-unknown error}"
}

install_crontab_from() {
  local input_file="$1"

  need_crontab
  crontab "${input_file}" || die "failed to install updated crontab"
}

task_exists_in() {
  local crontab_file="$1"
  local task_name="$2"

  grep -Fxq "${MARKER_PREFIX} begin ${task_name}" "${crontab_file}"
}

remove_task_block() {
  local input_file="$1"
  local output_file="$2"
  local task_name="$3"

  awk -v begin="${MARKER_PREFIX} begin ${task_name}" \
      -v end="${MARKER_PREFIX} end ${task_name}" '
    $0 == begin {
      in_block = 1
      found = 1
      next
    }
    $0 == end {
      if (in_block) {
        in_block = 0
        next
      }
    }
    !in_block {
      print
    }
    END {
      if (!found) {
        exit 3
      }
      if (in_block) {
        exit 4
      }
    }
  ' "${input_file}" >"${output_file}"
}

task_wrapper_in() {
  local crontab_file="$1"
  local task_name="$2"

  awk -v begin="${MARKER_PREFIX} begin ${task_name}" \
      -v end="${MARKER_PREFIX} end ${task_name}" \
      -v wrapper_prefix="${MARKER_PREFIX} wrapper " '
    $0 == begin {
      in_block = 1
      next
    }
    $0 == end {
      if (in_block) {
        exit
      }
    }
    in_block && index($0, wrapper_prefix) == 1 {
      print substr($0, length(wrapper_prefix) + 1)
      exit
    }
  ' "${crontab_file}"
}

write_wrapper() {
  local task_name="$1"
  shift
  local cmd_display
  local wrapper
  local tmp_wrapper

  mkdir -p -- "${WRAPPER_DIR}" "${LOG_DIR}/${task_name}" "${LOCK_DIR}"
  cmd_display="$(quote_args "$@")"
  wrapper="${WRAPPER_DIR}/${task_name}.sh"
  tmp_wrapper="$(mktemp "${WRAPPER_DIR}/.${task_name}.XXXXXX")"

  {
    printf '#!/usr/bin/env bash\n\n'
    printf 'set -euo pipefail\n\n'
    printf 'task_name=%q\n' "${task_name}"
    printf 'log_dir=%q\n' "${LOG_DIR}/${task_name}"
    printf 'lock_dir=%q\n' "${LOCK_DIR}"
    printf 'mkdir -p -- "${log_dir}" "${lock_dir}"\n'
    printf 'log_file="${log_dir}/$(date +%%F).log"\n'
    printf 'lock_file="${lock_dir}/${task_name}.lock"\n'
    printf 'lock_acquired_marker="${log_dir}/.lock-acquired.$$"\n'
    printf 'cmd=(%s)\n\n' "${cmd_display}"
    printf 'rm -f -- "${lock_acquired_marker}"\n'
    printf 'set +e\n'
    printf 'flock -n -E 75 --close "${lock_file}" bash -c '"'"'\n'
    printf '  set -euo pipefail\n'
    printf '  lock_acquired_marker="$1"\n'
    printf '  log_file="$2"\n'
    printf '  shift 2\n'
    printf '  touch -- "${lock_acquired_marker}"\n'
    printf '  {\n'
    printf '    printf '"'"'"'"'"'"'"'"'[daily_task] [%%s] starting: %%s\\n'"'"'"'"'"'"'"'"' "$(date '"'"'"'"'"'"'"'"'+%%F %%T%%z'"'"'"'"'"'"'"'"')" "$*"\n'
    printf '    set +e\n'
    printf '    "$@"\n'
    printf '    status=$?\n'
    printf '    set -e\n'
    printf '    printf '"'"'"'"'"'"'"'"'[daily_task] [%%s] exit: %%s\\n'"'"'"'"'"'"'"'"' "$(date '"'"'"'"'"'"'"'"'+%%F %%T%%z'"'"'"'"'"'"'"'"')" "${status}"\n'
    printf '    exit "${status}"\n'
    printf '  } >>"${log_file}" 2>&1\n'
    printf ''"'"' daily_task-wrapper "${lock_acquired_marker}" "${log_file}" "${cmd[@]}"\n'
    printf 'status=$?\n'
    printf 'set -e\n'
    printf 'if [[ "${status}" -eq 75 && ! -e "${lock_acquired_marker}" ]]; then\n'
    printf '  {\n'
    printf '    printf '"'"'[daily_task] [%%s] skipped: previous-run-active\\n'"'"' "$(date '"'"'+%%F %%T%%z'"'"')"\n'
    printf '    printf '"'"'[daily_task] [%%s] exit: 75\\n'"'"' "$(date '"'"'+%%F %%T%%z'"'"')"\n'
    printf '  } >>"${log_file}" 2>&1\n'
    printf '  rm -f -- "${lock_acquired_marker}"\n'
    printf '  exit 75\n'
    printf 'fi\n\n'
    printf 'rm -f -- "${lock_acquired_marker}"\n'
    printf 'exit "${status}"\n'
  } >"${tmp_wrapper}"

  chmod 700 "${tmp_wrapper}"
  mv -f -- "${tmp_wrapper}" "${wrapper}"
}

add_task() {
  [[ "$#" -ge 3 ]] || die "usage: add <task_name> <HH:MM> <command> [args...]"

  local task_name="$1"
  local time="$2"
  shift 2
  local hour="${time%%:*}"
  local minute="${time##*:}"
  local wrapper
  local cmd_display
  local current
  local updated
  local command_path
  local -a command_args

  validate_task_name "${task_name}"
  validate_time "${time}"
  need_flock

  command_path="$(normalize_command_path "$1")"
  shift
  command_args=("${command_path}" "$@")

  current="$(mktemp)"
  updated="$(mktemp)"

  read_current_crontab_to "${current}"
  if task_exists_in "${current}" "${task_name}"; then
    rm -f "${current}" "${updated}"
    die "task '${task_name}' already exists; delete it before adding a replacement"
  fi

  write_wrapper "${task_name}" "${command_args[@]}"

  wrapper="${WRAPPER_DIR}/${task_name}.sh"
  cmd_display="$(quote_args "${command_args[@]}")"
  cp "${current}" "${updated}"
  {
    [[ ! -s "${updated}" ]] || printf '\n'
    printf '%s begin %s\n' "${MARKER_PREFIX}" "${task_name}"
    printf '%s time %s\n' "${MARKER_PREFIX}" "${time}"
    printf '%s command %s\n' "${MARKER_PREFIX}" "${cmd_display}"
    printf '%s wrapper %s\n' "${MARKER_PREFIX}" "${wrapper}"
    printf '%d %d * * * %q\n' "$((10#${minute}))" "$((10#${hour}))" "${wrapper}"
    printf '%s end %s\n' "${MARKER_PREFIX}" "${task_name}"
  } >>"${updated}"

  install_crontab_from "${updated}"
  rm -f "${current}" "${updated}"
  log "added '${task_name}' at ${time}"
  log "logs: ${LOG_DIR}/${task_name}/YYYY-MM-DD.log"
}

delete_task() {
  [[ "$#" -eq 1 ]] || die "usage: delete <task_name>"

  local task_name="$1"
  local current
  local updated
  local wrapper

  validate_task_name "${task_name}"

  current="$(mktemp)"
  updated="$(mktemp)"

  read_current_crontab_to "${current}"
  if ! task_exists_in "${current}" "${task_name}"; then
    rm -f "${current}" "${updated}"
    die "managed task '${task_name}' was not found"
  fi

  wrapper="$(task_wrapper_in "${current}" "${task_name}")"
  if [[ -z "${wrapper}" ]]; then
    wrapper="${WRAPPER_DIR}/${task_name}.sh"
  fi

  if ! remove_task_block "${current}" "${updated}" "${task_name}"; then
    rm -f "${current}" "${updated}"
    die "failed to remove managed crontab block for '${task_name}'"
  fi

  install_crontab_from "${updated}"
  rm -f "${current}" "${updated}"
  rm -f -- "${wrapper}"
  log "deleted '${task_name}'"
  log "kept logs under ${LOG_DIR}/${task_name}"
}

list_tasks() {
  local current
  local count=0
  local task_name=""
  local task_time=""
  local task_command=""
  local task_wrapper=""
  local status=""
  local line

  current="$(mktemp)"

  read_current_crontab_to "${current}"

  while IFS= read -r line; do
    case "${line}" in
      "${MARKER_PREFIX} begin "*)
        task_name="${line#"${MARKER_PREFIX} begin "}"
        task_time=""
        task_command=""
        task_wrapper=""
        ;;
      "${MARKER_PREFIX} time "*)
        [[ -n "${task_name}" ]] && task_time="${line#"${MARKER_PREFIX} time "}"
        ;;
      "${MARKER_PREFIX} command "*)
        [[ -n "${task_name}" ]] && task_command="${line#"${MARKER_PREFIX} command "}"
        ;;
      "${MARKER_PREFIX} wrapper "*)
        [[ -n "${task_name}" ]] && task_wrapper="${line#"${MARKER_PREFIX} wrapper "}"
        ;;
      "${MARKER_PREFIX} end "*)
        if [[ -n "${task_name}" ]]; then
          status="ok"
          if [[ -z "${task_wrapper}" || ! -x "${task_wrapper}" ]]; then
            status="missing-wrapper"
          fi
          printf '%-24s %-5s %-15s %s\n' "${task_name}" "${task_time}" "${status}" "${task_command}"
          count=$((count + 1))
          task_name=""
        fi
        ;;
      *)
        ;;
    esac
  done <"${current}"

  if (( count == 0 )); then
    printf '%s\n' "No managed daily tasks. Add one with: ./daily_task.sh add <task_name> <HH:MM> <command> [args...]"
  fi
  rm -f "${current}"
}

main() {
  local command="${1:-}"

  case "${command}" in
    -h|--help|help)
      usage
      ;;
    add)
      shift
      add_task "$@"
      ;;
    delete)
      shift
      delete_task "$@"
      ;;
    list)
      shift
      [[ "$#" -eq 0 ]] || die "usage: list"
      list_tasks
      ;;
    "")
      usage >&2
      exit 1
      ;;
    *)
      die "unknown command '${command}'. Use -h for help."
      ;;
  esac
}

main "$@"
