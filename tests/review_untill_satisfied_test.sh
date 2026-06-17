#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/review_untill_satisfied.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

test_repo="${tmp_dir}/repo"
mkdir -p "${tmp_dir}/bin" "${test_repo}"
git -C "${test_repo}" init -q
git -C "${test_repo}" config user.email test@example.com
git -C "${test_repo}" config user.name "Test User"
touch "${test_repo}/README.md"
git -C "${test_repo}" add README.md
git -C "${test_repo}" commit -qm "initial"

export FAKE_CODEX_STATE="${tmp_dir}/codex-state"
export FAKE_CODEX_FIX_PROMPT="${tmp_dir}/fix-prompt"
export FAKE_CODEX_ARGS_LOG="${tmp_dir}/codex-args.log"

cat >"${tmp_dir}/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'OpenAI Codex fake session prose on stdout\n'
printf 'fake codex stderr diagnostics\n' >&2
printf '%s\n' "$*" >>"${FAKE_CODEX_ARGS_LOG}"

if [[ "${1:-}" != "exec" ]]; then
  echo "expected codex exec, got: $*" >&2
  exit 2
fi
shift

for arg in "$@"; do
  case "${arg}" in
    review|--uncommitted)
      echo "review must use ordinary codex exec with output-last-message, got: $*" >&2
      exit 2
      ;;
  esac
done

output_last_message=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      output_last_message="${2:-}"
      shift 2
      ;;
    --output-schema|--sandbox)
      shift 2
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done

count=0
if [[ -f "${FAKE_CODEX_STATE}" ]]; then
  count="$(cat "${FAKE_CODEX_STATE}")"
fi
count=$((count + 1))
printf '%s' "${count}" >"${FAKE_CODEX_STATE}"

if [[ "${count}" -eq 1 || "${count}" -eq 3 ]]; then
  if [[ -z "${output_last_message}" ]]; then
    echo "missing --output-last-message for review" >&2
    exit 2
  fi

  if [[ "${count}" -eq 1 ]]; then
    printf '{"satisfied":false,"summary":"needs one fix","findings":[{"issue":"demo"}]}\n' >"${output_last_message}"
  else
    printf '{"satisfied":true,"summary":"clean","findings":[]}\n' >"${output_last_message}"
  fi
else
  printf '%s\n' "${prompt:-}" >"${FAKE_CODEX_FIX_PROMPT}"
fi
EOF
chmod +x "${tmp_dir}/bin/codex"
export PATH="${tmp_dir}/bin:${PATH}"

log_dir="${tmp_dir}/logs"
output="$("${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${log_dir}")"

if [[ "${output}" != *"Review passed on loop 2"* ]]; then
  printf 'Expected review loop to pass on second review. Output:\n%s\n' "${output}" >&2
  exit 1
fi

log_file="$(find "${log_dir}" -type f -name '*.log' -print -quit)"
if [[ -z "${log_file}" ]]; then
  echo "Expected a review log file" >&2
  exit 1
fi

if ! grep -Fq -- "OpenAI Codex fake session prose on stdout" "${log_file}"; then
  printf 'Expected CLI stdout prose in log. Log:\n' >&2
  cat "${log_file}" >&2
  exit 1
fi

if ! grep -Fq -- '"satisfied":false' "${FAKE_CODEX_FIX_PROMPT}"; then
  printf 'Expected fix prompt to receive structured review JSON. Prompt:\n' >&2
  cat "${FAKE_CODEX_FIX_PROMPT}" >&2
  exit 1
fi

if ! grep -Fq -- "--output-last-message" "${FAKE_CODEX_ARGS_LOG}"; then
  printf 'Expected review command to use --output-last-message. Args:\n' >&2
  cat "${FAKE_CODEX_ARGS_LOG}" >&2
  exit 1
fi
