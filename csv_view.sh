#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./csv_view.sh <csv_file>
  cat data.csv | ./csv_view.sh

Examples:
  ./csv_view.sh data.csv
  cat data.csv | ./csv_view.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$#" -gt 1 ]]; then
  usage
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: requires python3." >&2
  exit 2
fi

pager="${PAGER:-less}"
read -r -a pager_args <<<"${pager}"
if [[ "${#pager_args[@]}" -eq 0 ]]; then
  pager_args=(less)
fi
pager_cmd="${pager_args[0]}"
if ! command -v "${pager_cmd}" >/dev/null 2>&1; then
  echo "Error: requires pager command: ${pager}" >&2
  exit 2
fi

page_output() {
  local pager_stderr
  local pager_status

  pager_stderr="$(mktemp "${TMPDIR:-/tmp}/csv-view-pager-stderr.XXXXXX")" || return 1

  if [[ "${pager_cmd##*/}" == "less" ]]; then
    "${pager_args[@]}" -S 2>"${pager_stderr}"
  else
    "${pager_args[@]}" 2>"${pager_stderr}"
  fi
  pager_status="$?"

  if [[ "${pager_status}" -ne 0 ]] && is_broken_pipe_stderr "${pager_stderr}"; then
    rm -f "${pager_stderr}"
    return 141
  fi

  emit_stderr_file "${pager_stderr}"
  rm -f "${pager_stderr}"
  return "${pager_status}"
}

is_broken_pipe_stderr() {
  local file="$1"

  [[ -s "${file}" ]] || return 1
  ! grep -viq "broken pipe" "${file}"
}

emit_stderr_file() {
  local file="$1"
  local line

  while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '%s\n' "${line}" >&2
  done <"${file}"
}

format_and_page() {
  local statuses
  local format_status
  local pager_status

  set +e
  set +o pipefail
  if [[ "$#" -eq 1 ]]; then
    format_csv <"$1" | page_output
  else
    format_csv | page_output
  fi
  statuses=("${PIPESTATUS[@]}")
  set -o pipefail
  set -e
  format_status="${statuses[0]}"
  pager_status="${statuses[1]}"

  if [[ "${format_status}" -ne 0 ]]; then
    return "${format_status}"
  fi

  if [[ "${pager_status}" -eq 141 ]]; then
    return 0
  fi

  return "${pager_status}"
}

format_csv() {
  python3 -c '
import csv
import re
import os
import sys
import unicodedata

ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

def display_cell(value):
    return value.replace("\t", "\\t").replace("\r", "\\r").replace("\n", "\\n")

def char_width(char):
    if unicodedata.combining(char):
        return 0
    if unicodedata.category(char) in ("Mn", "Me", "Cf"):
        return 0
    if unicodedata.east_asian_width(char) in ("F", "W"):
        return 2
    return 1

def display_width(value):
    width = 0
    index = 0
    while index < len(value):
        match = ANSI_ESCAPE_RE.match(value, index)
        if match:
            index = match.end()
            continue
        width += char_width(value[index])
        index += 1
    return width

def pad_cell(value, width):
    return value + (" " * max(0, width - display_width(value)))

def main():
    rows = [
        [display_cell(value) for value in row]
        for row in csv.reader(sys.stdin)
    ]
    if not rows:
        return

    widths = []
    for row in rows:
        if len(row) > len(widths):
            widths.extend([0] * (len(row) - len(widths)))
        for index, value in enumerate(row):
            widths[index] = max(widths[index], display_width(value))

    for row in rows:
        padded = [
            pad_cell(value, widths[index])
            for index, value in enumerate(row)
        ]
        print("  ".join(padded).rstrip())

try:
    main()
except BrokenPipeError:
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, sys.stdout.fileno())
    sys.exit(0)
'
}

if [[ "$#" -eq 1 ]]; then
  csv_file="$1"

  if [[ ! -e "${csv_file}" ]]; then
    echo "Error: file does not exist: ${csv_file}" >&2
    exit 1
  fi

  if [[ ! -f "${csv_file}" ]]; then
    echo "Error: not a regular file: ${csv_file}" >&2
    exit 1
  fi

  if [[ ! -r "${csv_file}" ]]; then
    echo "Error: file is not readable: ${csv_file}" >&2
    exit 1
  fi

  format_and_page "${csv_file}"
else
  if [[ -t 0 ]]; then
    usage
    exit 1
  fi

  format_and_page
fi
