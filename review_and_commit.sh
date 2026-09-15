#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

usage() {
    cat <<'HELP'
Usage: review_and_commit.sh [OPTIONS]

Run review/fix cycles, then automatically commit only if review succeeds.

  --repo PATH       Repository to review and commit. Default: current directory.
  --max-loops N     Maximum review/fix loops. Default: 12.
  --log-dir PATH    Review log directory outside the target repository.
  --fast            Use the Fast service tier for review/fix steps.
  --model MODEL     Commit-message model. Default: gpt-5.6-luna.
  -h, --help        Show this help message.

The commit step always uses -y to skip confirmation. Git hooks and signing
retain their normal behavior. Resume options are not supported by this wrapper.
HELP
}

fail() { printf 'Error: %s\n' "$*" >&2; exit 2; }
repo=.
review_args=()
commit_args=()
while (($#)); do
    case "$1" in
        --repo|--max-loops|--log-dir|--model)
            (($# >= 2)) && [[ -n "$2" && "$2" != -* ]] || fail "$1 requires a value"
            case "$1" in
                --repo) repo=$2 ;;
                --model) commit_args+=("$1" "$2") ;;
                *) review_args+=("$1" "$2") ;;
            esac
            shift 2 ;;
        --fast) review_args+=("$1"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

# Resolve once so both subprocesses receive the same repository root.
repo=$(git -C "$repo" rev-parse --show-toplevel) || fail 'Not a working-tree Git repository.'
bash "$script_dir/review_untill_satisfied.sh" --repo "$repo" "${review_args[@]}"
exec bash "$script_dir/commit_by_codex.sh" --repo "$repo" "${commit_args[@]}" -y
