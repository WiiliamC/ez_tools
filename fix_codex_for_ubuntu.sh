#!/usr/bin/env bash
set -euo pipefail

PROFILE_PATH="/etc/apparmor.d/codex-native"
PROFILE_NAME="codex-native"

log() {
  printf '[fix-codex] %s\n' "$*"
}

die() {
  printf '[fix-codex] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

resolve_codex_entrypoint() {
  local codex_path
  codex_path="$(command -v codex || true)"
  [[ -n "${codex_path}" ]] || die "codex was not found in PATH"
  readlink -f "${codex_path}"
}

find_codex_native_binary_under() {
  local roots=("$@")
  local native_path

  [[ "${#roots[@]}" -gt 0 ]] || return

  native_path="$(find "${roots[@]}" -path '*/@openai/codex-linux-*/vendor/*/bin/codex' -type f -perm -111 2>/dev/null | head -n 1 || true)"
  if [[ -n "${native_path}" ]]; then
    printf '%s\n' "${native_path}"
    return
  fi

  find "${roots[@]}" -path '*/@openai/codex-linux-*/vendor/*/codex/codex' -type f -perm -111 2>/dev/null | head -n 1 || true
}

resolve_codex_native_binary() {
  local entrypoint="$1"
  local node_dir native_path
  local -a global_roots

  if [[ -x "${entrypoint}" && "$(basename "${entrypoint}")" == "codex" && "${entrypoint}" == */vendor/*/bin/codex ]]; then
    printf '%s\n' "${entrypoint}"
    return
  fi

  if [[ -x "${entrypoint}" && "$(basename "${entrypoint}")" == "codex" && "${entrypoint}" == */vendor/*/codex/codex ]]; then
    printf '%s\n' "${entrypoint}"
    return
  fi

  node_dir="$(dirname "${entrypoint}")"

  while [[ "${node_dir}" != "/" ]]; do
    native_path="$(find_codex_native_binary_under "${node_dir}")"
    if [[ -n "${native_path}" ]]; then
      readlink -f "${native_path}"
      return
    fi
    node_dir="$(dirname "${node_dir}")"
  done

  global_roots=()
  if command -v npm >/dev/null 2>&1; then
    native_path="$(npm root -g 2>/dev/null || true)"
    if [[ -n "${native_path}" ]]; then
      global_roots+=("${native_path}/@openai/codex")
    fi
  fi
  global_roots+=(
    /usr/local/lib/node_modules/@openai/codex
    /usr/lib/node_modules/@openai/codex
  )

  native_path="$(find_codex_native_binary_under "${global_roots[@]}")"
  [[ -n "${native_path}" ]] || die "could not locate Codex native binary under the global npm install; checked both new vendor/*/bin/codex and old vendor/*/codex/codex layouts"
  readlink -f "${native_path}"
}

check_ubuntu_like() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
      ubuntu:*|*:*\ ubuntu\ *|*:ubuntu|debian:*|*:*\ debian\ *|*:debian)
        return
        ;;
    esac
    log "warning: this script is intended for Ubuntu/Debian-like systems; detected ID=${ID:-unknown}"
  fi
}

write_profile() {
  local native_binary="$1"
  local escaped_path profile_tmp

  escaped_path="${native_binary//\\/\\\\}"
  profile_tmp="$(mktemp)"

  cat >"${profile_tmp}" <<EOF
abi <abi/4.0>,
include <tunables/global>

@{codex_bin} = ${escaped_path}

profile ${PROFILE_NAME} @{codex_bin} flags=(unconfined) {
  userns,
  @{codex_bin} mr,
  include if exists <local/${PROFILE_NAME}>
}
EOF

  as_root install -m 0644 -o root -g root "${profile_tmp}" "${PROFILE_PATH}"
  rm -f "${profile_tmp}"
}

reload_profile() {
  need_cmd apparmor_parser
  as_root apparmor_parser -r "${PROFILE_PATH}"
}

show_userns_state() {
  if command -v sysctl >/dev/null 2>&1; then
    sysctl kernel.unprivileged_userns_clone user.max_user_namespaces kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || true
  fi
}

verify_profile_loaded() {
  if [[ -r /sys/kernel/security/apparmor/policy/profiles ]]; then
    if grep -Rqs "^${PROFILE_NAME}$" /sys/kernel/security/apparmor/policy/profiles; then
      log "AppArmor profile loaded: ${PROFILE_NAME}"
      return
    fi
  fi

  if [[ -r /sys/kernel/security/apparmor/profiles ]]; then
    if grep -qs "^${PROFILE_NAME} " /sys/kernel/security/apparmor/profiles; then
      log "AppArmor profile loaded: ${PROFILE_NAME}"
      return
    fi
  fi

  log "warning: could not confirm ${PROFILE_NAME} in AppArmor profile lists"
}

main() {
  need_cmd readlink
  need_cmd find
  need_cmd install
  need_cmd mktemp

  check_ubuntu_like

  local entrypoint native_binary
  entrypoint="$(resolve_codex_entrypoint)"
  native_binary="$(resolve_codex_native_binary "${entrypoint}")"

  log "Codex entrypoint: ${entrypoint}"
  log "Codex native binary: ${native_binary}"

  [[ -x "${native_binary}" ]] || die "Codex native binary is not executable: ${native_binary}"

  log "writing ${PROFILE_PATH}"
  write_profile "${native_binary}"

  log "reloading AppArmor profile"
  reload_profile

  verify_profile_loaded
  show_userns_state

  log "done. Restart Codex so the native process is started under the updated AppArmor profile."
}

main "$@"
