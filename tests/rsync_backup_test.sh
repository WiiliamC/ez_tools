#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/rsync_backup.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "${tmp_dir}"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_fails() {
  if "${script}" "$@" >"${tmp_dir}/output" 2>&1; then
    fail "expected failure"
  fi
}
# Use no personal rclone configuration during integration tests.
export RCLONE_CONFIG="${tmp_dir}/rclone.conf"
: >"${RCLONE_CONFIG}"
source_dir="${tmp_dir}/source files"
destination_dir="${tmp_dir}/backups/nested/copy"
mkdir -p "${source_dir}/subdir" "${source_dir}/empty"
printf 'original\n' >"${source_dir}/file"
printf 'hidden\n' >"${source_dir}/.hidden"
printf 'nested\n' >"${source_dir}/subdir/file"
chmod 751 "${source_dir}/file"
touch -t 202001020304.05 "${source_dir}/file"
ln -s file "${source_dir}/link"
ln -s missing "${source_dir}/broken"
ln -s subdir "${source_dir}/directory-link"

"${script}" --dry-run "${source_dir}" "${destination_dir}" >"${tmp_dir}/preview" 2>&1
[[ ! -e "${tmp_dir}/backups" ]] || fail "dry run created directories"
[[ -s "${tmp_dir}/preview" ]] || fail "missing dry run preview"
"${script}" "${source_dir}" "${destination_dir}" >"${tmp_dir}/stdout" 2>"${tmp_dir}/stats"
[[ ! -s "${tmp_dir}/stdout" ]] || fail "statistics leaked onto stdout"
[[ -s "${tmp_dir}/stats" ]] || fail "missing completion statistics"
for file in file .hidden subdir/file; do
  cmp "${source_dir}/${file}" "${destination_dir}/${file}"
done
[[ -d "${destination_dir}/empty" ]] || fail "missing empty directory"
for link in link broken directory-link; do
  [[ -L "${destination_dir}/${link}" ]] || fail "missing symlink"
  [[ "$(readlink "${source_dir}/${link}")" == "$(readlink "${destination_dir}/${link}")" ]] || fail "changed link target"
done
[[ "$(stat -c %a "${destination_dir}/file")" == 751 ]] || fail "file mode not preserved"
[[ "$(stat -c %Y "${destination_dir}/file")" == "$(stat -c %Y "${source_dir}/file")" ]] || fail "mtime not preserved"
before="$(stat -c '%i:%Z:%Y' "${destination_dir}/file")"
"${script}" -j 1 "${source_dir}/" "${destination_dir}/" >/dev/null 2>&1
[[ "$(stat -c '%i:%Z:%Y' "${destination_dir}/file")" == "${before}" ]] || fail "unchanged file rewritten"

printf 'updated, longer content\n' >"${source_dir}/file"
printf 'new\n' >"${source_dir}/new"
rm "${source_dir}/.hidden"
"${script}" -n "${source_dir}" "${destination_dir}" >/dev/null 2>&1
[[ "$(cat "${destination_dir}/file")" == original ]] || fail "dry run changed file"
[[ ! -e "${destination_dir}/new" ]] || fail "dry run added file"
"${script}" --jobs=4 "${source_dir}" "${destination_dir}" >/dev/null 2>&1
cmp "${source_dir}/file" "${destination_dir}/file"
cmp "${source_dir}/new" "${destination_dir}/new"
[[ -f "${destination_dir}/.hidden" ]] || fail "deleted destination-only file"

# Reject destination symlink ancestors before any files or metadata are changed.
ancestor_source="${tmp_dir}/ancestor-source"
ancestor_dest="${tmp_dir}/ancestor-destination"
ancestor_outside="${tmp_dir}/ancestor-outside"
mkdir -p "${ancestor_source}/a/b" "${ancestor_source}/ab" "${ancestor_dest}" "${ancestor_outside}/b"
printf 'nested\n' >"${ancestor_source}/a/b/file"
printf 'sibling\n' >"${ancestor_source}/ab/file"
printf 'outside\n' >"${ancestor_outside}/b/file"
chmod 755 "${ancestor_outside}/b"
ln -s "${ancestor_outside}" "${ancestor_dest}/a"
for mode in --dry-run --jobs=1 --jobs=8; do
  assert_fails "${mode}" "${ancestor_source}" "${ancestor_dest}"
  [[ "$(cat "${ancestor_outside}/b/file")" == outside ]] || fail "wrote through destination symlink ancestor"
  [[ "$(stat -c %a "${ancestor_outside}/b")" == 755 ]] || fail "changed mode beneath destination symlink ancestor"
  [[ -L "${ancestor_dest}/a" ]] || fail "changed conflicting destination symlink"
  [[ ! -e "${ancestor_dest}/ab" ]] || fail "copied files before rejecting destination symlink"
done
# Also detect deeper and dangling conflicts, including names with newlines.
rm "${ancestor_dest}/a"
mkdir "${ancestor_dest}/a"
ln -s "${ancestor_outside}/b" "${ancestor_dest}/a/b"
assert_fails "${ancestor_source}" "${ancestor_dest}"
[[ "$(cat "${ancestor_outside}/b/file")" == outside ]] || fail "wrote through deeper destination symlink"
rm "${ancestor_dest}/a/b"
mkdir "${ancestor_source}/"$'line\nbreak'
ln -s "${tmp_dir}/missing-target" "${ancestor_dest}/"$'line\nbreak'
assert_fails "${ancestor_source}" "${ancestor_dest}"
[[ ! -e "${tmp_dir}/missing-target" ]] || fail "created dangling destination link target"

printf AAAA >"${source_dir}/checksum"
"${script}" "${source_dir}" "${destination_dir}" >/dev/null 2>&1
printf BBBB >"${source_dir}/checksum"
touch -r "${destination_dir}/checksum" "${source_dir}/checksum"
"${script}" "${source_dir}" "${destination_dir}" >/dev/null 2>&1
[[ "$(cat "${destination_dir}/checksum")" == AAAA ]] || fail "default comparison changed"
"${script}" -c "${source_dir}" "${destination_dir}" >/dev/null 2>&1
cmp "${source_dir}/checksum" "${destination_dir}/checksum"

mkdir "${tmp_dir}/empty-source"
"${script}" "${tmp_dir}/empty-source" "${tmp_dir}/empty-copy" >/dev/null 2>&1
[[ -d "${tmp_dir}/empty-copy" ]] || fail "empty source root not copied"
mkdir "${tmp_dir}/-source:part"
printf value >"${tmp_dir}/-source:part/file"
(cd "${tmp_dir}" && "${script}" -- ./-source:part -destination >/dev/null 2>&1)
cmp "${tmp_dir}/-source:part/file" "${tmp_dir}/-destination/file"

assert_fails
assert_fails --unknown "${source_dir}" "${destination_dir}"
assert_fails '' "${destination_dir}"
assert_fails "${tmp_dir}/missing" "${destination_dir}"
assert_fails "${source_dir}/file" "${destination_dir}"
assert_fails "${source_dir}" "${destination_dir}/file"
assert_fails "${source_dir}" "${source_dir}"
assert_fails "${source_dir}" "${source_dir}/child"
assert_fails "${source_dir}/subdir" "${source_dir}"
assert_fails "${source_dir}" /
assert_fails / "${destination_dir}"
assert_fails "${source_dir}" remote:backup
assert_fails "${source_dir}" rsync://host.example/backup
ln -s "${source_dir}" "${tmp_dir}/alias"
assert_fails "${source_dir}" "${tmp_dir}/alias/child"
for jobs in 0 -1 01 abc 1.5; do
  assert_fails --jobs "${jobs}" "${source_dir}" "${destination_dir}"
done
assert_fails --jobs
"${script}" --help >/dev/null

# Check process ownership and output modes without depending on transfer speed.
mkdir "${tmp_dir}/bin"
cat >"${tmp_dir}/bin/rclone" <<'FAKE'
#!/usr/bin/env python3
import json
import os
import signal
import sys
json.dump({'args': sys.argv[1:], 'pid': os.getpid()}, open(os.environ['CAPTURE'], 'w'))
if os.environ.get('WAIT_SIGNAL'):
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    open(os.environ['READY'], 'w').close()
    signal.pause()
sys.exit(int(os.environ.get('FAKE_STATUS', '0')))
FAKE
chmod +x "${tmp_dir}/bin/rclone"
export PATH="${tmp_dir}/bin:${PATH}"
python3 - "${script}" "${source_dir}" "${destination_dir}" "${tmp_dir}" <<'PY'
import json
import os
import pty
import signal
import subprocess
import sys
import time
from pathlib import Path

script, source, dest, scratch = sys.argv[1:]
env = dict(os.environ, CAPTURE=f'{scratch}/args.json', READY=f'{scratch}/ready')
def run(options=(), terminal=False, status=0):
    master, slave = pty.openpty() if terminal else (None, None)
    try:
        result = subprocess.run([script, *options, source, dest], env=dict(env, FAKE_STATUS=str(status)),
                                stdout=subprocess.PIPE, stderr=slave if terminal else subprocess.PIPE)
        assert result.returncode == status, result
        return json.loads(Path(env['CAPTURE']).read_text())['args']
    finally:
        if terminal:
            os.close(slave)
            os.close(master)

args = run()
assert args[0] == 'copy'
assert args[args.index('--transfers') + 1] == '8'
assert all(flag in args for flag in ('--links', '--metadata', '--create-empty-src-dirs'))
assert args[-3:] == ['--', source + '/', dest + '/']
assert '--progress' not in args
assert args[args.index('--stats') + 1] == '10s'
assert '--stats-one-line' in args
assert args[args.index('--stats-log-level') + 1] == 'NOTICE'
for options, jobs in ((['-j', '1'], '1'), (['--jobs', '3'], '3'), (['--jobs=4'], '4')):
    args = run(options)
    assert args[args.index('--transfers') + 1] == jobs
args = run(terminal=True)
assert '--progress' in args and args[args.index('--stats') + 1] == '1s'
for terminal in (False, True):
    args = run(['--dry-run', '--checksum'], terminal=terminal)
    assert '--dry-run' in args and '--checksum' in args
    assert '--progress' not in args and args[args.index('--stats') + 1] == '0'
run(status=23)
proc = subprocess.Popen([script, source, dest], env=dict(env, WAIT_SIGNAL='1'),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    deadline = time.monotonic() + 5
    while not Path(env['READY']).exists():
        assert proc.poll() is None, 'process exited before ready'
        assert time.monotonic() < deadline, 'process did not start'
        time.sleep(0.01)
    assert json.loads(Path(env['CAPTURE']).read_text())['pid'] == proc.pid, 'rclone was not execed'
    proc.send_signal(signal.SIGTERM)
    assert proc.wait(timeout=5) == 143
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
PY

echo 'rsync_backup tests passed (rclone backend)'
