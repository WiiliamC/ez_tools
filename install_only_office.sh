#!/usr/bin/env bash

set -euo pipefail

KEY_ID="CB2DE8E5"
KEY_SERVER="hkp://keyserver.ubuntu.com:80"
KEYRING_PATH="/usr/share/keyrings/onlyoffice.gpg"
SOURCE_LIST_PATH="/etc/apt/sources.list.d/onlyoffice.list"
APT_REPOSITORY="https://download.onlyoffice.com/repo/debian"
PACKAGE_NAME="onlyoffice-desktopeditors"
TAG="[install-onlyoffice]"

usage() {
  cat <<'EOF'
Usage:
  ./install_only_office.sh install
  ./install_only_office.sh status
  ./install_only_office.sh help

Commands:
  install  Install ONLYOFFICE Desktop Editors from its official APT repository
  status   Show package, binary, keyring, and repository status
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
  need_cmd dpkg
  need_cmd getconf

  [[ "$(getconf LONG_BIT)" == "64" ]] || die "ONLYOFFICE Desktop Editors supports only 64-bit Linux"

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

package_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

install_dependencies() {
  log "updating APT package lists"
  as_root apt-get update

  log "installing required packages: ca-certificates gnupg"
  as_root apt-get install -y ca-certificates gnupg
}

install_keyring() {
  need_cmd chmod
  need_cmd gpg
  need_cmd install
  need_cmd mktemp

  local tmp_dir tmp_keyring
  tmp_dir="$(mktemp -d)"
  tmp_keyring="${tmp_dir}/onlyoffice.gpg"

  mkdir -p -m 700 "${HOME}/.gnupg"
  log "importing ONLYOFFICE signing key ${KEY_ID}"
  if ! gpg --batch \
    --no-default-keyring \
    --keyring "gnupg-ring:${tmp_keyring}" \
    --keyserver "${KEY_SERVER}" \
    --recv-keys "${KEY_ID}"; then
    rm -rf "${tmp_dir}"
    return 1
  fi

  chmod 0644 "${tmp_keyring}"
  log "installing ${KEYRING_PATH}"
  if ! as_root install -m 0644 -o root -g root "${tmp_keyring}" "${KEYRING_PATH}"; then
    rm -rf "${tmp_dir}"
    return 1
  fi
  rm -rf "${tmp_dir}"
}

write_source_list() {
  need_cmd install
  need_cmd mktemp

  local tmp_file
  tmp_file="$(mktemp)"
  printf 'deb [signed-by=%s] %s squeeze main\n' "${KEYRING_PATH}" "${APT_REPOSITORY}" >"${tmp_file}"

  log "writing ${SOURCE_LIST_PATH}"
  as_root install -d -m 0755 /etc/apt/sources.list.d
  if ! as_root install -m 0644 -o root -g root "${tmp_file}" "${SOURCE_LIST_PATH}"; then
    rm -f "${tmp_file}"
    return 1
  fi
  rm -f "${tmp_file}"
}

install_onlyoffice() {
  check_apt_system

  install_dependencies
  install_keyring
  write_source_list

  log "updating APT package lists with the ONLYOFFICE repository"
  as_root apt-get update

  log "installing ${PACKAGE_NAME}"
  as_root apt-get install -y "${PACKAGE_NAME}"

  show_status
}

show_status() {
  check_apt_system

  if package_installed "${PACKAGE_NAME}"; then
    log "package: ${PACKAGE_NAME} is installed"
  else
    log "package: ${PACKAGE_NAME} is not installed"
  fi

  if command -v desktopeditors >/dev/null 2>&1; then
    log "binary: $(command -v desktopeditors)"
  else
    log "binary: desktopeditors was not found in PATH"
  fi

  if [[ -f "${KEYRING_PATH}" ]]; then
    log "keyring: ${KEYRING_PATH}"
  else
    log "keyring: not found at ${KEYRING_PATH}"
  fi

  if [[ -f "${SOURCE_LIST_PATH}" ]]; then
    log "source list: ${SOURCE_LIST_PATH}"
    sed "s/^/${TAG} source: /" "${SOURCE_LIST_PATH}" || true
  else
    log "source list: not found at ${SOURCE_LIST_PATH}"
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
      install_onlyoffice
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
