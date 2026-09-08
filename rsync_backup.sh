#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./rsync_backup.sh [--jobs N] [--dry-run] [--checksum] <source_dir> <destination_dir>

Copy the contents of a local source directory into a local destination.
New and changed files are copied; destination-only files are retained.
By default, rsync compares file size and modification time to skip unchanged files.

Options:
  -j, --jobs N    Maximum concurrent rsync transfers (default: 8; positive integer).
                 Use 1 for a single transfer; individual files are not split.
  -n, --dry-run   Preview changes without writing files or creating directories.
  -c, --checksum  Compare file contents using checksums (reads both copies).
  -h, --help      Show this help message.
  --             End options, allowing paths beginning with a dash.

Dry runs use one complete preview regardless of --jobs.
Requires rsync 3.2.3+, GNU realpath/find and util-linux setsid.
EOF
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

declare -a options=()
declare -a positional=()
jobs=8
dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j|--jobs)
      [[ $# -ge 2 ]] || fail "$1 requires a positive integer."
      jobs="$2"; shift 2 ;;
    --jobs=*) jobs="${1#*=}"; shift ;;
    -n|--dry-run) options+=(--dry-run); dry_run=true; shift ;;
    -c|--checksum) options+=(--checksum); shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; positional+=("$@"); break ;;
    -*) fail "unknown option: $1" ;;
    *) positional+=("$1"); shift ;;
  esac
done

[[ "${jobs}" =~ ^[1-9][0-9]*$ ]] || fail "jobs must be a positive integer without leading zeros."

if [[ ${#positional[@]} -ne 2 ]]; then
  usage >&2
  exit 1
fi

for dependency in rsync realpath; do
  if ! command -v "${dependency}" >/dev/null 2>&1; then
    printf 'Error: requires %s.\n' "${dependency}" >&2
    exit 2
  fi
done

# Remote-style operands must not accidentally become local directories.
# A local name containing a colon can be passed as ./name:part or an absolute path.
for path in "${positional[@]}"; do
  [[ -n "${path}" ]] || fail "directory paths must not be empty."
  [[ "${path}" != *:* || "${path%%:*}" == */* ]] ||
    fail "only local directory paths are supported; prefix local colon names with ./ ."
  [[ "${path}" != rsync://* ]] || fail "only local directory paths are supported."
done

[[ -d "${positional[0]}" ]] || fail "source must be an existing directory."
IFS= read -r -d '' source_dir < <(realpath -ez -- "${positional[0]}")
IFS= read -r -d '' destination_dir < <(realpath -mz -- "${positional[1]}")

if [[ "${source_dir}" == "${destination_dir}" ||
      "${source_dir}/" == "${destination_dir%/}/"* ||
      "${destination_dir}/" == "${source_dir%/}/"* ]]; then
  fail "source and destination must be distinct, non-nested directories."
fi

if [[ -e "${destination_dir}" && ! -d "${destination_dir}" ]]; then
  fail "destination must be a directory."
fi

source_dir="${source_dir%/}/"
destination_dir="${destination_dir%/}/"
# Never add --delete or --remove-source-files: this is a retaining backup.
if [[ "${jobs}" == 1 || "${dry_run}" == true ]]; then
  exec rsync -a --itemize-changes --mkpath "${options[@]}" -- \
    "${source_dir}" "${destination_dir}"
fi

for dependency in find setsid mktemp stat; do
  command -v "${dependency}" >/dev/null 2>&1 || {
    printf 'Error: requires %s for parallel backups.\n' "${dependency}" >&2
    exit 2
  }
done

# Each tracked command gets its own process group, including rsync's children.
set +m
declare -A active=()
work_dir=""
restore_permissions=false
cleanup() {
  local exit_status=$? pid mode identity path index
  local -a saved_modes=()
  trap - EXIT
  trap '' INT TERM
  for pid in "${!active[@]}"; do
    kill -TERM -- "-${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true
  done
  for pid in "${!active[@]}"; do
    wait "${pid}" 2>/dev/null || true
  done
  if [[ "${restore_permissions}" == true ]]; then
    mapfile -d '' -t saved_modes <"${work_dir}/directory-modes"
    for ((index=${#saved_modes[@]}-3; index>=0; index-=3)); do
      mode="${saved_modes[index]}"
      identity="${saved_modes[index+1]}"
      path="${saved_modes[index+2]}"
      # Workers may have replaced a saved directory with a source symlink.
      path="${path%/}"
      [[ ! -L "${path}" && -d "${path}" ]] || continue
      [[ "$(stat -c '%d:%i' -- "${path}" 2>/dev/null)" == "${identity}" ]] || continue
      chmod "0${mode}" -- "${path}" || printf 'Error: could not restore directory permissions.\n' >&2
    done
  fi
  if [[ -n "${work_dir}" ]]; then
    rm -rf -- "${work_dir}" || true
  fi
  exit "${exit_status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work_dir="$(mktemp -d)"
work_dir="$(realpath -e -- "${work_dir}")"
if [[ "${work_dir}/" == "${source_dir}"* ||
      "${work_dir}/" == "${destination_dir}"* ]]; then
  fail "TMPDIR must be outside source and destination for parallel backups."
fi

start_task() {
  setsid "$@" &
  task_pid=$!
  active[${task_pid}]=1
}
wait_task() {
  local pid="$1" status=0
  wait "${pid}" || status=$?
  unset 'active[$pid]'
  return "${status}"
}
run_task() {
  start_task "$@"
  wait_task "${task_pid}"
}

# Enumerate before writing to B, and fail if any source subtree cannot be read.
run_task find "${source_dir}" -mindepth 1 ! -type d -printf '%P\0' >"${work_dir}/all"
declare -a lists=()
index=0
while IFS= read -r -d '' path; do
  list="${work_dir}/chunk-${index}"
  if [[ ! -e "${list}" ]]; then
    lists+=("${list}")
  fi
  printf '%s\0' "${path}" >>"${list}"
  index=$((index + 1))
  # Compare strings so even an oversized requested limit cannot overflow arithmetic.
  [[ "${index}" != "${jobs}" ]] || index=0
done <"${work_dir}/all"

# Save modes only for source directories that preparation will affect.
# Save parents before granting search access to snapshot hidden descendants.
# Cleanup restores this order in reverse, leaving restrictive parents until last.
: >"${work_dir}/directory-modes"
restore_permissions=true
if [[ -d "${destination_dir}" ]]; then
  run_task find "${source_dir}" -type d -printf '%P\0' >"${work_dir}/directories"
  while IFS= read -r -d '' relative_path; do
    # Check ancestors from the root so no lookup follows a destination symlink.
    ancestor="${destination_dir%/}"
    remaining="${relative_path}"
    while [[ "${remaining}" == */* ]]; do
      ancestor+="/${remaining%%/*}"
      [[ ! -L "${ancestor}" ]] || continue 2
      remaining="${remaining#*/}"
    done
    path="${destination_dir}${relative_path}"
    path="${path%/}"
    [[ ! -L "${path}" && -d "${path}" ]] || continue
    stat --printf='%a\0%d:%i\0%n\0' -- "${path}" >>"${work_dir}/directory-modes"
    [[ -x "${path}" ]] || chmod u+x -- "${path}"
  done <"${work_dir}/directories"
fi

# Create directories with usable permissions first; apply source attributes last.
run_task rsync -r --perms --chmod=Du+rwx --mkpath --include='*/' --exclude='*' -- \
  "${source_dir}" "${destination_dir}"

declare -a workers=()
for list in "${lists[@]}"; do
  start_task rsync -a --no-recursive --no-implied-dirs --itemize-changes \
    --from0 "--files-from=${list}" "${options[@]}" -- \
    "${source_dir}" "${destination_dir}"
  workers+=("${task_pid}")
done

status=0
for pid in "${workers[@]}"; do
  worker_status=0
  wait_task "${pid}" || worker_status=$?
  if [[ ${status} -eq 0 && ${worker_status} -ne 0 ]]; then
    status=${worker_status}
  fi
done
[[ ${status} -eq 0 ]] || exit "${status}"

run_task rsync -a --itemize-changes --include='*/' --exclude='*' -- \
  "${source_dir}" "${destination_dir}"
restore_permissions=false
