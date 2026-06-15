#!/usr/bin/env bash

set -euo pipefail

DEFAULT_MAX_LOOPS=5
exec_datetime="$(date '+%Y%m%d_%H%M%S')"

usage() {
    echo "Usage: bash scripts/review_untill_satisfied.sh [OPTIONS]"
    echo ""
    echo "Run Codex review/fix cycles until review is satisfied or max loops is reached."
    echo ""
    echo "Options:"
    echo "  --repo PATH       Git repository path. Defaults to the current working directory's Git root."
    echo "  --max-loops N     Maximum review/fix loops. Default: ${DEFAULT_MAX_LOOPS}."
    echo "  --log-dir PATH    Directory for logs. Default: <repo_root>/.review_untill_satisfied/logs."
    echo "  -h, --help        Show this help message."
}

error() {
    echo "Error: $*" >&2
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [ -z "$value" ]; then
        error "${option} requires a value."
        usage >&2
        exit 2
    fi
}

resolve_git_root() {
    local target="$1"
    local root
    if ! root="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"; then
        error "${target} is not a Git repository."
        exit 2
    fi
    printf '%s\n' "$root"
}

resolve_json_python() {
    local python_candidate
    if [ -n "${REVIEW_UNTIL_PYTHON:-}" ]; then
        if ! python_candidate="$(command -v -- "$REVIEW_UNTIL_PYTHON" 2>/dev/null)"; then
            error "REVIEW_UNTIL_PYTHON does not name an executable Python: ${REVIEW_UNTIL_PYTHON}"
            exit 2
        fi
        printf '%s\n' "$python_candidate"
        return
    fi

    if python_candidate="$(command -v python3 2>/dev/null)"; then
        printf '%s\n' "$python_candidate"
        return
    fi

    if python_candidate="$(command -v python 2>/dev/null)"; then
        printf '%s\n' "$python_candidate"
        return
    fi

    error "No Python interpreter found. Set REVIEW_UNTIL_PYTHON or install python3/python."
    exit 2
}

parse_review_status() {
    "$JSON_PYTHON" - "$1" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    review = json.loads(path.read_text())
except Exception as exc:
    print(f"Could not parse review JSON: {exc}", file=sys.stderr)
    sys.exit(2)

satisfied = review.get("satisfied") is True
findings = review.get("findings")
findings_empty = isinstance(findings, list) and len(findings) == 0

if satisfied or findings_empty:
    print("pass")
else:
    print("fail")
PY
}

repo_target="$PWD"
max_loops="$DEFAULT_MAX_LOOPS"
log_dir_arg=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --repo)
            require_value "$1" "${2:-}"
            repo_target="$2"
            shift 2
            ;;
        --max-loops)
            require_value "$1" "${2:-}"
            max_loops="$2"
            shift 2
            ;;
        --log-dir)
            require_value "$1" "${2:-}"
            log_dir_arg="$2"
            shift 2
            ;;
        *)
            error "Unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

if ! is_positive_integer "$max_loops"; then
    error "--max-loops must be a positive integer."
    usage >&2
    exit 2
fi

project_root="$(resolve_git_root "$repo_target")"
JSON_PYTHON="$(resolve_json_python)"
if [ -n "$log_dir_arg" ]; then
    log_dir="$log_dir_arg"
else
    log_dir="${project_root}/.review_untill_satisfied/logs"
fi
log_file="${log_dir}/${exec_datetime}.log"
mkdir -p "$log_dir"

tmp_dir="$(mktemp -d)"
schema_file="${tmp_dir}/review_schema.json"
review_json="${tmp_dir}/review.json"

cat > "$schema_file" <<'JSON'
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "satisfied": {
      "type": "boolean"
    },
    "summary": {
      "type": "string"
    },
    "findings": {
      "type": "array",
      "items": {}
    }
  },
  "required": [
    "satisfied",
    "summary",
    "findings"
  ]
}
JSON

cleanup() {
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

{
    echo "Review/fix loop started at ${exec_datetime}"
    echo "Project root: ${project_root}"
    echo "Max loops: ${max_loops}"
    echo "Review command: codex exec review --uncommitted"
    echo ""
} >> "$log_file"

echo "Review/fix log: ${log_file}"

for ((loop = 1; loop <= max_loops; loop++)); do
    echo "Review ${loop}/${max_loops}..."
    {
        echo "===== Review ${loop}/${max_loops} ====="
        date '+Started: %Y-%m-%d %H:%M:%S'
    } >> "$log_file"

    if (
        cd "$project_root"
        codex exec review --uncommitted --output-schema "$schema_file"
    ) > "$review_json" 2>> "$log_file"; then
        :
    else
        status=$?
        {
            echo "Review command failed with exit code ${status}"
            echo ""
        } >> "$log_file"
        error "Review command failed. See log: ${log_file}"
        exit "$status"
    fi

    {
        echo "--- Structured review JSON ---"
        cat "$review_json"
        echo ""
    } >> "$log_file"

    if review_status="$(parse_review_status "$review_json" 2>> "$log_file")"; then
        :
    else
        status=$?
        error "Could not parse review JSON. See log: ${log_file}"
        exit "$status"
    fi
    if [ "$review_status" = "pass" ]; then
        echo "Review passed on loop ${loop}. Log: ${log_file}"
        {
            echo "Review passed on loop ${loop}"
            echo ""
        } >> "$log_file"
        exit 0
    fi

    if [ "$loop" -eq "$max_loops" ]; then
        break
    fi

    echo "Findings remain; applying minimal fixes..."
    {
        echo "===== Fix ${loop}/${max_loops} ====="
        date '+Started: %Y-%m-%d %H:%M:%S'
    } >> "$log_file"

    if (
        cd "$project_root"
        codex exec --sandbox workspace-write "$(printf '%s\n\n%s' \
            'Use the following structured review JSON as context. Make only minimal fixes for the listed findings, avoid unrelated refactors, and run focused verification where practical.' \
            "$(cat "$review_json")")"
    ) >> "$log_file" 2>&1; then
        :
    else
        status=$?
        {
            echo "Fix command failed with exit code ${status}"
            echo ""
        } >> "$log_file"
        error "Fix command failed. See log: ${log_file}"
        exit "$status"
    fi
done

echo "Max loops reached without satisfaction. Log: ${log_file}"
{
    echo "Max loops reached without satisfaction"
    echo ""
} >> "$log_file"
exit 1
