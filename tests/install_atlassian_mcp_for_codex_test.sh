#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/install_atlassian_mcp_for_codex.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'Expected output to contain: %s\nActual output:\n%s\n' "${needle}" "${haystack}" >&2
    exit 1
  fi
}

assert_log_equals() {
  local expected="$1"
  local actual
  actual="$(cat "${FAKE_CODEX_LOG}")"

  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Unexpected Codex calls.\nExpected:\n%s\nActual:\n%s\n' "${expected}" "${actual}" >&2
    exit 1
  fi
}

mkdir -p "${tmp_dir}/bin"
export FAKE_CODEX_LOG="${tmp_dir}/codex.log"
export FAKE_CODEX_GET_STATUS=1
export FAKE_CODEX_ADD_STATUS=0
export FAKE_CODEX_LOGIN_STATUS=0

cat >"${tmp_dir}/bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${FAKE_CODEX_LOG}"

case "$*" in
  "mcp get atlassian")
    exit "${FAKE_CODEX_GET_STATUS:-1}"
    ;;
  "mcp add atlassian --url https://mcp.atlassian.com/v1/mcp/authv2")
    exit "${FAKE_CODEX_ADD_STATUS:-0}"
    ;;
  "mcp login atlassian")
    exit "${FAKE_CODEX_LOGIN_STATUS:-0}"
    ;;
  *)
    printf 'unexpected fake codex arguments: %s\n' "$*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "${tmp_dir}/bin/codex"

original_path="${PATH}"
export PATH="${tmp_dir}/bin:${PATH}"

: >"${FAKE_CODEX_LOG}"
output="$("${script}")"
assert_contains "${output}" "configured and authenticated successfully"
assert_log_equals $'mcp get atlassian\nmcp add atlassian --url https://mcp.atlassian.com/v1/mcp/authv2\nmcp login atlassian'

: >"${FAKE_CODEX_LOG}"
FAKE_CODEX_GET_STATUS=0
set +e
output="$("${script}" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected an existing Atlassian MCP configuration to fail the script" >&2
  exit 1
fi
assert_contains "${output}" "an MCP configuration named 'atlassian' already exists"
assert_contains "${output}" "remove it explicitly before retrying"
assert_log_equals "mcp get atlassian"

: >"${FAKE_CODEX_LOG}"
FAKE_CODEX_GET_STATUS=1
FAKE_CODEX_ADD_STATUS=1
set +e
output="$("${script}" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected add failure to fail the script" >&2
  exit 1
fi
assert_contains "${output}" "could not add 'atlassian'"
assert_log_equals $'mcp get atlassian\nmcp add atlassian --url https://mcp.atlassian.com/v1/mcp/authv2'

: >"${FAKE_CODEX_LOG}"
FAKE_CODEX_ADD_STATUS=0
FAKE_CODEX_LOGIN_STATUS=1
set +e
output="$("${script}" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected login failure to fail the script" >&2
  exit 1
fi
assert_contains "${output}" "MCP configuration was added, but login failed"
assert_contains "${output}" "codex mcp login atlassian"
assert_log_equals $'mcp get atlassian\nmcp add atlassian --url https://mcp.atlassian.com/v1/mcp/authv2\nmcp login atlassian'

mkdir -p "${tmp_dir}/no-codex-bin"
ln -s "$(command -v bash)" "${tmp_dir}/no-codex-bin/bash"
set +e
output="$(PATH="${tmp_dir}/no-codex-bin" "${script}" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected a missing Codex CLI to fail the script" >&2
  exit 1
fi
assert_contains "${output}" "missing required command: codex"

set +e
output="$(PATH="${original_path}" "${script}" unexpected 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected unexpected arguments to fail the script" >&2
  exit 1
fi
assert_contains "${output}" "does not accept arguments"
