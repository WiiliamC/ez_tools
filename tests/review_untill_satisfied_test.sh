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
export FAKE_CODEX_UMASK_LOG="${tmp_dir}/codex-umask.log"
export FAKE_CODEX_FD9_LOG="${tmp_dir}/codex-fd9.log"

cat >"${tmp_dir}/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'fake codex stderr diagnostics\n' >&2
printf '%s\n' "$*" >>"${FAKE_CODEX_ARGS_LOG}"
umask >>"${FAKE_CODEX_UMASK_LOG}"
if [[ -e "/proc/$$/fd/9" ]]; then
  printf 'open\n' >>"${FAKE_CODEX_FD9_LOG}"
else
  printf 'closed\n' >>"${FAKE_CODEX_FD9_LOG}"
fi

if [[ "${1:-}" != "exec" ]]; then
  echo "expected codex exec, got: $*" >&2
  exit 2
fi
shift

resume_session=""
if [[ "${1:-}" == "resume" ]]; then
  resume_session="${2:-}"
  shift 2
fi

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
    -c|--config)
      shift 2
      ;;
    --json)
      shift
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

session_id="${resume_session:-session-${count}}"
printf '{"type":"thread.started","thread_id":"%s"}\n' "${session_id}"
printf '{"type":"item.completed","item":{"type":"agent_message","text":"OpenAI Codex fake session prose on stdout"}}\n'

if [[ "${FAKE_CODEX_FAIL_RESUME:-}" == "1" && -n "${resume_session}" ]] ||
  [[ "${FAKE_CODEX_FAIL_ON_CALL:-}" == "${count}" ]]; then
  if [[ "${FAKE_CODEX_HIDE_GIT_ON_FAIL:-}" == "1" ]]; then
    mv .git .git.hidden
  fi
  exit "${FAKE_CODEX_FAIL_STATUS:-7}"
fi

if [[ -n "${output_last_message}" ]]; then
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

help_output="$("${script}" --help)"
if [[ "${help_output}" != *"--fast"* || "${help_output}" != *"Default: disabled"* ]] ||
  [[ "${help_output}" != *"--resume [LOG]"* ]] ||
  [[ "${help_output}" != *"--allow-worktree-changes"* ]]; then
  printf 'Expected help to document fresh and resume options. Output:\n%s\n' \
    "${help_output}" >&2
  exit 1
fi

set +e
unknown_output="$("${script}" --unknown 2>&1)"
unknown_status=$?
set -e
if [[ "${unknown_status}" -ne 2 || "${unknown_output}" != *"Unknown argument: --unknown"* ]]; then
  printf 'Expected unknown argument to exit 2. Output:\n%s\n' "${unknown_output}" >&2
  exit 1
fi

log_dir="${tmp_dir}/logs"
output="$(TERMINAL_TAB_SPINNER_FORCE=1 \
  "${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${log_dir}")"

if [[ "${output}" != *"Review passed on loop 2"* ]]; then
  printf 'Expected review loop to pass on second review. Output:\n%s\n' "${output}" >&2
  exit 1
fi

if [[ "${output}" != *"Review feedback 1/2:"* ]] ||
  [[ "${output}" != *"Status: changes requested"* ]] ||
  [[ "${output}" != *"needs one fix"* ]] ||
  [[ "${output}" != *"1. demo"* ]]; then
  printf 'Expected friendly first-loop review feedback. Output:\n%s\n' "${output}" >&2
  exit 1
fi

if [[ "${output}" != *"Modification prompt 1/2:"* ]] ||
  [[ "${output}" != *"Use the following structured review JSON as context."* ]] ||
  [[ "${output}" != *'"satisfied":false'* ]]; then
  printf 'Expected the complete first-loop modification prompt. Output:\n%s\n' "${output}" >&2
  exit 1
fi

if [[ "${output}" != *"Review feedback 2/2:"* ]] ||
  [[ "${output}" != *"Status: satisfied"* ]] ||
  [[ "${output}" != *"clean"* ]] ||
  [[ "${output}" != *"Findings:"* ]] ||
  [[ "${output}" != *"None"* ]]; then
  printf 'Expected friendly passing review feedback. Output:\n%s\n' "${output}" >&2
  exit 1
fi

if [[ "${output}" == *"Modification prompt 2/2:"* ]]; then
  printf 'Did not expect a modification prompt after the passing review. Output:\n%s\n' \
    "${output}" >&2
  exit 1
fi

if [[ "${output}" != *"Reviewing 1/2"* || "${output}" != *"Fixing 1/2"* ]]; then
  printf 'Expected review and fix spinner titles. Output:\n%q\n' "${output}" >&2
  exit 1
fi

expected_final_title="$(printf '\033]0;! %s\007' "$(basename "${test_repo}")")"
if [[ "${output}" != *"${expected_final_title}" ]]; then
  printf 'Expected final attention title. Output:\n%q\n' "${output}" >&2
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

printed_fix_prompt="${output#*Modification prompt 1/2:}"
printed_fix_prompt="${printed_fix_prompt%%Fixing 1/2*}"
if [[ "${printed_fix_prompt}" != *"$(cat "${FAKE_CODEX_FIX_PROMPT}")"* ]]; then
  printf 'Expected the printed prompt to match the prompt sent to Codex. Output:\n%s\n' \
    "${output}" >&2
  exit 1
fi

if ! grep -Fq -- "--output-last-message" "${FAKE_CODEX_ARGS_LOG}"; then
  printf 'Expected review command to use --output-last-message. Args:\n' >&2
  cat "${FAKE_CODEX_ARGS_LOG}" >&2
  exit 1
fi

default_invocation_count="$(grep -c '^exec ' "${FAKE_CODEX_ARGS_LOG}")"
default_tier_count="$(grep -c '^exec -c service_tier="default" ' "${FAKE_CODEX_ARGS_LOG}")"
if [[ "${default_tier_count}" -ne "${default_invocation_count}" ]]; then
  printf 'Expected every default Codex invocation to disable Fast. Args:\n' >&2
  cat "${FAKE_CODEX_ARGS_LOG}" >&2
  exit 1
fi

# Private sidecars keep restrictive modes, while Codex inherits the caller's
# normal umask and cannot pass the run lock to descendants.
rm -f "${FAKE_CODEX_STATE}" "${FAKE_CODEX_UMASK_LOG}" "${FAKE_CODEX_FD9_LOG}"
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"clean","findings":[]}'
permission_log_dir="${tmp_dir}/permission-logs"
(
  umask 027
  "${script}" --repo "${test_repo}" --max-loops 1 \
    --log-dir "${permission_log_dir}" >/dev/null
)
unset FAKE_CODEX_REVIEW_RESPONSE
permission_log="$(find "${permission_log_dir}" -type f -name '*.log' -print -quit)"
if [[ "$(cat "${FAKE_CODEX_UMASK_LOG}")" != "0027" ]]; then
  printf 'Expected Codex to inherit caller umask 0027, got:\n' >&2
  cat "${FAKE_CODEX_UMASK_LOG}" >&2
  exit 1
fi
if grep -Fq open "${FAKE_CODEX_FD9_LOG}" ||
  [[ "$(cat "${FAKE_CODEX_FD9_LOG}")" != "closed" ]]; then
  printf 'Expected Codex to run with lock fd 9 closed, got:\n' >&2
  cat "${FAKE_CODEX_FD9_LOG}" >&2
  exit 1
fi
for private_file in \
  "${permission_log}" \
  "${permission_log}.state.json" \
  "${permission_log}.events.jsonl" \
  "${permission_log}.lock"; do
  if [[ "$(stat -c '%a' "${private_file}")" != "600" ]]; then
    printf 'Expected private mode 600 for %s\n' "${private_file}" >&2
    exit 1
  fi
done

rm -f "${FAKE_CODEX_STATE}"
: >"${FAKE_CODEX_ARGS_LOG}"
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"clean","findings":[]}'
"${script}" --repo "${test_repo}" --max-loops 1 --log-dir "${tmp_dir}/fast-logs" \
  --fast >/dev/null
unset FAKE_CODEX_REVIEW_RESPONSE

if [[ "$(grep -c '^exec ' "${FAKE_CODEX_ARGS_LOG}")" -ne 1 ]] ||
  ! grep -q -- '^exec -c service_tier="fast" ' "${FAKE_CODEX_ARGS_LOG}"; then
  printf 'Expected --fast to select Fast for the Codex invocation. Args:\n' >&2
  cat "${FAKE_CODEX_ARGS_LOG}" >&2
  exit 1
fi

rm -f "${FAKE_CODEX_STATE}"
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":false,"summary":"still blocked","findings":[{"issue":"remaining issue"}]}'
set +e
max_loop_output="$("${script}" --repo "${test_repo}" --max-loops 1 \
  --log-dir "${tmp_dir}/max-loop-logs" 2>&1)"
max_loop_status=$?
set -e
unset FAKE_CODEX_REVIEW_RESPONSE

if [[ "${max_loop_status}" -ne 1 ]] ||
  [[ "${max_loop_output}" != *"Review feedback 1/1:"* ]] ||
  [[ "${max_loop_output}" != *"still blocked"* ]] ||
  [[ "${max_loop_output}" != *"1. remaining issue"* ]]; then
  printf 'Expected final unsatisfied review feedback at the loop limit. Output:\n%s\n' \
    "${max_loop_output}" >&2
  exit 1
fi

if [[ "${max_loop_output}" == *"Modification prompt 1/1:"* ]]; then
  printf 'Did not expect a modification prompt after the final allowed review. Output:\n%s\n' \
    "${max_loop_output}" >&2
  exit 1
fi

rm -f "${FAKE_CODEX_STATE}"
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":false,"summary":"safe\u001b[2J\nnext\u000dline","findings":[{"issue":"bell\u0007 and c1\u009b"}]}'
set +e
control_output="$("${script}" --repo "${test_repo}" --max-loops 1 \
  --log-dir "${tmp_dir}/control-logs" 2>&1)"
control_status=$?
set -e
unset FAKE_CODEX_REVIEW_RESPONSE

if [[ "${control_status}" -ne 1 ]] ||
  [[ "${control_output}" == *$'\033'* ]] ||
  [[ "${control_output}" == *$'\a'* ]] ||
  [[ "${control_output}" == *$'\r'* ]] ||
  [[ "${control_output}" == *$'\u009b'* ]] ||
  [[ "${control_output}" != *'safe\u001b[2J'* ]] ||
  [[ "${control_output}" != *'next\u000dline'* ]] ||
  [[ "${control_output}" != *'bell\u0007 and c1\u009b'* ]]; then
  printf 'Expected review feedback to visualize terminal control characters. Output:\n%q\n' \
    "${control_output}" >&2
  exit 1
fi

rm -f "${FAKE_CODEX_STATE}" "${FAKE_CODEX_FIX_PROMPT}"
export FAKE_CODEX_REVIEW_RESPONSE=$'{"satisfied":false,"summary":"raw c1 \u009b","findings":[{"issue":"remaining issue"}]}'
set +e
prompt_control_output="$("${script}" --repo "${test_repo}" --max-loops 2 \
  --log-dir "${tmp_dir}/prompt-control-logs" 2>&1)"
prompt_control_status=$?
set -e
unset FAKE_CODEX_REVIEW_RESPONSE

if [[ "${prompt_control_status}" -ne 1 ]] ||
  [[ "${prompt_control_output}" == *$'\u009b'* ]] ||
  [[ "${prompt_control_output}" != *'raw c1 \u009b'* ]]; then
  printf 'Expected the displayed modification prompt to visualize C1 controls. Output:\n%q\n' \
    "${prompt_control_output}" >&2
  exit 1
fi

if [[ "$(cat "${FAKE_CODEX_FIX_PROMPT}")" != *$'raw c1 \u009b'* ]]; then
  printf 'Expected Codex to receive the original C1 control in the modification prompt. Prompt:\n%q\n' \
    "$(cat "${FAKE_CODEX_FIX_PROMPT}")" >&2
  exit 1
fi

rm -f "${FAKE_CODEX_STATE}" "${FAKE_CODEX_FIX_PROMPT}"
export FAKE_CODEX_REVIEW_RESPONSE=$'{"satisfied":false,"summary":"中文摘要","findings":[{"issue":"中文问题和原始 C1 \u009b"}]}'
set +e
ascii_io_output="$(PYTHONIOENCODING=ascii \
  "${script}" --repo "${test_repo}" --max-loops 2 \
  --log-dir "${tmp_dir}/ascii-io-logs" 2>&1)"
ascii_io_status=$?
set -e
unset FAKE_CODEX_REVIEW_RESPONSE

if [[ "${ascii_io_status}" -ne 1 ]] ||
  [[ "${ascii_io_output}" != *"中文摘要"* ]] ||
  [[ "${ascii_io_output}" != *'中文问题和原始 C1 \u009b'* ]] ||
  [[ "${ascii_io_output}" != *"Modification prompt 1/2:"* ]] ||
  [[ "${ascii_io_output}" == *"UnicodeEncodeError"* ]] ||
  [[ "${ascii_io_output}" == *"UnicodeDecodeError"* ]]; then
  printf 'Expected UTF-8 review rendering with an ASCII inherited Python I/O encoding. Output:\n%q\n' \
    "${ascii_io_output}" >&2
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
  case_output="$(TERMINAL_TAB_SPINNER_FORCE=1 \
    "${script}" --repo "${test_repo}" --max-loops 1 --log-dir "${case_log_dir}" 2>&1)"
  case_status=$?
  set -e

  if [[ "${case_status}" -ne 2 ]]; then
    printf 'Expected inconsistent %s review to exit 2, got %s. Output:\n%s\n' \
      "${name}" "${case_status}" "${case_output}" >&2
    exit 1
  fi

  if [[ "${case_output}" != *"${expected_final_title}" ]]; then
    printf 'Expected final attention title after invalid %s review. Output:\n%q\n' \
      "${name}" "${case_output}" >&2
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

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))[sys.argv[2]])
PY
}

reset_fake_codex() {
  rm -f "${FAKE_CODEX_STATE}" "${FAKE_CODEX_FIX_PROMPT}"
  : >"${FAKE_CODEX_ARGS_LOG}"
  unset FAKE_CODEX_FAIL_ON_CALL FAKE_CODEX_FAIL_RESUME FAKE_CODEX_FAIL_STATUS
  unset FAKE_CODEX_HIDE_GIT_ON_FAIL
  unset FAKE_CODEX_REVIEW_RESPONSE
}

# A failed review resumes its captured thread and appends to the same durable run.
reset_fake_codex
export FAKE_CODEX_FAIL_ON_CALL=1
review_resume_dir="${tmp_dir}/review-resume-logs"
set +e
"${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${review_resume_dir}" >/dev/null 2>&1
review_fail_status=$?
set -e
unset FAKE_CODEX_FAIL_ON_CALL
review_resume_log="$(find "${review_resume_dir}" -name '*.log' -print -quit)"
review_resume_state="${review_resume_log}.state.json"
if [[ "${review_fail_status}" -ne 7 ]] ||
  [[ "$(json_field "${review_resume_state}" phase)" != "review" ]] ||
  [[ "$(json_field "${review_resume_state}" phase_status)" != "failed" ]] ||
  [[ "$(json_field "${review_resume_state}" session_id)" != "session-1" ]]; then
  echo "Expected failed review to preserve a resumable session" >&2
  exit 1
fi
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"resumed clean","findings":[]}'
review_resume_output="$("${script}" --resume "${review_resume_log}")"
unset FAKE_CODEX_REVIEW_RESPONSE
if [[ "${review_resume_output}" != *"Review passed on loop 1"* ]] ||
  ! grep -q '^exec resume session-1 ' "${FAKE_CODEX_ARGS_LOG}" ||
  ! grep -q 'resume session-1 .*sandbox_mode="read-only"' "${FAKE_CODEX_ARGS_LOG}" ||
  [[ "$(json_field "${review_resume_state}" run_status)" != "passed" ]]; then
  printf 'Expected review resume to continue session-1. Output:\n%s\n' "${review_resume_output}" >&2
  exit 1
fi
if ! grep -q '"type":"thread.started"' "${review_resume_log}.events.jsonl" ||
  [[ "$(stat -c '%a' "${review_resume_state}")" != "600" ]] ||
  [[ "$(stat -c '%a' "${review_resume_log}.review.json")" != "600" ]] ||
  [[ "$(stat -c '%a' "${review_resume_log}.events.jsonl")" != "600" ]]; then
  echo "Expected private durable JSON sidecars and raw JSONL events" >&2
  exit 1
fi

# A partially completed Fix is only continued through its known session. A
# failed continuation remains retryable with that same session.
reset_fake_codex
export FAKE_CODEX_FAIL_ON_CALL=2
fix_resume_dir="${tmp_dir}/fix-resume-logs"
set +e
"${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${fix_resume_dir}" >/dev/null 2>&1
fix_fail_status=$?
set -e
unset FAKE_CODEX_FAIL_ON_CALL
fix_resume_log="$(find "${fix_resume_dir}" -name '*.log' -print -quit)"
fix_resume_state="${fix_resume_log}.state.json"
if [[ "${fix_fail_status}" -ne 7 ]] ||
  [[ "$(json_field "${fix_resume_state}" phase)" != "fix" ]] ||
  [[ "$(json_field "${fix_resume_state}" session_id)" != "session-2" ]]; then
  echo "Expected failed Fix to preserve session-2" >&2
  exit 1
fi
export FAKE_CODEX_FAIL_RESUME=1
set +e
"${script}" --resume "${fix_resume_log}" >/dev/null 2>&1
fix_retry_status=$?
set -e
unset FAKE_CODEX_FAIL_RESUME
if [[ "${fix_retry_status}" -ne 7 ]] ||
  [[ "$(json_field "${fix_resume_state}" phase_status)" != "failed" ]] ||
  [[ "$(json_field "${fix_resume_state}" session_id)" != "session-2" ]]; then
  echo "Expected failed known-session resume to remain retryable" >&2
  exit 1
fi
fix_resume_output="$("${script}" --resume "${fix_resume_log}")"
if [[ "${fix_resume_output}" != *"Review passed on loop 2"* ]] ||
  [[ "$(grep -c '^exec resume session-2 ' "${FAKE_CODEX_ARGS_LOG}")" -ne 2 ]] ||
  ! grep -q 'resume session-2 .*sandbox_mode="workspace-write"' "${FAKE_CODEX_ARGS_LOG}"; then
  printf 'Expected Fix retry to use only the stored session. Output:\n%s\n' "${fix_resume_output}" >&2
  exit 1
fi

# Drift is rejected by default and allowed only with the explicit override.
reset_fake_codex
export FAKE_CODEX_FAIL_ON_CALL=1
drift_dir="${tmp_dir}/drift-logs"
set +e
"${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${drift_dir}" >/dev/null 2>&1
set -e
unset FAKE_CODEX_FAIL_ON_CALL
drift_log="$(find "${drift_dir}" -name '*.log' -print -quit)"
printf 'drift\n' >>"${test_repo}/README.md"
set +e
drift_output="$("${script}" --resume "${drift_log}" 2>&1)"
drift_status=$?
set -e
if [[ "${drift_status}" -ne 2 ]] || [[ "${drift_output}" != *"--allow-worktree-changes"* ]]; then
  printf 'Expected worktree drift rejection. Output:\n%s\n' "${drift_output}" >&2
  exit 1
fi
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"accepted drift","findings":[]}'
"${script}" --resume "${drift_log}" --allow-worktree-changes >/dev/null
unset FAKE_CODEX_REVIEW_RESPONSE
git -C "${test_repo}" checkout -q -- README.md

# An unborn repository can create a checkpoint, and later worktree drift is
# still rejected even though HEAD does not resolve yet.
reset_fake_codex
unborn_repo="${tmp_dir}/unborn-repo"
unborn_dir="${tmp_dir}/unborn-logs"
mkdir -p "${unborn_repo}"
git -C "${unborn_repo}" init -q
printf 'first version\n' >"${unborn_repo}/draft.txt"
export FAKE_CODEX_FAIL_ON_CALL=1
set +e
"${script}" --repo "${unborn_repo}" --max-loops 2 --log-dir "${unborn_dir}" >/dev/null 2>&1
unborn_fail_status=$?
set -e
unset FAKE_CODEX_FAIL_ON_CALL
unborn_log="$(find "${unborn_dir}" -name '*.log' -print -quit)"
if [[ "${unborn_fail_status}" -ne 7 ]] || [[ ! -f "${unborn_log}.state.json" ]]; then
  echo "Expected an unborn repository to preserve a resumable checkpoint" >&2
  exit 1
fi
printf 'second version\n' >>"${unborn_repo}/draft.txt"
set +e
unborn_output="$("${script}" --resume "${unborn_log}" 2>&1)"
unborn_status=$?
set -e
if [[ "${unborn_status}" -ne 2 ]] || [[ "${unborn_output}" != *"--allow-worktree-changes"* ]]; then
  printf 'Expected drift in an unborn repository to reject resume. Output:\n%s\n' \
    "${unborn_output}" >&2
  exit 1
fi

# A recursively fingerprinted submodule detects additional edits even when the
# superproject already reports the submodule as dirty at the checkpoint.
reset_fake_codex
submodule_origin="${tmp_dir}/submodule-origin"
submodule_repo="${tmp_dir}/submodule-parent"
submodule_dir="${tmp_dir}/submodule-logs"
mkdir -p "${submodule_origin}" "${submodule_repo}"
git -C "${submodule_origin}" init -q
git -C "${submodule_origin}" config user.email test@example.com
git -C "${submodule_origin}" config user.name "Test User"
printf 'tracked\n' >"${submodule_origin}/tracked.txt"
git -C "${submodule_origin}" add tracked.txt
git -C "${submodule_origin}" commit -qm "initial"
git -C "${submodule_repo}" init -q
git -C "${submodule_repo}" config user.email test@example.com
git -C "${submodule_repo}" config user.name "Test User"
git -C "${submodule_repo}" -c protocol.file.allow=always \
  submodule add -q "${submodule_origin}" modules/child
git -C "${submodule_repo}" commit -qam "add submodule"
printf 'dirty at checkpoint\n' >>"${submodule_repo}/modules/child/tracked.txt"
export FAKE_CODEX_FAIL_ON_CALL=1
set +e
"${script}" --repo "${submodule_repo}" --max-loops 2 --log-dir "${submodule_dir}" >/dev/null 2>&1
submodule_fail_status=$?
set -e
unset FAKE_CODEX_FAIL_ON_CALL
submodule_log="$(find "${submodule_dir}" -name '*.log' -print -quit)"
if [[ "${submodule_fail_status}" -ne 7 ]] || [[ ! -f "${submodule_log}.state.json" ]]; then
  echo "Expected a dirty submodule to preserve a resumable checkpoint" >&2
  exit 1
fi
printf 'additional drift\n' >>"${submodule_repo}/modules/child/tracked.txt"
set +e
submodule_output="$("${script}" --resume "${submodule_log}" 2>&1)"
submodule_status=$?
set -e
if [[ "${submodule_status}" -ne 2 ]] ||
  [[ "${submodule_output}" != *"--allow-worktree-changes"* ]]; then
  printf 'Expected additional submodule drift to reject resume. Output:\n%s\n' \
    "${submodule_output}" >&2
  exit 1
fi

# An exhausted run requires a larger total, then continues from its completed review.
reset_fake_codex
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":false,"summary":"extend me","findings":[{"issue":"more work"}]}'
extension_dir="${tmp_dir}/extension-logs"
set +e
"${script}" --repo "${test_repo}" --max-loops 1 --log-dir "${extension_dir}" >/dev/null 2>&1
set -e
unset FAKE_CODEX_REVIEW_RESPONSE
extension_log="$(find "${extension_dir}" -name '*.log' -print -quit)"
set +e
extension_error="$("${script}" --resume "${extension_log}" 2>&1)"
extension_status=$?
lower_error="$("${script}" --resume "${extension_log}" --max-loops 0 2>&1)"
lower_status=$?
set -e
if [[ "${extension_status}" -ne 2 || "${extension_error}" != *"larger --max-loops"* ]] ||
  [[ "${lower_status}" -ne 2 ]]; then
  echo "Expected exhausted and invalid loop totals to be rejected" >&2
  exit 1
fi
extension_output="$("${script}" --resume "${extension_log}" --max-loops 2)"
if [[ "${extension_output}" != *"Review passed on loop 2"* ]] ||
  [[ "$(json_field "${extension_log}.state.json" max_loops)" != "2" ]]; then
  printf 'Expected exhausted run extension. Output:\n%s\n' "${extension_output}" >&2
  exit 1
fi

# Bare --resume selects the newest incomplete run in the selected repository/log directory.
reset_fake_codex
latest_dir="${tmp_dir}/latest-logs"
export FAKE_CODEX_FAIL_ON_CALL=1
for _ in 1 2; do
  rm -f "${FAKE_CODEX_STATE}"
  set +e
  "${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${latest_dir}" >/dev/null 2>&1
  set -e
done
unset FAKE_CODEX_FAIL_ON_CALL
latest_log="$(python3 - "${latest_dir}" <<'PY'
from pathlib import Path
import json
import sys
states = list(Path(sys.argv[1]).glob("*.log.state.json"))
state = max(states, key=lambda p: (json.loads(p.read_text())["updated_at"], p.stat().st_mtime_ns))
print(str(state)[:-len(".state.json")])
PY
)"
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"newest","findings":[]}'
latest_output="$("${script}" --repo "${test_repo}" --log-dir "${latest_dir}" --resume)"
unset FAKE_CODEX_REVIEW_RESPONSE
if [[ "${latest_output}" != *"Resuming review/fix log: ${latest_log}"* ]]; then
  printf 'Expected bare resume to select newest run. Output:\n%s\n' "${latest_output}" >&2
  exit 1
fi

# Bare resume skips parseable sidecars whose typed fields are malformed.
reset_fake_codex
corrupt_dir="${tmp_dir}/corrupt-state-logs"
export FAKE_CODEX_FAIL_ON_CALL=1
set +e
"${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${corrupt_dir}" >/dev/null 2>&1
set -e
unset FAKE_CODEX_FAIL_ON_CALL
corrupt_valid_log="$(find "${corrupt_dir}" -name '*.log' -print -quit)"
python3 - "${corrupt_valid_log}.state.json" <<'PY'
import json
import sys
from pathlib import Path

source = Path(sys.argv[1])
state = json.loads(source.read_text(encoding="utf-8"))

bad_max_loops = dict(state)
bad_max_loops["run_status"] = "exhausted"
bad_max_loops["max_loops"] = "2"
bad_max_loops["updated_at"] = "9999-12-31T23:59:59+00:00"
source.with_name("bad-max-loops.log.state.json").write_text(
    json.dumps(bad_max_loops) + "\n", encoding="utf-8"
)

bad_updated_at = dict(state)
bad_updated_at["updated_at"] = 9999999999
source.with_name("bad-updated-at.log.state.json").write_text(
    json.dumps(bad_updated_at) + "\n", encoding="utf-8"
)
PY
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"valid resumed","findings":[]}'
corrupt_output="$("${script}" --repo "${test_repo}" --log-dir "${corrupt_dir}" \
  --resume --max-loops 3)"
unset FAKE_CODEX_REVIEW_RESPONSE
if [[ "${corrupt_output}" != *"Resuming review/fix log: ${corrupt_valid_log}"* ]]; then
  printf 'Expected bare resume to skip malformed state entries. Output:\n%s\n' \
    "${corrupt_output}" >&2
  exit 1
fi

# Bare resume ignores a newer exhausted run unless its loop limit is explicitly extended.
mixed_latest_dir="${tmp_dir}/mixed-latest-logs"
reset_fake_codex
export FAKE_CODEX_FAIL_ON_CALL=1
set +e
"${script}" --repo "${test_repo}" --max-loops 2 --log-dir "${mixed_latest_dir}" >/dev/null 2>&1
set -e
unset FAKE_CODEX_FAIL_ON_CALL
mixed_interrupted_log="$(find "${mixed_latest_dir}" -name '*.log' -print -quit)"
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":false,"summary":"exhausted","findings":[{"issue":"later"}]}'
set +e
"${script}" --repo "${test_repo}" --max-loops 1 --log-dir "${mixed_latest_dir}" >/dev/null 2>&1
set -e
unset FAKE_CODEX_REVIEW_RESPONSE
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"older resumed","findings":[]}'
mixed_latest_output="$("${script}" --repo "${test_repo}" --log-dir "${mixed_latest_dir}" --resume)"
unset FAKE_CODEX_REVIEW_RESPONSE
if [[ "${mixed_latest_output}" != *"Resuming review/fix log: ${mixed_interrupted_log}"* ]]; then
  printf 'Expected bare resume to ignore an unextended exhausted run. Output:\n%s\n' \
    "${mixed_latest_output}" >&2
  exit 1
fi

remaining_latest_state="$(python3 - "${latest_dir}" <<'PY'
from pathlib import Path
import json
import sys
for path in Path(sys.argv[1]).glob("*.log.state.json"):
    if json.loads(path.read_text())["run_status"] != "passed":
        print(path)
        break
PY
)"
remaining_latest_log="${remaining_latest_state%.state.json}"
assert_lower_output=""
set +e
assert_lower_output="$("${script}" --resume "${remaining_latest_log}" --max-loops 1 2>&1)"
assert_lower_status=$?
set -e
if [[ "${assert_lower_status}" -ne 2 ]] ||
  [[ "${assert_lower_output}" != *"cannot be lower than the stored total"* ]]; then
  printf 'Expected a lower resume loop total to be rejected. Output:\n%s\n' \
    "${assert_lower_output}" >&2
  exit 1
fi

# A stale running checkpoint is not trusted even when the bytes still match.
python3 - "${remaining_latest_state}" <<'PY'
import json
import os
import sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text())
state["phase_status"] = "running"
state["run_status"] = "running"
state["fingerprint_trustworthy"] = False
temporary = path.with_suffix(path.suffix + ".test-tmp")
temporary.write_text(json.dumps(state) + "\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
set +e
stale_output="$("${script}" --resume "${remaining_latest_log}" 2>&1)"
stale_status=$?
set -e
if [[ "${stale_status}" -ne 2 ]] || [[ "${stale_output}" != *"trustworthy saved checkpoint"* ]]; then
  printf 'Expected stale running state to require an override. Output:\n%s\n' "${stale_output}" >&2
  exit 1
fi
export FAKE_CODEX_REVIEW_RESPONSE='{"satisfied":true,"summary":"stale resumed","findings":[]}'
"${script}" --resume "${remaining_latest_log}" --allow-worktree-changes >/dev/null
unset FAKE_CODEX_REVIEW_RESPONSE

# Cleanup keeps the saved checkpoint untrusted if its post-invocation
# fingerprint cannot be computed.
reset_fake_codex
fingerprint_failure_repo="${tmp_dir}/fingerprint-failure-repo"
fingerprint_failure_dir="${tmp_dir}/fingerprint-failure-logs"
mkdir -p "${fingerprint_failure_repo}"
git -C "${fingerprint_failure_repo}" init -q
git -C "${fingerprint_failure_repo}" config user.email test@example.com
git -C "${fingerprint_failure_repo}" config user.name "Test User"
touch "${fingerprint_failure_repo}/README.md"
git -C "${fingerprint_failure_repo}" add README.md
git -C "${fingerprint_failure_repo}" commit -qm "initial"
export FAKE_CODEX_FAIL_ON_CALL=1
export FAKE_CODEX_HIDE_GIT_ON_FAIL=1
set +e
"${script}" --repo "${fingerprint_failure_repo}" --max-loops 2 \
  --log-dir "${fingerprint_failure_dir}" >/dev/null 2>&1
fingerprint_failure_status=$?
set -e
unset FAKE_CODEX_FAIL_ON_CALL FAKE_CODEX_HIDE_GIT_ON_FAIL
mv "${fingerprint_failure_repo}/.git.hidden" "${fingerprint_failure_repo}/.git"
fingerprint_failure_log="$(find "${fingerprint_failure_dir}" -name '*.log' -print -quit)"
if [[ "${fingerprint_failure_status}" -eq 0 ]] ||
  [[ "$(json_field "${fingerprint_failure_log}.state.json" fingerprint_trustworthy)" != "False" ]]; then
  echo "Expected failed cleanup fingerprinting to preserve an untrusted checkpoint" >&2
  exit 1
fi

# Explicit option, legacy/schema, passed-run, and lock diagnostics fail before Codex.
legacy_log="${tmp_dir}/legacy.log"
printf 'old log\n' >"${legacy_log}"
bad_log="${tmp_dir}/bad.log"
printf 'bad state\n' >"${bad_log}"
printf '{"schema_version":99}\n' >"${bad_log}.state.json"
assert_resume_error() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$("${script}" "$@" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -ne 2 || "${output}" != *"${expected}"* ]]; then
    printf 'Expected resume error containing %s. Output:\n%s\n' "${expected}" "${output}" >&2
    exit 1
  fi
}
assert_resume_error "legacy logs are unsupported" --resume "${legacy_log}"
assert_resume_error "Unsupported resume state schema" --resume "${bad_log}"
assert_resume_error "--fast is invalid" --resume "${review_resume_log}" --fast
assert_resume_error "--log-dir cannot" --resume "${review_resume_log}" --log-dir "${tmp_dir}/unused"
assert_resume_error "--repo does not match" --resume "${review_resume_log}" --repo "${repo_root}"
assert_resume_error "Passed runs are not resumable" --resume "${review_resume_log}"

exec 8>"${fix_resume_log}.lock"
flock -n 8
assert_resume_error "already active" --resume "${fix_resume_log}"
flock -u 8
