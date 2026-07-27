#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../terminal_tab_spinner.sh
source "${repo_root}/terminal_tab_spinner.sh"

tmp_dir="$(mktemp -d)"
cleanup() {
    terminal_tab_spinner_stop >/dev/null 2>&1 || true
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT

output_file="${tmp_dir}/titles"
export TERMINAL_TAB_SPINNER_FORCE=1

{
    terminal_tab_spinner_start "demo" "Reviewing 1/2"
    first_pid="${TERMINAL_TAB_SPINNER_PID}"
    sleep 0.12

    terminal_tab_spinner_start "demo" "Fixing 1/2"
    if kill -0 "${first_pid}" 2>/dev/null; then
        echo "Expected restarting the spinner to stop the previous process" >&2
        exit 1
    fi

    terminal_tab_spinner_finish "demo"
} >"${output_file}"

if [ -n "${TERMINAL_TAB_SPINNER_PID}" ]; then
    echo "Expected finishing the spinner to clear its PID" >&2
    exit 1
fi

assert_title_written() {
    local title="$1"
    local encoded
    encoded="$(printf '\033]0;%s\007' "${title}")"
    if ! grep -Fq -- "${encoded}" "${output_file}"; then
        printf 'Expected terminal title %q. Raw output:\n' "${title}" >&2
        od -An -tx1c "${output_file}" >&2
        exit 1
    fi
}

assert_title_written "⠋ demo · Reviewing 1/2"
assert_title_written "⠙ demo · Reviewing 1/2"
assert_title_written "⠋ demo · Fixing 1/2"
assert_title_written "! demo"

sanitized_output="${tmp_dir}/sanitized"
expected_sanitized_output="${tmp_dir}/expected-sanitized"
terminal_tab_spinner_set_title $'demo\a\033\nstatus' >"${sanitized_output}"
printf '\033]0;demostatus\007' >"${expected_sanitized_output}"
if ! cmp -s "${expected_sanitized_output}" "${sanitized_output}"; then
    echo "Expected control characters to be stripped from terminal titles" >&2
    od -An -tx1c "${sanitized_output}" >&2
    exit 1
fi

unset TERMINAL_TAB_SPINNER_FORCE
TERMINAL_TAB_SPINNER_PROJECT=""
disabled_output="${tmp_dir}/disabled"
terminal_tab_spinner_start "demo" "Hidden" >"${disabled_output}"
terminal_tab_spinner_finish "demo" >>"${disabled_output}"
if [ -s "${disabled_output}" ]; then
    echo "Expected spinner output to be disabled when stdout is not a TTY" >&2
    exit 1
fi
