#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../fix_codex_for_ubuntu.sh
source "${repo_root}/fix_codex_for_ubuntu.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

assert_equals() {
  local expected="$1"
  local actual="$2"

  if [[ "${actual}" != "${expected}" ]]; then
    printf 'Expected: %s\nActual: %s\n' "${expected}" "${actual}" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'Expected output to contain: %s\nActual output:\n%s\n' "${needle}" "${haystack}" >&2
    exit 1
  fi
}

make_native_binary() {
  local destination="$1"

  mkdir -p "$(dirname "${destination}")"
  cp "$(type -P true)" "${destination}"
  chmod +x "${destination}"
}

standalone_binary="${tmp_dir}/home/example/.codex/packages/standalone/releases/1.2.3-x86_64-unknown-linux-musl/bin/codex"
make_native_binary "${standalone_binary}"
assert_equals "${standalone_binary}" "$(resolve_codex_native_binary "${standalone_binary}")"
assert_equals "standalone" "$(detect_install_type "${standalone_binary}")"

npm_root="${tmp_dir}/npm/lib/node_modules/@openai/codex"
npm_entrypoint="${npm_root}/bin/codex.js"
npm_binary="${npm_root}/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"
mkdir -p "$(dirname "${npm_entrypoint}")"
printf '#!/usr/bin/env node\n' >"${npm_entrypoint}"
chmod +x "${npm_entrypoint}"
make_native_binary "${npm_binary}"
assert_equals "${npm_binary}" "$(resolve_codex_native_binary "${npm_entrypoint}")"
assert_equals "npm" "$(detect_install_type "${npm_binary}")"

custom_binary="${tmp_dir}/custom/bin/codex"
make_native_binary "${custom_binary}"
assert_equals "${custom_binary}" "$(resolve_codex_native_binary "${custom_binary}")"
assert_equals "native" "$(detect_install_type "${custom_binary}")"

# A directly invoked standalone binary must win even when an npm installation
# also exists elsewhere on the machine.
assert_equals "${standalone_binary}" "$(resolve_codex_native_binary "${standalone_binary}")"

missing_entrypoint="${tmp_dir}/missing/bin/codex.js"
set +e
output="$(resolve_codex_native_binary "${missing_entrypoint}" 2>&1)"
status=$?
set -e
if [[ "${status}" -eq 0 ]]; then
  echo "Expected a missing Codex native binary to fail" >&2
  exit 1
fi
if [[ "${output}" != *"Codex entrypoint does not exist"* ]]; then
  printf 'Unexpected error:\n%s\n' "${output}" >&2
  exit 1
fi

running_daemon_cli="${tmp_dir}/running-daemon-codex"
cat >"${running_daemon_cli}" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "app-server daemon version" ]]; then
  printf '%s\n' '{"status":"running"}'
  exit 0
fi
exit 99
EOF
chmod +x "${running_daemon_cli}"
output="$(show_restart_guidance "${running_daemon_cli}")"
assert_contains "${output}" "was not restarted to avoid interrupting active sessions"
assert_contains "${output}" "codex app-server daemon restart"

stopped_daemon_cli="${tmp_dir}/stopped-daemon-codex"
cat >"${stopped_daemon_cli}" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "app-server daemon version" ]]; then
  printf '%s\n' '{"status":"stopped"}'
  exit 0
fi
exit 99
EOF
chmod +x "${stopped_daemon_cli}"
output="$(show_restart_guidance "${stopped_daemon_cli}")"
assert_contains "${output}" "Start a new Codex session"
if [[ "${output}" == *"daemon restart"* ]]; then
  printf 'Stopped daemon guidance must not request a daemon restart:\n%s\n' "${output}" >&2
  exit 1
fi

unsupported_cli="${tmp_dir}/unsupported-codex"
cat >"${unsupported_cli}" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${unsupported_cli}"
output="$(show_restart_guidance "${unsupported_cli}")"
assert_contains "${output}" "Restart all running Codex processes after active work finishes"
