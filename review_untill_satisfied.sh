#!/usr/bin/env bash

set -euo pipefail
caller_umask="$(umask)"
umask 077

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
    echo "  --resume [LOG]    Resume LOG, or the newest incomplete run for the repository."
    echo "  --allow-worktree-changes"
    echo "                    Resume even when the worktree differs from the saved checkpoint."
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

worktree_fingerprint() {
    "$JSON_PYTHON" - "$project_root" <<'PY'
import hashlib
import os
import stat
import subprocess
import sys

def git(root, *args, check=True):
    return subprocess.run(
        ["git", "-C", root, *args],
        check=check, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )

def add_field(h, label, value):
    h.update(label + b"\0" + len(value).to_bytes(8, "big") + value)

def repository_fingerprint(root, ancestors):
    canonical_root = os.path.realpath(root)
    if canonical_root in ancestors:
        raise RuntimeError(f"recursive submodule checkout detected at {root}")
    ancestors = ancestors | {canonical_root}
    root_bytes = os.fsencode(root)
    h = hashlib.sha256()

    head_result = git(root, "rev-parse", "--verify", "HEAD", check=False)
    if head_result.returncode == 0:
        head = head_result.stdout
    else:
        symbolic_head = git(root, "symbolic-ref", "-q", "HEAD", check=False)
        if symbolic_head.returncode != 0:
            raise subprocess.CalledProcessError(
                head_result.returncode, head_result.args,
                output=head_result.stdout, stderr=head_result.stderr
            )
        head = b"<unborn-head>\n"

    for label, value in (
        (b"head", head),
        (b"staged", git(root, "diff", "--cached", "--binary", "--no-ext-diff").stdout),
        (b"unstaged", git(root, "diff", "--binary", "--no-ext-diff").stdout),
    ):
        add_field(h, label, value)

    paths = [
        path for path in
        git(root, "ls-files", "--others", "--exclude-standard", "-z").stdout.split(b"\0")
        if path
    ]
    for path in sorted(paths):
        full = os.path.join(root_bytes, path)
        st = os.lstat(full)
        if stat.S_ISREG(st.st_mode):
            kind = b"file+x" if st.st_mode & 0o111 else b"file"
            with open(full, "rb") as stream:
                content = stream.read()
        elif stat.S_ISLNK(st.st_mode):
            kind = b"symlink"
            content = os.fsencode(os.readlink(full))
        elif stat.S_ISDIR(st.st_mode):
            kind, content = b"dir", b""
        else:
            kind, content = f"special:{stat.S_IFMT(st.st_mode):o}".encode(), b""
        h.update(b"untracked\0" + path + b"\0" + kind + b"\0")
        h.update(len(content).to_bytes(8, "big") + content)

    gitlinks = []
    for entry in git(root, "ls-files", "--stage", "-z").stdout.split(b"\0"):
        if not entry:
            continue
        metadata, separator, path = entry.partition(b"\t")
        fields = metadata.split()
        if separator and len(fields) == 3 and fields[0] == b"160000" and fields[2] == b"0":
            gitlinks.append((path, fields[1]))

    for path, object_id in sorted(gitlinks):
        submodule_root_bytes = os.path.join(root_bytes, path)
        submodule_root = os.fsdecode(submodule_root_bytes)
        top_level = git(submodule_root, "rev-parse", "--show-toplevel", check=False)
        if (
            top_level.returncode != 0 or
            os.path.realpath(os.fsdecode(top_level.stdout.rstrip(b"\n"))) !=
            os.path.realpath(submodule_root)
        ):
            state = b"uninitialized"
        else:
            nested = repository_fingerprint(submodule_root, ancestors)
            state = b"checked-out\0" + nested.encode("ascii")
        add_field(h, b"submodule", path + b"\0" + object_id + b"\0" + state)

    return h.hexdigest()

print(repository_fingerprint(sys.argv[1], set()))
PY
}

state_get() {
    "$JSON_PYTHON" - "$state_file" "$1" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)[sys.argv[2]]
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
PY
}

validate_state_file() {
    "$JSON_PYTHON" - "$1" <<'PY'
import json
import sys
required = {
    "schema_version": int, "repo_path": str, "log_path": str,
    "service_tier": str, "max_loops": int, "loop": int, "phase": str,
    "phase_status": str, "run_status": str, "session_id": str,
    "worktree_fingerprint": str, "fingerprint_trustworthy": bool,
    "created_at": str, "updated_at": str,
}
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        state = json.load(stream)
except Exception as exc:
    print(f"Could not parse resume state {sys.argv[1]}: {exc}", file=sys.stderr)
    sys.exit(2)
if state.get("schema_version") != 1:
    print(f"Unsupported resume state schema in {sys.argv[1]}", file=sys.stderr)
    sys.exit(2)
bad = [key for key, kind in required.items()
       if key not in state or isinstance(state[key], bool) != (kind is bool)
       or not isinstance(state[key], kind)]
if bad:
    print(f"Invalid resume state {sys.argv[1]}: {', '.join(bad)}", file=sys.stderr)
    sys.exit(2)
if state["phase"] not in ("review", "fix") or state["phase_status"] not in (
    "pending", "running", "failed", "completed"
) or state["run_status"] not in ("running", "resumable", "exhausted", "passed"):
    print(f"Invalid resume state values in {sys.argv[1]}", file=sys.stderr)
    sys.exit(2)
PY
}

write_state() {
    local fingerprint="${1:-$worktree_fingerprint_value}"
    local trustworthy="${2:-$fingerprint_trustworthy}"
    "$JSON_PYTHON" - "$state_file" "$project_root" "$log_file" "$service_tier" \
        "$max_loops" "$loop" "$phase" "$phase_status" "$run_status" "$session_id" \
        "$fingerprint" "$trustworthy" "$created_at" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

(path, repo, log, tier, max_loops, loop, phase, phase_status, run_status,
 session_id, fingerprint, trustworthy, created_at) = sys.argv[1:]
data = {
    "schema_version": 1,
    "repo_path": repo,
    "log_path": log,
    "service_tier": tier,
    "max_loops": int(max_loops),
    "loop": int(loop),
    "phase": phase,
    "phase_status": phase_status,
    "run_status": run_status,
    "session_id": session_id,
    "worktree_fingerprint": fingerprint,
    "fingerprint_trustworthy": trustworthy == "true",
    "created_at": created_at,
    "updated_at": datetime.now(timezone.utc).isoformat(),
}
target = Path(path)
temporary = target.with_name(target.name + f".tmp.{os.getpid()}")
fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        json.dump(data, stream, ensure_ascii=False, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)
finally:
    try:
        temporary.unlink()
    except FileNotFoundError:
        pass
PY
}

extract_session_id() {
    "$JSON_PYTHON" - "$1" <<'PY'
import json
import sys
session = ""
try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        for line in stream:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "thread.started":
                value = event.get("thread_id") or event.get("session_id")
                if isinstance(value, str):
                    session = value
except FileNotFoundError:
    pass
print(session)
PY
}

repo_target="$PWD"
max_loops="$DEFAULT_MAX_LOOPS"
max_loops_provided=false
log_dir_arg=""
service_tier="default"
resume_requested=false
resume_log_arg=""
allow_worktree_changes=false
repo_provided=false

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --repo)
            require_value "$1" "${2:-}"
            repo_target="$2"
            repo_provided=true
            shift 2
            ;;
        --max-loops)
            require_value "$1" "${2:-}"
            max_loops="$2"
            max_loops_provided=true
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
        --resume)
            resume_requested=true
            if [ $# -gt 1 ] && [[ "$2" != -* ]]; then
                resume_log_arg="$2"
                shift 2
            else
                shift
            fi
            ;;
        --resume=*)
            resume_requested=true
            resume_log_arg="${1#--resume=}"
            require_value "--resume" "$resume_log_arg"
            shift
            ;;
        --allow-worktree-changes)
            allow_worktree_changes=true
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

JSON_PYTHON="$(resolve_json_python)"
default_log_dir() {
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
    printf '%s\n' "${state_root}/review_untill_satisfied/${repo_name}/logs"
}

if [ "$resume_requested" = true ] && [ "$service_tier" = "fast" ]; then
    error "--fast is invalid with --resume; the stored service tier is used."
    exit 2
fi
if [ -n "$resume_log_arg" ] && [ -n "$log_dir_arg" ]; then
    error "--log-dir cannot be used with an explicit resume log."
    exit 2
fi

resuming=false
if [ "$resume_requested" = true ] && [ -n "$resume_log_arg" ]; then
    log_file="$(resolve_path "$resume_log_arg")"
    state_file="${log_file}.state.json"
    if [ ! -f "$log_file" ] || [ ! -f "$state_file" ]; then
        error "Resume requires a log with a versioned .state.json sidecar; legacy logs are unsupported: ${log_file}"
        exit 2
    fi
    validate_state_file "$state_file"
    stored_repo="$(state_get repo_path)"
    if [ "$repo_provided" = true ]; then
        project_root="$(resolve_git_root "$repo_target")"
        if [ "$project_root" != "$stored_repo" ]; then
            error "--repo does not match the repository stored for this run."
            exit 2
        fi
    else
        project_root="$stored_repo"
    fi
    if [ "$(state_get log_path)" != "$log_file" ]; then
        error "Resume state log path does not match: ${log_file}"
        exit 2
    fi
    resuming=true
else
    project_root="$(resolve_git_root "$repo_target")"
fi

project_name="$(basename -- "$project_root")"

if [ "$resuming" = false ]; then
    if [ -n "$log_dir_arg" ]; then
        log_dir="$log_dir_arg"
        tool_owned_log_dir=false
    else
        log_dir="$(default_log_dir)"
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

    if [ "$resume_requested" = true ]; then
        state_file="$("$JSON_PYTHON" - "$log_dir" "$project_root" \
            "$max_loops_provided" "$max_loops" <<'PY'
import json
import sys
from pathlib import Path

directory = Path(sys.argv[1])
repo = Path(sys.argv[2])
max_loops_provided = sys.argv[3] == "true"
requested_max_loops = int(sys.argv[4])
candidates = []
required = {
    "schema_version": int, "repo_path": str, "log_path": str,
    "service_tier": str, "max_loops": int, "loop": int, "phase": str,
    "phase_status": str, "run_status": str, "session_id": str,
    "worktree_fingerprint": str, "fingerprint_trustworthy": bool,
    "created_at": str, "updated_at": str,
}
for path in directory.glob("*.log.state.json"):
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
        if any(
            key not in state
            or isinstance(state[key], bool) != (kind is bool)
            or not isinstance(state[key], kind)
            for key, kind in required.items()
        ):
            continue
        if (
            state["schema_version"] != 1
            or state["phase"] not in ("review", "fix")
            or state["phase_status"] not in ("pending", "running", "failed", "completed")
            or state["run_status"] not in ("running", "resumable", "exhausted", "passed")
        ):
            continue
        status = state["run_status"]
        exhausted_is_extendable = (
            status == "exhausted"
            and max_loops_provided
            and requested_max_loops > state["max_loops"]
        )
        if (
            state["repo_path"] == str(repo)
            and (status in {"running", "resumable"} or exhausted_is_extendable)
        ):
            candidates.append((state["updated_at"], path.stat().st_mtime_ns, path))
    except Exception:
        continue
if not candidates:
    sys.exit(1)
print(max(candidates)[2])
PY
        )" || {
            error "No incomplete resumable run found for repository: ${project_root}"
            exit 2
        }
        validate_state_file "$state_file"
        log_file="${state_file%.state.json}"
        resuming=true
    else
        log_file="$(mktemp "${log_dir}/${exec_datetime}.XXXXXX.log")"
        chmod 600 "$log_file"
        state_file="${log_file}.state.json"
    fi
fi

review_json="${log_file}.review.json"
events_file="${log_file}.events.jsonl"
lock_file="${log_file}.lock"
touch "$review_json" "$events_file" "$lock_file"
chmod 600 "$review_json" "$events_file" "$lock_file"
exec 9>"$lock_file"
if ! flock -n 9; then
    error "Run is already active and cannot be resumed: ${log_file}"
    exit 2
fi

tmp_dir="$(mktemp -d)"
schema_file="${tmp_dir}/review_schema.json"

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

# Keep logs and durable sidecars private without changing the permissions of
# files that Codex (or commands it launches) creates in the target repository.
umask "$caller_umask"

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

state_initialized=false
active_invocation_events=""
active_codex_pid=""

terminate_active_codex() {
    local pid="$active_codex_pid"
    local _
    [ -n "$pid" ] || return 0

    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..20}; do
        if ! kill -0 -- "-$pid" 2>/dev/null && ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 0.1
    done
    if kill -0 -- "-$pid" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    active_codex_pid=""
}

cleanup() {
    local status=$?
    terminal_tab_spinner_finish "$project_name" || true
    terminate_active_codex
    if [ "$state_initialized" = true ] && [ "$phase_status" = "running" ]; then
        if [ -n "$active_invocation_events" ]; then
            cleanup_session_id="$(extract_session_id "$active_invocation_events")"
            [ -z "$cleanup_session_id" ] || session_id="$cleanup_session_id"
        fi
        if cleanup_fingerprint="$(worktree_fingerprint 2>/dev/null)"; then
            worktree_fingerprint_value="$cleanup_fingerprint"
            fingerprint_trustworthy=true
        else
            fingerprint_trustworthy=false
        fi
        phase_status="failed"
        run_status="resumable"
        write_state "$worktree_fingerprint_value" "$fingerprint_trustworthy" || true
    fi
    rm -rf "$tmp_dir" || true
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$resuming" = true ]; then
    stored_max_loops="$(state_get max_loops)"
    if [ "$max_loops_provided" = true ]; then
        if [ "$max_loops" -lt "$stored_max_loops" ]; then
            error "--max-loops cannot be lower than the stored total (${stored_max_loops})."
            exit 2
        fi
    else
        max_loops="$stored_max_loops"
    fi
    service_tier="$(state_get service_tier)"
    loop="$(state_get loop)"
    phase="$(state_get phase)"
    phase_status="$(state_get phase_status)"
    run_status="$(state_get run_status)"
    session_id="$(state_get session_id)"
    worktree_fingerprint_value="$(state_get worktree_fingerprint)"
    fingerprint_trustworthy="$(state_get fingerprint_trustworthy)"
    created_at="$(state_get created_at)"
    if [ "$run_status" = "passed" ]; then
        error "Passed runs are not resumable."
        exit 2
    fi
    if [ "$run_status" = "exhausted" ] && [ "$max_loops" -le "$stored_max_loops" ]; then
        error "This run exhausted ${stored_max_loops} loops; resume with a larger --max-loops total."
        exit 2
    fi
    current_fingerprint="$(worktree_fingerprint)"
    if { [ "$phase_status" = "running" ] && [ "$fingerprint_trustworthy" != "true" ]; } ||
        [ "$current_fingerprint" != "$worktree_fingerprint_value" ]; then
        if [ "$allow_worktree_changes" != true ]; then
            error "Worktree differs from the trustworthy saved checkpoint; use --allow-worktree-changes to resume explicitly."
            exit 2
        fi
    fi
    if [ "$phase" = "fix" ] && { [ "$phase_status" = "failed" ] || [ "$phase_status" = "running" ]; } &&
        [ -z "$session_id" ]; then
        error "A partially completed Fix has no captured session and cannot be rerun automatically."
        exit 2
    fi
    worktree_fingerprint_value="$current_fingerprint"
    fingerprint_trustworthy=true
    run_status="resumable"
    write_state
    echo "Resuming review/fix log: ${log_file}"
    {
        echo "===== Resumed $(date -u '+%Y-%m-%dT%H:%M:%SZ') ====="
        echo "Max loops: ${max_loops}"
        echo "Service tier: ${service_tier}"
    } >> "$log_file"
else
    loop=1
    phase=review
    phase_status=pending
    run_status=running
    session_id=""
    worktree_fingerprint_value="$(worktree_fingerprint)"
    fingerprint_trustworthy=true
    created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    write_state
    {
        echo "Review/fix loop started at ${exec_datetime}"
        echo "Project root: ${project_root}"
        echo "Max loops: ${max_loops}"
        echo "Service tier: ${service_tier}"
        echo "Review command: codex exec -c service_tier=\"${service_tier}\" --json --sandbox read-only --output-schema ${schema_file} --output-last-message ${review_json} <review prompt>"
        echo ""
    } >> "$log_file"
    echo "Review/fix log: ${log_file}"
fi
state_initialized=true

is_codex_timeout_event() {
    "$JSON_PYTHON" -c '
import json
import sys

try:
    event = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError):
    sys.exit(1)

sys.exit(not (
    isinstance(event, dict)
    and event.get("type") == "error"
    and isinstance(event.get("message"), str)
    and "request timed out" in event["message"]
))
' "$1"
}

run_codex_phase() {
    local prompt="$1"
    local invocation_events="${tmp_dir}/invocation.events.jsonl"
    local stdout_fifo="${tmp_dir}/codex.stdout.fifo"
    local codex_pid codex_status line timeout_watchdog_pid=""
    local continue_session=false
    local timeout_detected=false
    : > "$invocation_events"
    mkfifo "$stdout_fifo"
    active_invocation_events="$invocation_events"
    if [ -n "$session_id" ] && { [ "$phase_status" = "failed" ] || [ "$phase_status" = "running" ]; }; then
        continue_session=true
    else
        session_id=""
    fi
    phase_status=running
    run_status=running
    fingerprint_trustworthy=false
    write_state "$worktree_fingerprint_value" false

    if [ "$continue_session" = true ]; then
        if [ "$phase" = review ]; then
            (
                exec 9>&-
                cd "$project_root"
                exec setsid codex exec resume "$session_id" -c "service_tier=\"${service_tier}\"" \
                    -c 'sandbox_mode="read-only"' \
                    --json --output-schema "$schema_file" --output-last-message "$review_json" "$prompt" \
                    >"$stdout_fifo" 2>> "$log_file"
            ) &
        else
            (
                exec 9>&-
                cd "$project_root"
                exec setsid codex exec resume "$session_id" -c "service_tier=\"${service_tier}\"" \
                    -c 'sandbox_mode="workspace-write"' \
                    --json "$prompt" >"$stdout_fifo" 2>> "$log_file"
            ) &
        fi
    else
        if [ "$phase" = review ]; then
            (
                exec 9>&-
                cd "$project_root"
                exec setsid codex exec -c "service_tier=\"${service_tier}\"" --json --sandbox read-only \
                    --output-schema "$schema_file" --output-last-message "$review_json" "$prompt" \
                    >"$stdout_fifo" 2>> "$log_file"
            ) &
        else
            (
                exec 9>&-
                cd "$project_root"
                exec setsid codex exec -c "service_tier=\"${service_tier}\"" --json --sandbox workspace-write \
                    "$prompt" >"$stdout_fifo" 2>> "$log_file"
            ) &
        fi
    fi
    codex_pid=$!
    active_codex_pid="$codex_pid"

    while IFS= read -r line; do
        printf '%s\n' "$line" >> "$invocation_events"
        printf '%s\n' "$line" >> "$events_file"
        printf '%s\n' "$line" >> "$log_file"
        if [ "$timeout_detected" = false ] && is_codex_timeout_event "$line"; then
            timeout_detected=true
            echo "Codex ${phase} phase reported request timed out; terminating invocation." >> "$log_file"
            kill -TERM -- "-$codex_pid" 2>/dev/null || kill -TERM "$codex_pid" 2>/dev/null || true
            (
                for _ in {1..20}; do
                    if ! kill -0 -- "-$codex_pid" 2>/dev/null; then
                        exit 0
                    fi
                    sleep 0.1
                done
                kill -KILL -- "-$codex_pid" 2>/dev/null || kill -KILL "$codex_pid" 2>/dev/null || true
            ) &
            timeout_watchdog_pid=$!
        fi
    done < "$stdout_fifo"
    if wait "$codex_pid"; then codex_status=0; else codex_status=$?; fi
    active_codex_pid=""
    if [ -n "$timeout_watchdog_pid" ]; then
        wait "$timeout_watchdog_pid" || true
    fi
    rm -f "$stdout_fifo"

    if [ "$timeout_detected" = true ]; then
        return 124
    fi
    return "$codex_status"
}

while [ "$loop" -le "$max_loops" ]; do
    if [ "$phase" = fix ] && [ "$phase_status" = completed ]; then
        loop=$((loop + 1))
        phase=review
        phase_status=pending
        session_id=""
        run_status=resumable
        write_state
    fi

    if [ "$phase" = review ]; then
        if [ "$phase_status" != completed ]; then
            echo "Review ${loop}/${max_loops}..."
            {
                echo "===== Review ${loop}/${max_loops} ====="
                date '+Started: %Y-%m-%d %H:%M:%S'
            } >> "$log_file"
            terminal_tab_spinner_start "$project_name" "Reviewing ${loop}/${max_loops}"
            if run_codex_phase "$review_prompt"; then status=0; else status=$?; fi
            terminal_tab_spinner_stop
            new_session_id="$(extract_session_id "${tmp_dir}/invocation.events.jsonl")"
            [ -z "$new_session_id" ] || session_id="$new_session_id"
            worktree_fingerprint_value="$(worktree_fingerprint)"
            fingerprint_trustworthy=true
            if [ "$status" -ne 0 ]; then
                phase_status=failed
                run_status=resumable
                write_state
                echo "Review command failed with exit code ${status}" >> "$log_file"
                if [ "$status" -eq 124 ]; then
                    error "Review phase timed out after Codex reported request timed out. The run can be resumed. See log: ${log_file}"
                else
                    error "Review command failed. See log: ${log_file}"
                fi
                exit "$status"
            fi
            phase_status=completed
            run_status=resumable
            session_id=""
            write_state
        fi

        {
            echo "--- Structured review JSON ---"
            echo "Path: ${review_json}"
            if [ -f "$review_json" ]; then cat "$review_json"; else echo "(review JSON file missing)"; fi
            echo ""
        } >> "$log_file"
        if review_status="$(parse_review_status "$review_json" 2>> "$log_file")"; then :; else
            status=$?
            phase_status=failed
            run_status=resumable
            write_state
            error "Could not validate review JSON. See log: ${log_file}"
            exit "$status"
        fi
        print_review_feedback "$review_json" "$loop" "$max_loops"
        echo ""
        if [ "$review_status" = pass ]; then
            run_status=passed
            phase_status=completed
            write_state
            echo "Review passed on loop ${loop}. Log: ${log_file}"
            echo "Review passed on loop ${loop}" >> "$log_file"
            exit 0
        fi
        if [ "$loop" -eq "$max_loops" ]; then
            run_status=exhausted
            write_state
            echo "Max loops reached without satisfaction. Log: ${log_file}"
            echo "Max loops reached without satisfaction" >> "$log_file"
            exit 1
        fi
        phase=fix
        phase_status=pending
        session_id=""
        run_status=resumable
        write_state
    fi

    fix_prompt="$(printf '%s\n\n%s' \
        'Use the following structured review JSON as context. Make only minimal fixes for the listed findings, avoid unrelated refactors, and run focused verification where practical.' \
        "$(cat "$review_json")")"
    if [ "$phase_status" != completed ]; then
        echo "Findings remain; applying minimal fixes..."
        echo "Modification prompt ${loop}/${max_loops}:"
        printf '%s\n\n' "$fix_prompt" | print_terminal_safe
        {
            echo "===== Fix ${loop}/${max_loops} ====="
            date '+Started: %Y-%m-%d %H:%M:%S'
            echo "--- Modification prompt ---"
            printf '%s\n\n' "$fix_prompt"
        } >> "$log_file"
        terminal_tab_spinner_start "$project_name" "Fixing ${loop}/${max_loops}"
        if run_codex_phase "$fix_prompt"; then status=0; else status=$?; fi
        terminal_tab_spinner_stop
        new_session_id="$(extract_session_id "${tmp_dir}/invocation.events.jsonl")"
        [ -z "$new_session_id" ] || session_id="$new_session_id"
        worktree_fingerprint_value="$(worktree_fingerprint)"
        fingerprint_trustworthy=true
        if [ "$status" -ne 0 ]; then
            phase_status=failed
            run_status=resumable
            write_state
            echo "Fix command failed with exit code ${status}" >> "$log_file"
            if [ "$status" -eq 124 ]; then
                error "Fix phase timed out after Codex reported request timed out. The run can be resumed. See log: ${log_file}"
            else
                error "Fix command failed. See log: ${log_file}"
            fi
            exit "$status"
        fi
        phase_status=completed
        run_status=resumable
        session_id=""
        write_state
    fi
done
