#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=terminal_tab_spinner.sh
source "${script_dir}/terminal_tab_spinner.sh"

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
    echo "  --log-dir PATH    Directory for logs; it must be outside the target repository."
    echo "                    Default: <XDG_STATE_HOME or ~/.local/state>/review_untill_satisfied/<repo>/logs."
    echo "  --fast            Use the Codex Fast service tier. Default: disabled."
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

resolve_path() {
    "$JSON_PYTHON" - "$1" <<'PY'
import sys
from pathlib import Path

print(Path(sys.argv[1]).resolve(strict=False))
PY
}

parse_review_status() {
    "$JSON_PYTHON" - "$1" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    raw = path.read_text(encoding="utf-8")
except Exception as exc:
    print(f"Could not read review JSON from {path}: {exc}", file=sys.stderr)
    sys.exit(2)

try:
    review = json.loads(raw)
except Exception as exc:
    print(f"Could not parse review JSON from {path}: {exc}", file=sys.stderr)
    print(f"Raw review JSON size: {len(raw.encode('utf-8'))} bytes", file=sys.stderr)
    if raw:
        print("--- Raw review JSON preview ---", file=sys.stderr)
        print(raw[:4000], file=sys.stderr)
        if len(raw) > 4000:
            print("--- Raw review JSON preview truncated ---", file=sys.stderr)
    else:
        print("Raw review JSON is empty.", file=sys.stderr)
    sys.exit(2)

schema_errors = []
if not isinstance(review, dict):
    schema_errors.append("top-level value is not an object")
else:
    if set(review) != {"satisfied", "summary", "findings"}:
        schema_errors.append(
            "top-level object must contain exactly satisfied, summary, and findings"
        )
    if not isinstance(review.get("satisfied"), bool):
        schema_errors.append("satisfied must be a boolean")
    if not isinstance(review.get("summary"), str):
        schema_errors.append("summary must be a string")
    if not isinstance(review.get("findings"), list):
        schema_errors.append("findings must be an array")
    else:
        for index, finding in enumerate(review["findings"]):
            if not isinstance(finding, dict):
                schema_errors.append(f"findings[{index}] must be an object")
            elif set(finding) != {"issue"} or not isinstance(finding.get("issue"), str):
                schema_errors.append(
                    f"findings[{index}] must contain only a string issue field"
                )

if schema_errors:
    print(f"Review JSON from {path} does not match expected schema: {', '.join(schema_errors)}", file=sys.stderr)
    print("--- Raw review JSON ---", file=sys.stderr)
    print(raw[:4000], file=sys.stderr)
    if len(raw) > 4000:
        print("--- Raw review JSON truncated ---", file=sys.stderr)
    sys.exit(2)

satisfied = review.get("satisfied") is True
findings = review.get("findings")
findings_empty = isinstance(findings, list) and len(findings) == 0

if satisfied and findings_empty:
    print("pass")
elif not satisfied and not findings_empty:
    print("fail")
else:
    print(
        "Review JSON is inconsistent: satisfied must be true exactly when findings is empty",
        file=sys.stderr,
    )
    sys.exit(2)
PY
}

print_review_feedback() {
    "$JSON_PYTHON" - "$1" "$2" "$3" <<'PY'
import json
import sys
import unicodedata
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

review = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
loop = sys.argv[2]
max_loops = sys.argv[3]

def terminal_safe(text):
    return "".join(
        char
        if char == "\n" or unicodedata.category(char) != "Cc"
        else f"\\u{ord(char):04x}"
        for char in text
    )

print(f"Review feedback {loop}/{max_loops}:")
print(f"  Status: {'satisfied' if review['satisfied'] else 'changes requested'}")
print("  Summary:")
summary_lines = terminal_safe(review["summary"]).split("\n")
for line in summary_lines:
    print(f"    {line}")

print("  Findings:")
if not review["findings"]:
    print("    None")
else:
    for index, finding in enumerate(review["findings"], start=1):
        issue_lines = terminal_safe(finding["issue"]).split("\n")
        print(f"    {index}. {issue_lines[0]}")
        for line in issue_lines[1:]:
            print(f"       {line}")
PY
}

print_terminal_safe() {
    "$JSON_PYTHON" -c '
import sys
import unicodedata

sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")

text = sys.stdin.read()
sys.stdout.write(
    "".join(
        char
        if char == "\n" or unicodedata.category(char) != "Cc"
        else f"\\u{ord(char):04x}"
        for char in text
    )
)
'
}

repo_target="$PWD"
max_loops="$DEFAULT_MAX_LOOPS"
log_dir_arg=""
service_tier="default"

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
        --fast)
            service_tier="fast"
            shift
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
project_name="$(basename -- "$project_root")"
JSON_PYTHON="$(resolve_json_python)"
if [ -n "$log_dir_arg" ]; then
    log_dir="$log_dir_arg"
    tool_owned_log_dir=false
else
    if [ -n "${XDG_STATE_HOME:-}" ]; then
        state_root="$XDG_STATE_HOME"
        if [[ "$state_root" != /* ]]; then
            error "XDG_STATE_HOME must be an absolute path."
            exit 2
        fi
    else
        if [ -z "${HOME:-}" ] || [[ "$HOME" != /* ]]; then
            error "HOME must be an absolute path when XDG_STATE_HOME is not set."
            exit 2
        fi
        state_root="${HOME}/.local/state"
    fi
    repo_name="$(basename -- "$project_root")"
    log_dir="${state_root}/review_untill_satisfied/${repo_name}/logs"
    tool_owned_log_dir=true
fi

log_dir="$(resolve_path "$log_dir")"
if [ "$log_dir" = "$project_root" ] || [[ "$log_dir" == "$project_root/"* ]]; then
    error "Log directory must be outside the target repository: ${project_root}"
    exit 2
fi

mkdir -p "$log_dir"
if [ "$tool_owned_log_dir" = true ]; then
    chmod 700 "$log_dir"
fi
log_file="$(mktemp "${log_dir}/${exec_datetime}.XXXXXX.log")"

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
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "issue": {
            "type": "string"
          }
        },
        "required": [
          "issue"
        ]
      }
    }
  },
  "required": [
    "satisfied",
    "summary",
    "findings"
  ]
}
JSON

review_prompt='Review the current uncommitted changes in this repository. Inspect git status, staged and unstaged diffs, and relevant untracked files before deciding.

Return a structured final JSON message that matches the provided output schema:
{
  "satisfied": boolean,
  "summary": string,
  "findings": [
    {
      "issue": string
    }
  ]
}

Set satisfied to true exactly when the review finds no remaining issues, and in that case return an empty findings array. When unsatisfied, include one or more concise, actionable findings, each as an object with only an issue string.'

cleanup() {
    local status=$?
    terminal_tab_spinner_finish "$project_name" || true
    rm -rf "$tmp_dir" || true
    return "$status"
}
trap cleanup EXIT

{
    echo "Review/fix loop started at ${exec_datetime}"
    echo "Project root: ${project_root}"
    echo "Max loops: ${max_loops}"
    echo "Service tier: ${service_tier}"
    echo "Review command: codex exec -c service_tier=\"${service_tier}\" --sandbox read-only --output-schema ${schema_file} --output-last-message ${review_json} <review prompt>"
    echo ""
} >> "$log_file"

echo "Review/fix log: ${log_file}"

for ((loop = 1; loop <= max_loops; loop++)); do
    echo "Review ${loop}/${max_loops}..."
    {
        echo "===== Review ${loop}/${max_loops} ====="
        date '+Started: %Y-%m-%d %H:%M:%S'
    } >> "$log_file"

    terminal_tab_spinner_start "$project_name" "Reviewing ${loop}/${max_loops}"
    if (
        cd "$project_root"
        codex exec -c "service_tier=\"${service_tier}\"" --sandbox read-only \
            --output-schema "$schema_file" --output-last-message "$review_json" "$review_prompt"
    ) >> "$log_file" 2>&1; then
        status=0
    else
        status=$?
    fi
    terminal_tab_spinner_stop
    if [ "$status" -ne 0 ]; then
        {
            echo "Review command failed with exit code ${status}"
            echo ""
        } >> "$log_file"
        error "Review command failed. See log: ${log_file}"
        exit "$status"
    fi

    {
        echo "--- Structured review JSON ---"
        echo "Path: ${review_json}"
        if [ -f "$review_json" ]; then
            cat "$review_json"
        else
            echo "(review JSON file missing)"
        fi
        echo ""
    } >> "$log_file"

    if review_status="$(parse_review_status "$review_json" 2>> "$log_file")"; then
        :
    else
        status=$?
        error "Could not validate review JSON. See log: ${log_file}"
        exit "$status"
    fi

    print_review_feedback "$review_json" "$loop" "$max_loops"
    echo ""

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

    fix_prompt="$(printf '%s\n\n%s' \
        'Use the following structured review JSON as context. Make only minimal fixes for the listed findings, avoid unrelated refactors, and run focused verification where practical.' \
        "$(cat "$review_json")")"

    echo "Modification prompt ${loop}/${max_loops}:"
    printf '%s\n\n' "$fix_prompt" | print_terminal_safe
    {
        echo "--- Modification prompt ---"
        printf '%s\n\n' "$fix_prompt"
    } >> "$log_file"

    terminal_tab_spinner_start "$project_name" "Fixing ${loop}/${max_loops}"
    if (
        cd "$project_root"
        codex exec -c "service_tier=\"${service_tier}\"" --sandbox workspace-write "$fix_prompt"
    ) >> "$log_file" 2>&1; then
        status=0
    else
        status=$?
    fi
    terminal_tab_spinner_stop
    if [ "$status" -ne 0 ]; then
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
