#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/csv_view.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/bin"
less_output="${tmp_dir}/less-output.txt"
less_args="${tmp_dir}/less-args.txt"
cat_output="${tmp_dir}/cat-output.txt"
cat_args="${tmp_dir}/cat-args.txt"

cat >"${tmp_dir}/bin/less" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${FAKE_LESS_ARGS}"
/bin/cat >"${FAKE_LESS_OUTPUT}"
EOF

cat >"${tmp_dir}/bin/cat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$#" -gt 0 ]]; then
  printf '%s\n' "$*" >"${FAKE_CAT_ARGS}"
fi
/bin/tee "${FAKE_CAT_OUTPUT}"
EOF

chmod +x "${tmp_dir}/bin/less"
chmod +x "${tmp_dir}/bin/cat"
export PATH="${tmp_dir}/bin:${PATH}"
export FAKE_LESS_OUTPUT="${less_output}"
export FAKE_LESS_ARGS="${less_args}"
export FAKE_CAT_OUTPUT="${cat_output}"
export FAKE_CAT_ARGS="${cat_args}"
unset PAGER

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
    /bin/cat "${file}" >&2
    exit 1
  fi
}

assert_less_used_with_chop_long_lines() {
  if [[ "$(/bin/cat "${less_args}")" != "-S" ]]; then
    printf 'Expected less to receive -S, got:\n' >&2
    /bin/cat "${less_args}" >&2
    exit 1
  fi
}

assert_cat_used_without_less_options() {
  if [[ -s "${cat_args}" ]]; then
    printf 'Expected cat to receive no arguments, got:\n' >&2
    /bin/cat "${cat_args}" >&2
    exit 1
  fi
}

assert_file_equals() {
  local file="$1"
  local expected="$2"
  local actual

  actual="$(/bin/cat "${file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Expected %s to equal: %s\nActual contents:\n%s\n' "${file}" "${expected}" "${actual}" >&2
    exit 1
  fi
}

csv_file="${tmp_dir}/data.csv"
/bin/cat >"${csv_file}" <<'EOF'
name,city,count
alice,shanghai,12
bob,new york,3
EOF

"${script}" "${csv_file}"
assert_less_used_with_chop_long_lines
assert_file_contains "${less_output}" "name   city      count"
assert_file_contains "${less_output}" "alice  shanghai  12"
assert_file_contains "${less_output}" "bob    new york  3"

>"${less_output}"
quoted_csv_file="${tmp_dir}/quoted.csv"
/bin/cat >"${quoted_csv_file}" <<'EOF'
name,note,count
alice,"hello, world",12
bob,"plain note",3
EOF

"${script}" "${quoted_csv_file}"
assert_less_used_with_chop_long_lines
assert_file_contains "${less_output}" "name   note          count"
assert_file_contains "${less_output}" "alice  hello, world  12"
assert_file_contains "${less_output}" "bob    plain note    3"

>"${less_output}"
unicode_csv_file="${tmp_dir}/unicode.csv"
/bin/cat >"${unicode_csv_file}" <<'EOF'
place,count
上海,12
new york,3
café,1
resume,2
EOF

"${script}" "${unicode_csv_file}"
assert_less_used_with_chop_long_lines
assert_file_contains "${less_output}" "place     count"
assert_file_contains "${less_output}" "上海      12"
assert_file_contains "${less_output}" "new york  3"
assert_file_contains "${less_output}" "café      1"
assert_file_contains "${less_output}" "resume    2"

>"${less_output}"
multiline_csv_file="${tmp_dir}/multiline.csv"
/bin/cat >"${multiline_csv_file}" <<'EOF'
name,note,count
alice,"hello
world",12
bob,"line one
line two",3
EOF

"${script}" "${multiline_csv_file}"
assert_less_used_with_chop_long_lines
assert_file_contains "${less_output}" "name   note                count"
assert_file_contains "${less_output}" "alice  hello\\nworld        12"
assert_file_contains "${less_output}" "bob    line one\\nline two  3"

>"${less_output}"
tab_csv_file="${tmp_dir}/tabs.csv"
printf 'name,note,count\nalice,"hello\tworld",12\nbob,plain,3\n' >"${tab_csv_file}"

"${script}" "${tab_csv_file}"
assert_less_used_with_chop_long_lines
assert_file_contains "${less_output}" "name   note          count"
assert_file_contains "${less_output}" "alice  hello\\tworld  12"
assert_file_contains "${less_output}" "bob    plain         3"

>"${less_output}"
printf 'name,note\nalice,"hello, stdin"\n' | "${script}"
assert_less_used_with_chop_long_lines
assert_file_contains "${less_output}" "name   note"
assert_file_contains "${less_output}" "alice  hello, stdin"

>"${less_output}"
printf 'a,b\nlonger,value\n' | "${script}"
assert_less_used_with_chop_long_lines
assert_file_contains "${less_output}" "a       b"
assert_file_contains "${less_output}" "longer  value"

PAGER=cat "${script}" "${csv_file}" >/dev/null
assert_cat_used_without_less_options
assert_file_contains "${cat_output}" "name   city      count"
assert_file_contains "${cat_output}" "alice  shanghai  12"

>"${less_output}"
PAGER="less -R" "${script}" "${csv_file}"
assert_file_equals "${less_args}" "-R -S"
assert_file_contains "${less_output}" "name   city      count"

>"${cat_args}"
PAGER="cat -n" "${script}" "${csv_file}" >/dev/null
assert_file_equals "${cat_args}" "-n"
assert_file_contains "${cat_output}" "bob    new york  3"

large_csv_file="${tmp_dir}/large.csv"
{
  printf 'name,city,count\n'
  for index in $(seq 1 5000); do
    printf 'name%s,city%s,%s\n' "${index}" "${index}" "${index}"
  done
} >"${large_csv_file}"

set +e
output="$(PAGER="head -n1" "${script}" "${large_csv_file}" 2>&1)"
status=$?
set -e
if [[ "${status}" -ne 0 ]]; then
  printf 'Expected early pager close to succeed, got status %s and output:\n%s\n' "${status}" "${output}" >&2
  exit 1
fi
if [[ "${output}" == *"BrokenPipeError"* || "${output}" == *"Traceback"* ]]; then
  printf 'Expected early pager close not to print a traceback, got:\n%s\n' "${output}" >&2
  exit 1
fi
assert_contains "${output}" "name"

passthrough_stderr="${tmp_dir}/passthrough-stderr.txt"
set +e
PAGER=/bin/cat "${script}" "${large_csv_file}" 2>"${passthrough_stderr}" | head -n1 >/dev/null
pipeline_statuses=("${PIPESTATUS[@]}")
set -e
if [[ "${pipeline_statuses[0]}" -ne 0 ]]; then
  printf 'Expected passthrough pager early downstream close to succeed, got status %s and stderr:\n' "${pipeline_statuses[0]}" >&2
  /bin/cat "${passthrough_stderr}" >&2
  exit 1
fi
if [[ -s "${passthrough_stderr}" ]]; then
  printf 'Expected passthrough pager early downstream close not to print stderr, got:\n' >&2
  /bin/cat "${passthrough_stderr}" >&2
  exit 1
fi

output="$("${script}" --help)"
assert_contains "${output}" "Usage:"
assert_contains "${output}" "cat data.csv | ./csv_view.sh"

set +e
output="$("${script}" "${tmp_dir}/missing.csv" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected missing file to fail" >&2
  exit 1
fi
assert_contains "${output}" "file does not exist"

set +e
output="$("${script}" "${tmp_dir}" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected directory input to fail" >&2
  exit 1
fi
assert_contains "${output}" "not a regular file"
