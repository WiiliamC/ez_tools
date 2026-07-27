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
output_schema=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      output_last_message="${2:-}"
      shift 2
      ;;
    --output-schema)
      output_schema="${2:-}"
      shift 2
      ;;
    --sandbox)
      shift 2
      ;;
    *)
      prompt="$1"
      shift
      ;;
  esac
done

if [[ -n "${output_schema}" ]]; then
  python3 - "${output_schema}" <<'PY'
import json
import sys
from pathlib import Path

schema = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
items = schema["properties"]["findings"]["items"]
assert items == {
    "type": "object",
    "additionalProperties": False,
    "properties": {"issue": {"type": "string"}},
    "required": ["issue"],
}
PY
fi

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

  if [[ -n "${FAKE_CODEX_REVIEW_RESPONSE:-}" ]]; then
    printf '%s\n' "${FAKE_CODEX_REVIEW_RESPONSE}" >"${output_last_message}"
  elif [[ "${count}" -eq 1 ]]; then
    printf '{"satisfied":false,"summary":"needs one fix","findings":[{"issue":"demo"}]}\n' >"${output_last_message}"
  else
    printf '{"satisfied":true,"summary":"clean","findings":[]}\n' >"${output_last_message}"
  fi
else
  if [[ "${FAKE_CODEX_DELETE_REVIEW_DIR_ON_FIX:-}" == "1" ]]; then
    rm -rf -- .review_untill_satisfied
  fi
  printf '%s\n' "${prompt:-}" >"${FAKE_CODEX_FIX_PROMPT}"
fi
EOF
chmod +x "${tmp_dir}/bin/codex"

cat >"${tmp_dir}/bin/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  +%Y%m%d_%H%M%S)
    printf '20260727_120000\n'
    ;;
  '+Started: %Y-%m-%d %H:%M:%S')
    printf 'Started: 2026-07-27 12:00:00\n'
    ;;
  *)
    exec /usr/bin/date "$@"
    ;;
esac
EOF
chmod +x "${tmp_dir}/bin/date"

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

default_state_dir="${tmp_dir}/state"
mkdir -p "${test_repo}/.review_untill_satisfied/logs"
printf 'active log\n' >"${test_repo}/.review_untill_satisfied/logs/active.log"
rm -f "${FAKE_CODEX_STATE}"
export FAKE_CODEX_DELETE_REVIEW_DIR_ON_FIX=1
default_output="$(XDG_STATE_HOME="${default_state_dir}" "${script}" --repo "${test_repo}" --max-loops 2)"
unset FAKE_CODEX_DELETE_REVIEW_DIR_ON_FIX

if [[ "${default_output}" != *"Review passed on loop 2"* ]]; then
  printf 'Expected default-path review loop to pass after target log deletion. Output:\n%s\n' \
    "${default_output}" >&2
  exit 1
fi

if [[ -e "${test_repo}/.review_untill_satisfied" ]]; then
  echo "Expected fake fix to delete the target repository's review directory" >&2
  exit 1
fi

default_log_dir="${default_state_dir}/review_untill_satisfied/$(basename "${test_repo}")/logs"
default_log_file="$(find "${default_log_dir}" -type f -name '*.log' -print -quit)"
if [[ -z "${default_log_file}" ]]; then
  echo "Expected the default log outside the target repository" >&2
  exit 1
fi

if [[ "$(stat -c '%a' "${default_log_dir}")" != "700" ]]; then
  echo "Expected default log directory mode 700" >&2
  exit 1
fi

if [[ "$(stat -c '%a' "${default_log_file}")" != "600" ]]; then
  echo "Expected default log file mode 600" >&2
  exit 1
fi

assert_log_dir_rejected() {
  local name="$1"
  local rejected_log_dir="$2"
  local case_output
  local case_status

  rm -f "${FAKE_CODEX_STATE}"
  set +e
  case_output="$("${script}" --repo "${test_repo}" --max-loops 1 \
    --log-dir "${rejected_log_dir}" 2>&1)"
  case_status=$?
  set -e

  if [[ "${case_status}" -ne 2 ]]; then
    printf 'Expected %s log directory to exit 2, got %s. Output:\n%s\n' \
      "${name}" "${case_status}" "${case_output}" >&2
    exit 1
  fi

  if [[ "${case_output}" != *"Log directory must be outside the target repository"* ]]; then
    printf 'Expected repository-boundary diagnostic for %s. Output:\n%s\n' \
      "${name}" "${case_output}" >&2
    exit 1
  fi

  if [[ -e "${FAKE_CODEX_STATE}" ]]; then
    printf 'Expected %s validation to fail before invoking Codex\n' "${name}" >&2
    exit 1
  fi
}

assert_log_dir_rejected "repository root" "${test_repo}"
assert_log_dir_rejected "repository child" "${test_repo}/new-logs"

ln -s "${test_repo}/linked-logs" "${tmp_dir}/log-dir-symlink"
assert_log_dir_rejected "symlink into repository" "${tmp_dir}/log-dir-symlink"

assert_state_root_rejected() {
  local name="$1"
  local expected_diagnostic="$2"
  shift 2
  local case_output
  local case_status

  rm -f "${FAKE_CODEX_STATE}"
  set +e
  case_output="$(env "$@" "${script}" --repo "${test_repo}" --max-loops 1 2>&1)"
  case_status=$?
  set -e

  if [[ "${case_status}" -ne 2 || "${case_output}" != *"${expected_diagnostic}"* ]]; then
    printf 'Expected invalid %s state root to exit 2. Output:\n%s\n' \
      "${name}" "${case_output}" >&2
    exit 1
  fi

  if [[ -e "${FAKE_CODEX_STATE}" ]]; then
    printf 'Expected %s validation to fail before invoking Codex\n' "${name}" >&2
    exit 1
  fi
}

assert_state_root_rejected \
  "relative XDG_STATE_HOME" \
  "XDG_STATE_HOME must be an absolute path" \
  XDG_STATE_HOME=relative-state
assert_state_root_rejected \
  "missing HOME" \
  "HOME must be an absolute path" \
  -u XDG_STATE_HOME -u HOME
assert_state_root_rejected \
  "relative HOME" \
  "HOME must be an absolute path" \
  -u XDG_STATE_HOME HOME=relative-home

unique_state_dir="${tmp_dir}/unique-state"
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"clean","findings":[]}'
for _ in 1 2; do
  rm -f "${FAKE_CODEX_STATE}"
  XDG_STATE_HOME="${unique_state_dir}" \
    "${script}" --repo "${test_repo}" --max-loops 1 >/dev/null
done
unset FAKE_CODEX_REVIEW_RESPONSE

unique_log_dir="${unique_state_dir}/review_untill_satisfied/$(basename "${test_repo}")/logs"
if [[ "$(find "${unique_log_dir}" -type f -name '*.log' | wc -l)" -ne 2 ]]; then
  echo "Expected same-second runs to create distinct log files" >&2
  exit 1
fi

assert_invalid_review_fails() {
  local name="$1"
  local response="$2"
  local expected_diagnostic="$3"
  local case_log_dir="${tmp_dir}/logs-${name}"
  local case_output
  local case_status

  rm -f "${FAKE_CODEX_STATE}"
  export FAKE_CODEX_REVIEW_RESPONSE="${response}"

  set +e
  case_output="$("${script}" --repo "${test_repo}" --max-loops 1 --log-dir "${case_log_dir}" 2>&1)"
  case_status=$?
  set -e

  if [[ "${case_status}" -ne 2 ]]; then
    printf 'Expected inconsistent %s review to exit 2, got %s. Output:\n%s\n' \
      "${name}" "${case_status}" "${case_output}" >&2
    exit 1
  fi

  local case_log
  case_log="$(find "${case_log_dir}" -type f -name '*.log' -print -quit)"
  if ! grep -Fq -- "${expected_diagnostic}" "${case_log}"; then
    printf 'Expected invalid %s review diagnostic. Log:\n' "${name}" >&2
    cat "${case_log}" >&2
    exit 1
  fi
}

assert_invalid_review_fails \
  "false-empty" \
  '{"satisfied":false,"summary":"contradictory","findings":[]}' \
  "satisfied must be true exactly when findings is empty"
assert_invalid_review_fails \
  "true-nonempty" \
  '{"satisfied":true,"summary":"contradictory","findings":[{"issue":"demo"}]}' \
  "satisfied must be true exactly when findings is empty"
assert_invalid_review_fails \
  "extra-top-level-property" \
  '{"satisfied":true,"summary":"clean","findings":[],"extra":"unexpected"}' \
  "top-level object must contain exactly satisfied, summary, and findings"
