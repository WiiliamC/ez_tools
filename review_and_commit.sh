#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'HELP'
Usage: review_and_commit.sh [OPTIONS]

Run review/fix cycles, then automatically commit only if review succeeds.

  --review-scope S  changes (default) or branch (local main/master baseline).
  --repo PATH       Repository to review and commit. Default: current directory.
  --max-loops N     Maximum review/fix loops. Default: 12.
  --log-dir PATH    Review log directory outside the target repository.
  --fast            Use the Fast service tier for review/fix steps.
  --resume [LOG]    Resume LOG, or the newest incomplete run for the repository.
  --allow-worktree-changes
                    Allow expected worktree changes when resuming.
  --model MODEL     Commit-message model. Default: gpt-5.6-luna.
  -h, --help        Show this help message.

The commit step always uses -y to skip confirmation. Git hooks and signing
retain their normal behavior. Except for --review-scope, --model and help, all options are
forwarded to the selected review script. Branch scope uses
review_pr_untill_satisfied.sh; changes scope uses
review_changes_untill_satisfied.sh. Its resume rules apply, including
--resume=LOG. The commit always targets the repository selected by review.
HELP
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 2; }
review_scope=changes
review_args=()
commit_args=()
while (($#)); do
    case "$1" in
        --review-scope)
            (($# >= 2)) && [[ "$2" == changes || "$2" == branch ]] || fail "$1 requires changes or branch"
            review_scope="$2"
            shift 2 ;;
        --model)
            (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || fail "$1 requires a value"
            commit_args+=("$1" "$2")
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) review_args+=("$1"); shift ;;
    esac
done

review_script="$script_dir/review_changes_untill_satisfied.sh"
if [[ "$review_scope" == branch ]]; then
    review_script="$script_dir/review_pr_untill_satisfied.sh"
fi

# Review owns repository selection, including selection from a resume log.
result_dir=$(mktemp -d)
trap 'rm -rf -- "$result_dir"' EXIT
review_pid=""
interrupt_review() {
    trap '' INT TERM
    if [[ -n "$review_pid" ]]; then
        # Background shells can inherit ignored SIGINT; TERM reliably invokes
        # the review script's cleanup while we retain the caller's exit status.
        kill -TERM "$review_pid" 2>/dev/null || true
        wait "$review_pid" 2>/dev/null || true
    fi
    exit "$1"
}
trap 'interrupt_review 130' INT
trap 'interrupt_review 143' TERM
result_file="$result_dir/review-result"
REVIEW_UNTIL_RESULT_FILE="$result_file" bash "$review_script" "${review_args[@]}" <&0 &
review_pid=$!
wait "$review_pid"
review_pid=""
[[ -f "$result_file" ]] || fail 'Review did not report its repository.'
{
    IFS= read -r -d '' repo || fail 'Invalid review repository result.'
    if IFS= read -r -d '' extra || [[ -n "$extra" ]]; then
        fail 'Invalid review repository result.'
    fi
} < "$result_file"
[[ "$repo" == /* ]] || fail 'Review repository must be an absolute path.'
resolved_repo=$(git -C "$repo" rev-parse --show-toplevel) || fail 'Review repository is not a working-tree Git repository.'
[[ "$resolved_repo" == "$repo" ]] || fail 'Review repository must be the repository root.'
rm -rf -- "$result_dir"
trap - EXIT INT TERM
exec bash "$script_dir/commit_by_codex.sh" --repo "$repo" "${commit_args[@]}" -y
