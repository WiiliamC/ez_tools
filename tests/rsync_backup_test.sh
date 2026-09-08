#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/rsync_backup.sh"
tmp_dir="$(mktemp -d)"
test_pid=""
cleanup() {
  if [[ -n "${test_pid}" ]]; then
    kill -TERM "${test_pid}" 2>/dev/null || true
    wait "${test_pid}" 2>/dev/null || true
  fi
  chmod -R u+rwX "${tmp_dir}"
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_fails() {
  if "${script}" "$@" >"${tmp_dir}/error" 2>&1; then
    fail "expected failure"
  fi
}

source_dir="${tmp_dir}/source files"
destination_dir="${tmp_dir}/backups/nested/copy"
mkdir -p "${source_dir}/subdir" "${source_dir}/empty"
printf 'original\n' >"${source_dir}/file"
printf 'hidden\n' >"${source_dir}/.hidden"
printf 'nested\n' >"${source_dir}/subdir/file"
ln -s file "${source_dir}/link"

"${script}" --dry-run "${source_dir}" "${destination_dir}" >/dev/null
[[ ! -e "${tmp_dir}/backups" ]] || fail "dry run created directories"
"${script}" "${source_dir}" "${destination_dir}" >/dev/null
diff -r "${source_dir}" "${destination_dir}"
[[ -d "${destination_dir}/empty" ]] || fail "missing empty directory"
[[ -L "${destination_dir}/link" ]] || fail "symlink was dereferenced"
output="$("${script}" "${source_dir}/" "${destination_dir}/")"
[[ -z "${output}" ]] || fail "unchanged backup reported changes"

printf 'updated, longer content\n' >"${source_dir}/file"
printf 'new\n' >"${source_dir}/new"
rm "${source_dir}/.hidden"
"${script}" --dry-run "${source_dir}" "${destination_dir}" >/dev/null
[[ "$(cat "${destination_dir}/file")" == original ]] || fail "dry run updated a file"
[[ ! -e "${destination_dir}/new" ]] || fail "dry run added a file"
"${script}" "${source_dir}" "${destination_dir}" >/dev/null
cmp "${source_dir}/file" "${destination_dir}/file"
cmp "${source_dir}/new" "${destination_dir}/new"
[[ -f "${destination_dir}/.hidden" ]] || fail "deleted destination-only file"

# Retained destination-only directories need not be readable for a backup.
retained_dir="${destination_dir}/retained-only"
mkdir -p "${retained_dir}/subtree"
printf 'retained\n' >"${retained_dir}/subtree/file"
chmod 000 "${retained_dir}"
printf 'updated beside unreadable subtree\n' >"${source_dir}/file"
"${script}" --jobs 8 "${source_dir}" "${destination_dir}" >/dev/null
cmp "${source_dir}/file" "${destination_dir}/file"
[[ "$(stat -c %a "${retained_dir}")" == 0 ]] || fail "changed destination-only directory mode"
chmod 700 "${retained_dir}"
[[ "$(cat "${retained_dir}/subtree/file")" == retained ]] || fail "changed destination-only subtree"

# Permission preparation must not follow destination symlink ancestors.
ancestor_source="${tmp_dir}/ancestor-source"
ancestor_dest="${tmp_dir}/ancestor-destination"
ancestor_outside="${tmp_dir}/ancestor-outside"
mkdir -p "${ancestor_source}/a/b" "${ancestor_source}/ab" "${ancestor_dest}" "${ancestor_outside}/b"
printf 'nested\n' >"${ancestor_source}/a/b/file"
printf 'sibling\n' >"${ancestor_source}/ab/file"
ln -s "${ancestor_outside}" "${ancestor_dest}/a"
chmod 600 "${ancestor_outside}/b"
"${script}" --jobs 8 "${ancestor_source}" "${ancestor_dest}" >/dev/null
[[ "$(stat -c %a "${ancestor_outside}/b")" == 600 ]] || fail "changed mode beneath destination symlink ancestor"
[[ ! -L "${ancestor_dest}/a" ]] || fail "destination symlink was not replaced"
cmp "${ancestor_source}/a/b/file" "${ancestor_dest}/a/b/file"
cmp "${ancestor_source}/ab/file" "${ancestor_dest}/ab/file"

printf 'AAAA\n' >"${source_dir}/checksum"
"${script}" "${source_dir}" "${destination_dir}" >/dev/null
printf 'BBBB\n' >"${source_dir}/checksum"
touch -r "${destination_dir}/checksum" "${source_dir}/checksum"
"${script}" "${source_dir}" "${destination_dir}" >/dev/null
[[ "$(cat "${destination_dir}/checksum")" == AAAA ]] || fail "default did not use size/time"
"${script}" --checksum "${source_dir}" "${destination_dir}" >/dev/null
cmp "${source_dir}/checksum" "${destination_dir}/checksum"

assert_fails
assert_fails --unknown "${source_dir}" "${destination_dir}"
assert_fails "" "${destination_dir}"
assert_fails "${tmp_dir}/missing" "${destination_dir}"
assert_fails "${source_dir}/file" "${destination_dir}"
assert_fails "${source_dir}" "${destination_dir}/file"
assert_fails "${source_dir}" "${source_dir}"
assert_fails "${source_dir}" "${source_dir}/child"
assert_fails "${source_dir}/subdir" "${source_dir}"
assert_fails "${source_dir}" /
assert_fails / "${destination_dir}"
ln -s "${source_dir}" "${tmp_dir}/alias"
assert_fails "${source_dir}" "${tmp_dir}/alias/child"
assert_fails "${tmp_dir}/alias" "${source_dir}"
assert_fails "${source_dir}" user@host.example:/backup
assert_fails "${source_dir}" rsync://host.example/backup

mkdir "${tmp_dir}/-source:local"
printf 'special path\n' >"${tmp_dir}/-source:local/file"
(cd "${tmp_dir}" && "${script}" -- ./-source:local -destination >/dev/null)
cmp "${tmp_dir}/-source:local/file" "${tmp_dir}/-destination/file"
"${script}" --help >/dev/null

# Canonical operands must retain trailing newlines, without touching lookalikes.
newline_source="${tmp_dir}/newline-source"$'\n\n'
newline_dest="${tmp_dir}/newline-destination"$'\n\n'
mkdir "${newline_source}" "${tmp_dir}/newline-source" "${tmp_dir}/newline-destination"
printf 'correct source\n' >"${newline_source}/file"
printf 'wrong source\n' >"${tmp_dir}/newline-source/file"
printf 'untouched destination\n' >"${tmp_dir}/newline-destination/file"
for job_count in 1 8; do
  "${script}" -j "${job_count}" "${newline_source}" "${newline_dest}" >/dev/null
  cmp "${newline_source}/file" "${newline_dest}/file"
  [[ "$(cat "${tmp_dir}/newline-destination/file")" == 'untouched destination' ]] || fail "modified newline lookalike"
done

# Verify full trees in both modes, including names unsafe for newline lists.
complex_source="${tmp_dir}/complex"
mkdir -p "${complex_source}/deep/level/empty" "${complex_source}/readonly"
for i in {1..25}; do
  printf 'file %s\n' "${i}" >"${complex_source}/deep/level/file-${i}"
done
printf 'newline\n' >"${complex_source}/deep/level/"$'line\nbreak'
printf 'dash\n' >"${complex_source}/-dash"
printf 'colon\n' >"${complex_source}/name:part"
printf 'readonly\n' >"${complex_source}/readonly/file"
ln -s missing "${complex_source}/dangling"
ln -s deep "${complex_source}/dir-link"
mkfifo "${complex_source}/fifo"
chmod 550 "${complex_source}/readonly"
touch -t 202001020304 "${complex_source}" "${complex_source}/deep" "${complex_source}/readonly"
for job_count in 1 8; do
  complex_dest="${tmp_dir}/complex-${job_count}"
  "${script}" --jobs "${job_count}" "${complex_source}" "${complex_dest}" >/dev/null
  # A checksum dry run catches missing data and mismatched archive attributes.
  output="$(rsync -anic -- "${complex_source}/" "${complex_dest}/")"
  [[ -z "${output}" ]] || fail "tree mismatch with jobs=${job_count}: ${output}"
  "${script}" --jobs="${job_count}" "${complex_source}" "${complex_dest}" >/dev/null
  # Parallel preparation temporarily makes readonly directories writable.
  output="$(rsync -anic -- "${complex_source}/" "${complex_dest}/")"
  [[ -z "${output}" ]] || fail "repeat changed tree with jobs=${job_count}: ${output}"
done
# Replacing a file must work after the first backup restores a directory to 550.
printf 'updated readonly content\n' >"${complex_source}/readonly/file"
"${script}" --jobs 8 "${complex_source}" "${tmp_dir}/complex-8" >/dev/null
cmp "${complex_source}/readonly/file" "${tmp_dir}/complex-8/readonly/file"
[[ "$(stat -c %a "${tmp_dir}/complex-8/readonly")" == 550 ]] || fail "readonly directory mode was not restored"

mkdir "${tmp_dir}/empty-source"
"${script}" "${tmp_dir}/empty-source" "${tmp_dir}/empty-copy" >/dev/null
[[ -d "${tmp_dir}/empty-copy" ]] || fail "empty source not copied"

assert_fails --jobs
for invalid in 0 -1 1.5 abc '' 08; do
  assert_fails --jobs "${invalid}" "${source_dir}" "${destination_dir}"
done
scratch_source="${tmp_dir}/scratch-source"
mkdir "${scratch_source}"
status=0
TMPDIR="${scratch_source}" "${script}" "${scratch_source}" "${tmp_dir}/scratch-copy" >"${tmp_dir}/error" 2>&1 || status=$?
[[ ${status} -ne 0 && ! -e "${tmp_dir}/scratch-copy" ]] || fail "accepted scratch directory inside backup tree"
[[ -z "$(find "${scratch_source}" -mindepth 1 -print -quit)" ]] || fail "scratch rejection leaked lists"

export REAL_RSYNC="$(command -v rsync)"

# A fake executable checks that a failed rsync is never reported as success.
mkdir "${tmp_dir}/bin"
printf '#!/usr/bin/env bash\nexit 23\n' >"${tmp_dir}/bin/rsync"
chmod +x "${tmp_dir}/bin/rsync"
status=0
PATH="${tmp_dir}/bin:${PATH}" "${script}" "${source_dir}" "${destination_dir}" || status=$?
[[ ${status} -eq 23 ]] || fail "rsync exit status was not preserved"

# A barrier forces every requested worker to be alive at once. If workers are
# serialized or the number differs, the barrier fails instead of hanging.
cat >"${tmp_dir}/bin/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
list=""
for arg in "$@"; do
  case "$arg" in --files-from=*) list="${arg#*=}" ;; esac
done
if [[ -z "${list}" ]]; then
  printf 'serial\n' >>"${FAKE_STATE}/serial"
  if [[ "${FAKE_REAL_PREP:-false}" == true ]]; then
    exec "${REAL_RSYNC}" "$@"
  fi
  exit 0
fi
printf '%s\n' "${list}" >"${FAKE_STATE}/started/$$"
ready=false
for ((attempt=0; attempt<250; attempt++)); do
  started=("${FAKE_STATE}/started/"*)
  if [[ ${#started[@]} -eq ${FAKE_EXPECTED} ]]; then
    ready=true
    break
  fi
  sleep 0.02
done
[[ "${ready}" == true ]] || exit 90
if [[ "${FAKE_MODE}" == symlink-failure ]]; then
  IFS= read -r -d '' path <"${list}"
  [[ "${path}" != fail ]] || exit 23
  exec "${REAL_RSYNC}" "$@"
fi
if [[ "${FAKE_MODE}" == interrupt ]]; then
  child=""
  trap 'kill -TERM "${child}" 2>/dev/null || true; wait "${child}" 2>/dev/null || true; exit 143' TERM
  sleep 60 &
  child=$!
  printf '%s\n' "${child}" >"${FAKE_STATE}/children/$$"
  wait "${child}"
fi
if [[ "${FAKE_MODE}" == failure && "${list}" == */chunk-0 ]]; then
  exit 23
fi
printf 'done\n' >"${FAKE_STATE}/finished/$$"
EOF
export PATH="${tmp_dir}/bin:${PATH}"
export FAKE_MODE=success
export FAKE_STATE FAKE_EXPECTED
parallel_source="${tmp_dir}/parallel-source"
mkdir "${parallel_source}"
for i in {1..24}; do touch "${parallel_source}/file-${i}"; done

check_parallel() {
  local label="$1" expected="$2"
  shift 2
  FAKE_STATE="${tmp_dir}/${label}"
  FAKE_EXPECTED="${expected}"
  mkdir -p "${FAKE_STATE}/started" "${FAKE_STATE}/finished" "${FAKE_STATE}/children" "${FAKE_STATE}/tmp"
  TMPDIR="${FAKE_STATE}/tmp" "${script}" "$@" "${parallel_source}" "${tmp_dir}/fake-destination"
  local started=("${FAKE_STATE}/started/"*) finished=("${FAKE_STATE}/finished/"*)
  [[ ${#started[@]} -eq ${expected} && ${#finished[@]} -eq ${expected} ]] || fail "wrong concurrency: ${label}"
  [[ $(wc -l <"${FAKE_STATE}/serial") -eq 2 ]] || fail "missing directory phases"
  [[ -z "$(find "${FAKE_STATE}/tmp" -mindepth 1 -print -quit)" ]] || fail "temporary lists leaked"
}
check_parallel default 8
check_parallel short-option 2 -j 2
check_parallel long-option 4 --jobs 4
check_parallel equals-option 3 --jobs=3
full_source="${parallel_source}"
parallel_source="${tmp_dir}/few-files"
mkdir "${parallel_source}"
touch "${parallel_source}/one" "${parallel_source}/two"
check_parallel fewer-files 2
check_parallel oversized-limit 2 --jobs=999999999999999999999999
parallel_source="${full_source}"

# --jobs 1 and dry runs must use one unpartitioned invocation.
for mode in single preview; do
  FAKE_STATE="${tmp_dir}/${mode}"
  mkdir "${FAKE_STATE}"
  if [[ "${mode}" == single ]]; then args=(-j 1); else args=(--dry-run); fi
  "${script}" "${args[@]}" "${parallel_source}" "${tmp_dir}/fake-destination"
  [[ $(wc -l <"${FAKE_STATE}/serial") -eq 1 ]] || fail "expected one invocation for ${mode}"
done

# Exercise real preparation with failing/interrupted fake transfer workers.
export FAKE_REAL_PREP=true
readonly_path="${tmp_dir}/fake-destination/readonly"$'\n'
mkdir -p "${readonly_path}" "${parallel_source}/readonly"$'\n'
chmod 550 "${tmp_dir}/fake-destination" "${readonly_path}"
chmod 755 "${parallel_source}" "${parallel_source}/readonly"$'\n'

FAKE_MODE=failure
FAKE_EXPECTED=8
FAKE_STATE="${tmp_dir}/worker-failure"
mkdir -p "${FAKE_STATE}/started" "${FAKE_STATE}/finished" "${FAKE_STATE}/tmp"
status=0
TMPDIR="${FAKE_STATE}/tmp" "${script}" "${parallel_source}" "${tmp_dir}/fake-destination" || status=$?
[[ ${status} -eq 23 ]] || fail "worker exit status was not preserved"
[[ "$(stat -c %a "${tmp_dir}/fake-destination")" == 550 && "$(stat -c %a "${readonly_path}")" == 550 ]] || fail "failure left directories writable"
finished=("${FAKE_STATE}/finished/"*)
[[ ${#finished[@]} -eq 7 ]] || fail "did not wait for remaining workers"
[[ $(wc -l <"${FAKE_STATE}/serial") -eq 1 ]] || fail "finalized directories after worker failure"
[[ -z "$(find "${FAKE_STATE}/tmp" -mindepth 1 -print -quit)" ]] || fail "failed workers leaked lists"

# Failure must restore descendants initially hidden by non-searchable parents.
hidden_source="${tmp_dir}/hidden-source"
hidden_dest="${tmp_dir}/hidden-destination"
mkdir -p "${hidden_source}/parent/child/grandchild" "${hidden_dest}/parent/child/grandchild"
touch "${hidden_source}/file"
chmod 510 "${hidden_dest}/parent/child/grandchild"
chmod 400 "${hidden_dest}/parent/child"
chmod 600 "${hidden_dest}/parent"
chmod 550 "${hidden_dest}"
FAKE_EXPECTED=1
FAKE_STATE="${tmp_dir}/hidden-failure"
mkdir -p "${FAKE_STATE}/started" "${FAKE_STATE}/finished" "${FAKE_STATE}/tmp"
status=0
TMPDIR="${FAKE_STATE}/tmp" "${script}" "${hidden_source}" "${hidden_dest}" || status=$?
[[ ${status} -eq 23 ]] || fail "hidden-directory worker failure status was not preserved"
[[ "$(stat -c %a "${hidden_dest}")" == 550 ]] || fail "failure changed hidden destination mode"
[[ "$(stat -c %a "${hidden_dest}/parent")" == 600 ]] || fail "failure changed hidden parent mode"
chmod u+x "${hidden_dest}/parent"
[[ "$(stat -c %a "${hidden_dest}/parent/child")" == 400 ]] || fail "failure changed hidden child mode"
chmod u+x "${hidden_dest}/parent/child"
[[ "$(stat -c %a "${hidden_dest}/parent/child/grandchild")" == 510 ]] || fail "failure changed hidden grandchild mode"
[[ $(wc -l <"${FAKE_STATE}/serial") -eq 1 ]] || fail "finalized hidden directories after worker failure"
[[ -z "$(find "${FAKE_STATE}/tmp" -mindepth 1 -print -quit)" ]] || fail "hidden-directory failure leaked lists"

# A real worker replaces an empty directory with a symlink while another fails.
symlink_source="${tmp_dir}/symlink-source"
symlink_dest="${tmp_dir}/symlink-destination"
outside_target="${tmp_dir}/outside-target"
mkdir -p "${symlink_source}" "${symlink_dest}/link" "${outside_target}"
chmod 550 "${symlink_dest}/link"
chmod 700 "${outside_target}"
ln -s "${outside_target}" "${symlink_source}/link"
touch "${symlink_source}/fail"
FAKE_MODE=symlink-failure
FAKE_EXPECTED=2
FAKE_STATE="${tmp_dir}/symlink-failure"
mkdir -p "${FAKE_STATE}/started" "${FAKE_STATE}/tmp"
status=0
TMPDIR="${FAKE_STATE}/tmp" "${script}" -j 2 "${symlink_source}" "${symlink_dest}" >"${FAKE_STATE}/output" 2>&1 || status=$?
[[ ${status} -eq 23 ]] || fail "symlink replacement failure status was not preserved"
[[ -L "${symlink_dest}/link" ]] || fail "worker did not replace the empty directory with a symlink"
[[ "$(stat -c %a "${outside_target}")" == 700 ]] || fail "cleanup changed symlink target permissions"

FAKE_MODE=interrupt
FAKE_EXPECTED=2
FAKE_STATE="${tmp_dir}/interruption"
mkdir -p "${FAKE_STATE}/started" "${FAKE_STATE}/finished" "${FAKE_STATE}/children" "${FAKE_STATE}/tmp"
TMPDIR="${FAKE_STATE}/tmp" "${script}" -j 2 "${parallel_source}" "${tmp_dir}/fake-destination" &
test_pid=$!
ready=false
for ((attempt=0; attempt<250; attempt++)); do
  children=("${FAKE_STATE}/children/"*)
  if [[ ${#children[@]} -eq 2 ]]; then ready=true; break; fi
  sleep 0.02
done
[[ "${ready}" == true ]] || fail "interrupt workers did not start"
[[ "$(stat -c %a "${tmp_dir}/fake-destination")" == 755 && "$(stat -c %a "${readonly_path}")" == 755 ]] || fail "preparation did not change directory modes"
kill -TERM "${test_pid}"
status=0
wait "${test_pid}" || status=$?
test_pid=""
[[ ${status} -eq 143 ]] || fail "incorrect termination status"
[[ "$(stat -c %a "${tmp_dir}/fake-destination")" == 550 && "$(stat -c %a "${readonly_path}")" == 550 ]] || fail "interruption left directories writable"
for child_record in "${children[@]}"; do
  worker_pid="${child_record##*/}"
  child_pid="$(cat "${child_record}")"
  if kill -0 "${worker_pid}" 2>/dev/null || kill -0 "${child_pid}" 2>/dev/null; then
    fail "interruption left a running worker or child"
  fi
done
[[ -z "$(find "${FAKE_STATE}/tmp" -mindepth 1 -print -quit)" ]] || fail "interruption leaked lists"

echo "rsync_backup tests passed"
