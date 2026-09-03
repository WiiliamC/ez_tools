#!/usr/bin/env bash
set -euo pipefail

PROFILE_PATH="/etc/apparmor.d/codex-native"
PROFILE_NAME="codex-native"
restart_daemon=false
sandbox_verification_succeeded=false

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

as_invoking_user() {
  if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    sudo -u "${SUDO_USER}" -- "$@"
  else
    "$@"
  fi
}

usage() {
  cat <<'EOF'
Usage: fix_codex_for_ubuntu.sh [--restart-daemon]

Install and reload the Codex AppArmor profile. By default, running Codex
processes are left alone. --restart-daemon restarts an already-running Codex
app-server daemon after local sandbox verification succeeds.
EOF
}

parse_args() {
  restart_daemon=false

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --restart-daemon)
        restart_daemon=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (try --help)"
        ;;
    esac
    shift
  done
}

resolve_codex_entrypoint() {
  local codex_path
  codex_path="$(command -v codex || true)"
  [[ -n "${codex_path}" ]] || die "codex was not found in PATH"
  readlink -f "${codex_path}"
}

is_native_executable() {
  local path="$1"

  [[ -f "${path}" && -x "${path}" ]] || return 1
  file -Lb -- "${path}" 2>/dev/null | grep -q '^ELF '
}

detect_install_type() {
  local native_binary="$1"

  case "${native_binary}" in
    */.codex/packages/standalone/releases/*/bin/codex)
      printf '%s\n' "standalone"
      ;;
    */@openai/codex-linux-*/vendor/*/bin/codex|*/@openai/codex-linux-*/vendor/*/codex/codex)
      printf '%s\n' "npm"
      ;;
    *)
      printf '%s\n' "native"
      ;;
  esac
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

  [[ -f "${entrypoint}" ]] || die "Codex entrypoint does not exist: ${entrypoint}"

  # The official installer exposes the standalone native binary directly.
  # Prefer any resolved native Codex entrypoint before looking for npm package
  # layouts, otherwise a stale global npm install can receive the AppArmor
  # profile instead of the binary that actually runs.
  if [[ "$(basename "${entrypoint}")" == "codex" ]] && is_native_executable "${entrypoint}"; then
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

escape_apparmor_path() {
  local path="$1"
  local escaped="${path//\\/\\\\}"

  escaped="${escaped//\"/\\\"}"
  escaped="${escaped//\?/\\?}"
  escaped="${escaped//\*/\\*}"
  escaped="${escaped//\[/\\[}"
  escaped="${escaped//\]/\\]}"
  escaped="${escaped//\{/\\{}"
  escaped="${escaped//\}/\\\}}"
  escaped="${escaped//\^/\\^}"
  printf '"%s"' "${escaped}"
}

find_codex_bwrap_paths() {
  local native_binary="$1"
  local binary_dir candidate resolved existing
  local -a candidates found

  binary_dir="$(dirname "${native_binary}")"
  candidates=()
  candidate="$(command -v bwrap || true)"
  [[ -n "${candidate}" ]] && candidates+=("${candidate}")
  candidates+=(
    "${binary_dir}/../codex-resources/bwrap"
    "${binary_dir}/codex-resources/bwrap"
  )

  found=()
  for candidate in "${candidates[@]}"; do
    [[ -f "${candidate}" && -x "${candidate}" ]] || continue
    resolved="$(readlink -f "${candidate}")"
    [[ -n "${resolved}" ]] || continue
    for existing in "${found[@]}"; do
      [[ "${existing}" == "${resolved}" ]] && continue 2
    done
    if [[ -n "${resolved}" ]]; then
      found+=("${resolved}")
    fi
  done

  [[ "${#found[@]}" -gt 0 ]] && printf '%s\n' "${found[@]}"
}

render_profile() {
  local native_binary="$1"
  shift
  local escaped_path bwrap

  escaped_path="$(escape_apparmor_path "${native_binary}")"

  cat <<EOF
abi <abi/4.0>,
include <tunables/global>

@{codex_bin} = ${escaped_path}

profile ${PROFILE_NAME} @{codex_bin} flags=(unconfined) {
  userns,
  @{codex_bin} mr,
EOF
  for bwrap in "$@"; do
    printf '  %s ix,\n' "$(escape_apparmor_path "${bwrap}")"
  done
  cat <<EOF
  include if exists <local/${PROFILE_NAME}>
}
EOF
}

validate_profile() {
  local profile_tmp="$1"

  if command -v apparmor_parser >/dev/null 2>&1; then
    apparmor_parser --skip-kernel-load --skip-cache "${profile_tmp}"
  else
    log "warning: apparmor_parser is unavailable; profile syntax was not pre-validated"
  fi
}

write_profile() {
  local native_binary="$1"
  shift
  local profile_tmp
  profile_tmp="$(mktemp)"

  render_profile "${native_binary}" "$@" >"${profile_tmp}"
  if ! validate_profile "${profile_tmp}"; then
    rm -f "${profile_tmp}"
    die "AppArmor profile syntax validation failed"
  fi

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

show_restart_guidance() {
  local native_binary="$1"
  local daemon_state

  if daemon_state="$(as_invoking_user "${native_binary}" app-server daemon version 2>/dev/null)"; then
    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' <<<"${daemon_state}"; then
      log "warning: the Codex app-server daemon is running and was not restarted to avoid interrupting active sessions."
      log "After all active Codex sessions finish, run:"
      log "  codex app-server daemon restart"
      log "Then start a new Codex session to use the updated AppArmor profile."
      return
    fi

    log "Start a new Codex session to use the updated AppArmor profile."
    return
  fi

  log "Restart all running Codex processes after active work finishes so they inherit the updated AppArmor profile."
}

daemon_is_running() {
  local native_binary="$1"
  local daemon_state

  daemon_state="$(as_invoking_user "${native_binary}" app-server daemon version 2>/dev/null)" || return 1
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"running"' <<<"${daemon_state}"
}

restart_running_daemon() {
  local native_binary="$1"

  if daemon_is_running "${native_binary}"; then
    log "restarting the already-running Codex app-server daemon"
    as_invoking_user "${native_binary}" app-server daemon restart
  else
    log "Codex app-server daemon is not running; no daemon restart was performed."
  fi
}

verification_user_for_euid() {
  local euid="$1"
  local sudo_user="$2"

  if [[ "${euid}" -ne 0 ]]; then
    id -un
    return
  fi
  if [[ -n "${sudo_user}" && "${sudo_user}" != "root" ]]; then
    printf '%s\n' "${sudo_user}"
    return
  fi
  return 1
}

verify_sandbox() {
  local native_binary="$1"
  local verification_user

  sandbox_verification_succeeded=false

  if ! verification_user="$(verification_user_for_euid "${EUID}" "${SUDO_USER:-}")"; then
    log "warning: cannot perform meaningful non-root sandbox verification when invoked directly as root; rerun via sudo from a non-root account."
    return
  fi

  log "verifying Codex sandbox as ${verification_user}"
  if [[ "${EUID}" -eq 0 ]]; then
    sudo -u "${verification_user}" -- "${native_binary}" sandbox -- /usr/bin/true || die "local sandbox verification failed; inspect AppArmor logs and rerun after correcting the profile"
  else
    "${native_binary}" sandbox -- /usr/bin/true || die "local sandbox verification failed; inspect AppArmor logs and rerun after correcting the profile"
  fi
  sandbox_verification_succeeded=true
  log "local Codex sandbox verification succeeded"
}

main() {
  parse_args "$@"
  need_cmd readlink
  need_cmd find
  need_cmd file
  need_cmd install
  need_cmd mktemp
  need_cmd apparmor_parser

  check_ubuntu_like

  local entrypoint native_binary install_type
  local -a bwrap_paths
  entrypoint="$(resolve_codex_entrypoint)"
  native_binary="$(resolve_codex_native_binary "${entrypoint}")"
  install_type="$(detect_install_type "${native_binary}")"

  log "Codex entrypoint: ${entrypoint}"
  log "Codex native binary: ${native_binary}"
  log "Codex install type: ${install_type}"

  [[ -x "${native_binary}" ]] || die "Codex native binary is not executable: ${native_binary}"

  mapfile -t bwrap_paths < <(find_codex_bwrap_paths "${native_binary}")
  if [[ "${#bwrap_paths[@]}" -gt 0 ]]; then
    log "permitting Codex descendant bubblewrap executables: ${bwrap_paths[*]}"
  else
    log "warning: no system or bundled bubblewrap executable was found; no bubblewrap execution rule was added"
  fi

  log "writing ${PROFILE_PATH}"
  write_profile "${native_binary}" "${bwrap_paths[@]}"

  log "reloading AppArmor profile"
  reload_profile

  verify_profile_loaded
  show_userns_state
  verify_sandbox "${native_binary}"
  if [[ "${restart_daemon}" == true ]]; then
    if [[ "${sandbox_verification_succeeded}" == true ]]; then
      restart_running_daemon "${native_binary}"
    else
      log "warning: daemon was not restarted because meaningful non-root sandbox verification was unavailable."
    fi
  else
    show_restart_guidance "${native_binary}"
  fi

  log "done."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
