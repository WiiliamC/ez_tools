#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./rsync_backup.sh [--jobs N] [--dry-run] [--checksum] <source_dir> <destination_dir>

Copy the contents of a local source directory into a local destination.
New and changed files are copied; destination-only files are retained.
By default, rclone compares file size and modification time to skip unchanged files.

Options:
  -j, --jobs N    Maximum concurrent file transfers (default: 8; positive integer).
                 Passed to rclone --transfers; one rclone process handles all files.
  -n, --dry-run   Preview changes without writing files or creating directories.
  -c, --checksum  Compare file contents using checksums (reads both copies).
  -h, --help      Show this help message.
  --             End options, allowing paths beginning with a dash.

Shows live progress in a terminal, or statistics every 10 seconds on stderr.
Preserves links, empty directories and metadata supported by rclone.
Requires rclone with --metadata support and GNU realpath/find.
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

for dependency in rclone realpath find; do
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
# --links does not prevent rclone from writing through destination directory
# symlinks. Reject conflicts before copying; find does not follow source links.
# Keep this in a pipeline so pipefail also rejects an incomplete directory scan.
find -P "${source_dir}" -mindepth 1 -type d -printf '%P\0' |
  while IFS= read -r -d '' relative_dir; do
    [[ ! -L "${destination_dir}${relative_dir}" ]] ||
      fail "destination symlink conflicts with source directory: ${relative_dir}"
  done

# Some rclone versions do not create the root for a completely empty source.
if [[ "${dry_run}" == false ]]; then
  mkdir -p -- "${destination_dir}"
fi

# copy retains destination-only files; sync would delete them.
if [[ "${dry_run}" == true ]]; then
  options+=(--stats 0)
elif [[ -t 2 ]]; then
  options+=(--progress --stats 1s)
else
  options+=(--stats 10s --stats-one-line --stats-log-level NOTICE)
fi

exec rclone copy --transfers "${jobs}" --links --metadata \
  --create-empty-src-dirs "${options[@]}" -- \
  "${source_dir}" "${destination_dir}"
