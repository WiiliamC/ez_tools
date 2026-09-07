#!/usr/bin/env bash

set -euo pipefail
umask 077

MODE=repeat
if [[ "${1:-}" == --daily ]]; then
  MODE=daily
  shift
fi
TAG="[${MODE}-task]"
STATE_DIR="${HOME}/.${MODE}_task"
WRAPPER_DIR="${STATE_DIR}/wrappers"
LOG_DIR="${STATE_DIR}/logs"
LOCK_DIR="${STATE_DIR}/locks"
MARKER_PREFIX="# ${MODE}_task:"
SCHEDULE_ARG='<interval>'
[[ "${MODE}" != daily ]] || SCHEDULE_ARG='<HH:MM>'
TEMP_FILES=()
PENDING_WRAPPER=""

cleanup() {
  local status=$?
  [[ -z "${PENDING_WRAPPER}" ]] || rm -f -- "${PENDING_WRAPPER}"
  if (( ${#TEMP_FILES[@]} )); then
    rm -f -- "${TEMP_FILES[@]}"
  fi
  return "${status}"
}
trap cleanup EXIT

usage() {
  cat <<EOF
Usage:
  ./${MODE}_task.sh add <task_name> ${SCHEDULE_ARG} <command> [args...]
  ./${MODE}_task.sh delete <task_name>
  ./${MODE}_task.sh list
  ./${MODE}_task.sh -h|--help

Tasks use the current user's crontab. Task names may contain letters, digits,
underscore, dot and hyphen, but cannot be '.' or '..'. Duplicate names are rejected.
Delete stops future runs, allows an active command to finish, and keeps logs.

Command behavior:
  Commands use argument-array semantics. Shell syntax requires explicit bash -lc.
  Tasks run from the add-time working directory, including relative commands
  and arguments. The cron environment applies; use absolute executable paths
  when a command is not on cron's PATH.

Logs:
  ~/.${MODE}_task/logs/{task}/{YYYY-MM-DD}.log
  Wrapper records use [${MODE}_task]. Command stdout and stderr are appended unchanged.

Non-overlap:
  Per-task flock locks live under ~/.${MODE}_task/locks.
  An overlapping run logs 'skipped: previous-run-active' and exits 75.
  Different tasks do not block one another. Command failure does not cancel scheduling.

Persistence:
  Cron must be installed, running and enabled at boot. Task files, working directory
  and executables must remain accessible after reboot, without an interactive login.
  The utility does not install or configure the system cron service.
  Only this utility's marked entries are edited; unrelated crontab entries are kept.
EOF
  if [[ "${MODE}" == daily ]]; then
    cat <<'EOF'

Time format:
  HH:MM in 24-hour format, from 00:00 through 23:59, using cron's timezone.
  Example: ./daily_task.sh add report 09:00 /usr/bin/printf 'hello\n'
EOF
  else
    cat <<'EOF'

Interval format:
  Positive integer followed by m (minutes), h (hours), or d (24-hour days).
  Examples: 1m, 90m, 1h, 2d. Maximum normalized interval: 9223372036854775807 minutes.
  The schedule is anchored to the add-time minute; the first run is one interval
  later. Adding 1h at 10:23:45 schedules the first run at 11:23.
  Runs follow a fixed elapsed-time rhythm across hours and days. Overlapping and
  missed runs are skipped, not queued. After reboot, wait for the next scheduled
  minute; there is no catch-up run. Wall-clock changes affect this minute schedule.

Examples:
  ./repeat_task.sh add report 1h /usr/bin/printf 'hello\n'
  ./repeat_task.sh add shell_job 90m bash -lc 'date >> ~/repeat.txt'
  ./repeat_task.sh list
  ./repeat_task.sh delete report

Compatibility:
  --daily selects the daily_task.sh interface and its separate task namespace.
EOF
  fi
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

validate_interval() {
  local interval="$1" value factor limit
  [[ "${interval}" =~ ^([0-9]+)([mhd])$ ]] || die "invalid interval '${interval}'; expected a positive integer followed by m, h, or d"
  value="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    m) factor=1 ;;
    h) factor=60 ;;
    d) factor=1440 ;;
  esac
  # Strip leading zeroes before checking length; never evaluate unbounded input.
  value="${value#"${value%%[!0]*}"}"
  [[ -n "${value}" ]] || die "interval must be greater than zero"
  limit="$((9223372036854775807 / factor))"
  if (( ${#value} > ${#limit} )) ||
     { (( ${#value} == ${#limit} )) && [[ "${value}" > "${limit}" ]]; }; then
    die "interval is too large"
  fi
  INTERVAL_MINUTES=$((10#${value} * factor))
}

lock_management() {
  local lock_dir="/tmp/ez-tools-tasks-${UID}"
  need_flock
  # One lock per user across both modes, even when HOME differs between calls.
  (umask 077; mkdir -- "${lock_dir}") 2>/dev/null || true
  [[ -d "${lock_dir}" && ! -L "${lock_dir}" && -O "${lock_dir}" ]] || die "unsafe management lock directory"
  chmod 700 -- "${lock_dir}"
  [[ ! -L "${lock_dir}/management.lock" ]] || die "unsafe management lock file"
  exec {MANAGEMENT_FD}>"${lock_dir}/management.lock"
  flock "${MANAGEMENT_FD}"
}

# Cron uses /bin/sh, not Bash, and handles percent signs before invoking the shell.
quote_cron_path() {
  local quoted="${1//\'/\'\\\'\'}"
  quoted="'${quoted}'"
  printf '%s' "${quoted//%/\\%}"
}

quote_args() {
  local arg

  printf '%q' "$1"
  shift
  for arg in "$@"; do
    printf ' %q' "${arg}"
  done
}

read_current_crontab_to() {
  local output_file="$1"
  local err_file

  need_crontab
  err_file="$(mktemp)"
  TEMP_FILES+=("${err_file}")
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
  crontab "${input_file}"
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
  local task_name="$1" work_dir="$2" wrapper tmp_wrapper
  shift 2
  mkdir -p -- "${WRAPPER_DIR}" "${LOG_DIR}/${task_name}" "${LOCK_DIR}"
  wrapper="${WRAPPER_DIR}/${task_name}.sh"
  [[ ! -e "${wrapper}" && ! -L "${wrapper}" ]] || die "wrapper already exists for '${task_name}'; inspect the orphan file before adding"
  tmp_wrapper="$(mktemp "${WRAPPER_DIR}/.${task_name}.XXXXXX")"
  TEMP_FILES+=("${tmp_wrapper}")
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf 'task_name=%q\n' "${task_name}"
    printf 'work_dir=%q\n' "${work_dir}"
    printf 'log_dir=%q\n' "${LOG_DIR}/${task_name}"
    printf 'lock_dir=%q\n' "${LOCK_DIR}"
    printf 'wrapper=%q\n' "${wrapper}"
    printf 'log_prefix=%q\n' "[${MODE}_task]"
    printf 'cmd=(%s)\n' "$(quote_args "$@")"
    if [[ "${MODE}" == repeat ]]; then
      printf 'anchor_minute=%q\ninterval_minutes=%q\n' "${ANCHOR_MINUTE}" "${INTERVAL_MINUTES}"
      cat <<'EOF'
now_minute=$(( $(date +%s) / 60 ))
elapsed=$((now_minute - anchor_minute))
if (( elapsed < interval_minutes || elapsed % interval_minutes != 0 )); then
  exit 0
fi
EOF
    fi
    cat <<'EOF'
mkdir -p -- "${log_dir}" "${lock_dir}"
log_file="${log_dir}/$(date +%F).log"
lock_file="${lock_dir}/${task_name}.lock"
lock_acquired_marker="${log_dir}/.lock-acquired.$$"
trap 'rm -f -- "${lock_acquired_marker}"' EXIT
set +e
flock -n -E 75 --close "${lock_file}" bash -c '
  set -euo pipefail
  lock_acquired_marker="$1"
  log_file="$2"
  work_dir="$3"
  log_prefix="$4"
  wrapper="$5"
  shift 5
  touch -- "${lock_acquired_marker}"
  # A cron invocation waiting to start must not run a deleted task.
  [[ -f "${wrapper}" ]] || exit 0
  {
    printf "%s [%s] starting: %s\n" "${log_prefix}" "$(date "+%F %T%z")" "$*"
    set +e
    cd -- "${work_dir}"
    status=$?
    if [[ "${status}" -eq 0 ]]; then
      "$@"
      status=$?
    fi
    printf "%s [%s] exit: %s\n" "${log_prefix}" "$(date "+%F %T%z")" "${status}"
    exit "${status}"
  } >>"${log_file}" 2>&1
' task-wrapper "${lock_acquired_marker}" "${log_file}" "${work_dir}" "${log_prefix}" "${wrapper}" "${cmd[@]}"
status=$?
set -e
if [[ "${status}" -eq 75 && ! -e "${lock_acquired_marker}" ]]; then
  {
    printf '%s [%s] skipped: previous-run-active\n' "${log_prefix}" "$(date '+%F %T%z')"
    printf '%s [%s] exit: 75\n' "${log_prefix}" "$(date '+%F %T%z')"
  } >>"${log_file}" 2>&1
fi
exit "${status}"
EOF
  } >"${tmp_wrapper}"
  chmod 700 "${tmp_wrapper}"
  PENDING_WRAPPER="${wrapper}"
  mv -- "${tmp_wrapper}" "${wrapper}"
}

add_task() {
  [[ "$#" -ge 3 ]] || die "usage: add <task_name> ${SCHEDULE_ARG} <command> [args...]"

  local task_name="$1"
  local time="$2"
  shift 2
  local hour="${time%%:*}"
  local minute="${time##*:}"
  local wrapper
  local cmd_display
  local current
  local updated
  local work_dir
  local -a command_args

  validate_task_name "${task_name}"
  if [[ "${MODE}" == daily ]]; then
    validate_time "${time}"
  else
    validate_interval "${time}"
    ANCHOR_MINUTE=$(( $(date +%s) / 60 ))
  fi
  lock_management

  work_dir="$(pwd -P)"
  command_args=("$@")
  [[ "${HOME}" != *$'\n'* && "${work_dir}" != *$'\n'* ]] || die "HOME and working directory cannot contain newlines"

  current="$(mktemp)"
  TEMP_FILES+=("${current}")
  updated="$(mktemp)"
  TEMP_FILES+=("${updated}")

  read_current_crontab_to "${current}"
  if task_exists_in "${current}" "${task_name}"; then
    rm -f "${current}" "${updated}"
    die "task '${task_name}' already exists; delete it before adding a replacement"
  fi

  write_wrapper "${task_name}" "${work_dir}" "${command_args[@]}"

  wrapper="${WRAPPER_DIR}/${task_name}.sh"
  cmd_display="$(quote_args "${command_args[@]}")"
  cp "${current}" "${updated}"
  {
    [[ ! -s "${updated}" ]] || printf '\n'
    printf '%s begin %s\n' "${MARKER_PREFIX}" "${task_name}"
    printf '%s time %s\n' "${MARKER_PREFIX}" "${time}"
    printf '%s workdir %s\n' "${MARKER_PREFIX}" "${work_dir}"
    printf '%s command %s\n' "${MARKER_PREFIX}" "${cmd_display}"
    printf '%s wrapper %s\n' "${MARKER_PREFIX}" "${wrapper}"
    if [[ "${MODE}" == daily ]]; then
      printf '%d %d * * * %s\n' "$((10#${minute}))" "$((10#${hour}))" "$(quote_cron_path "${wrapper}")"
    else
      printf '%s anchor_minute %s\n' "${MARKER_PREFIX}" "${ANCHOR_MINUTE}"
      printf '%s interval_minutes %s\n' "${MARKER_PREFIX}" "${INTERVAL_MINUTES}"
      printf '* * * * * %s\n' "$(quote_cron_path "${wrapper}")"
    fi
    printf '%s end %s\n' "${MARKER_PREFIX}" "${task_name}"
  } >>"${updated}"

  install_crontab_from "${updated}" || die "failed to install updated crontab"
  PENDING_WRAPPER=""
  rm -f "${current}" "${updated}"
  if [[ "${MODE}" == daily ]]; then
    log "added '${task_name}' at ${time}"
  else
    log "added '${task_name}' every ${time}"
  fi
  log "logs: ${LOG_DIR}/${task_name}/YYYY-MM-DD.log"
}

delete_task() {
  [[ "$#" -eq 1 ]] || die "usage: delete <task_name>"

  local task_name="$1"
  local current
  local updated
  local wrapper

  validate_task_name "${task_name}"
  lock_management

  current="$(mktemp)"
  TEMP_FILES+=("${current}")
  updated="$(mktemp)"
  TEMP_FILES+=("${updated}")

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

  install_crontab_from "${updated}" || die "failed to install updated crontab"
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
  TEMP_FILES+=("${current}")

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
    printf '%s\n' "No managed ${MODE} tasks. Add one with: ./${MODE}_task.sh add <task_name> ${SCHEDULE_ARG} <command> [args...]"
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
