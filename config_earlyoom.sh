#!/usr/bin/env bash

set -euo pipefail

SERVICE_NAME="earlyoom"
TAG="[config-earlyoom]"

usage() {
  cat <<'EOF'
Usage:
  ./config_earlyoom.sh install
  ./config_earlyoom.sh status
  ./config_earlyoom.sh help

Commands:
  install  Install earlyoom, enable it, and start it with the package defaults
  status   Show earlyoom package and service status
  help     Show this help

Running without a command is the same as "install".
EOF
}

log() {
  printf '%s %s\n' "${TAG}" "$*"
}

die() {
  printf '%s ERROR: %s\n' "${TAG}" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    need_cmd sudo
    sudo "$@"
  fi
}

check_apt_system() {
  need_cmd apt-get

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    local id_like_tokens
    id_like_tokens=" ${ID_LIKE:-} "

    case "${ID:-}" in
      ubuntu|debian)
        return
        ;;
    esac

    case "${id_like_tokens}" in
      *" ubuntu "*|*" debian "*)
        return
        ;;
    esac

    die "this script only supports Ubuntu/Debian APT systems; detected ID=${ID:-unknown}"
  fi

  die "could not determine Linux distribution from /etc/os-release"
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]
}

install_earlyoom() {
  check_apt_system
  need_cmd systemctl

  log "updating APT package lists"
  as_root apt-get update

  log "installing earlyoom"
  as_root apt-get install -y earlyoom

  log "enabling and starting ${SERVICE_NAME}.service with package defaults"
  as_root systemctl enable --now "${SERVICE_NAME}.service"

  show_status
}

show_status() {
  check_apt_system

  if dpkg-query -W -f='${Status}\n' earlyoom 2>/dev/null | grep -qx 'install ok installed'; then
    log "package: earlyoom is installed"
  else
    log "package: earlyoom is not installed"
  fi

  if ! has_systemd; then
    log "service: systemd is not available or not running"
    return
  fi

  local enabled active
  enabled="$(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || true)"
  active="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"

  log "service enabled: ${enabled:-unknown}"
  log "service active: ${active:-unknown}"

  if systemctl list-unit-files "${SERVICE_NAME}.service" --no-legend 2>/dev/null | grep -q "^${SERVICE_NAME}\\.service"; then
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  else
    log "service unit not found: ${SERVICE_NAME}.service"
  fi
}

main() {
  local command_name="${1:-install}"

  if [[ $# -gt 1 ]]; then
    usage
    exit 1
  fi

  case "${command_name}" in
    install)
      install_earlyoom
      ;;
    status)
      show_status
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
