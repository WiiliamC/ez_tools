#!/usr/bin/env bash

set -euo pipefail

KEYRING_PATH="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
SOURCE_LIST_PATH="/etc/apt/sources.list.d/github-cli.list"
KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"
APT_REPO_URL="https://cli.github.com/packages"
TAG="[install-gh]"

usage() {
  cat <<'EOF'
Usage:
  ./install_gh_for_ubuntu.sh install
  ./install_gh_for_ubuntu.sh status
  ./install_gh_for_ubuntu.sh help

Commands:
  install  Install GitHub CLI from the official GitHub CLI APT repository
  status   Show gh package, binary, and repository status
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

package_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

install_dependencies() {
  log "updating APT package lists"
  as_root apt-get update

  log "installing required packages: ca-certificates wget"
  as_root apt-get install -y ca-certificates wget
}

install_keyring() {
  need_cmd install
  need_cmd mktemp
  need_cmd wget

  local tmp_file
  tmp_file="$(mktemp)"

  log "downloading GitHub CLI APT keyring"
  if ! wget -nv -O "${tmp_file}" "${KEYRING_URL}"; then
    rm -f "${tmp_file}"
    return 1
  fi

  log "installing ${KEYRING_PATH}"
  as_root install -d -m 0755 /etc/apt/keyrings
  if ! as_root install -m 0644 -o root -g root "${tmp_file}" "${KEYRING_PATH}"; then
    rm -f "${tmp_file}"
    return 1
  fi
  rm -f "${tmp_file}"
}

write_source_list() {
  need_cmd dpkg
  need_cmd install
  need_cmd mktemp

  local arch tmp_file
  arch="$(dpkg --print-architecture)"
  tmp_file="$(mktemp)"

  printf 'deb [arch=%s signed-by=%s] %s stable main\n' "${arch}" "${KEYRING_PATH}" "${APT_REPO_URL}" >"${tmp_file}"

  log "writing ${SOURCE_LIST_PATH}"
  as_root install -d -m 0755 /etc/apt/sources.list.d
  if ! as_root install -m 0644 -o root -g root "${tmp_file}" "${SOURCE_LIST_PATH}"; then
    rm -f "${tmp_file}"
    return 1
  fi
  rm -f "${tmp_file}"
}

install_gh() {
  check_apt_system

  install_dependencies
  install_keyring
  write_source_list

  log "updating APT package lists with GitHub CLI repository"
  as_root apt-get update

  log "installing gh"
  as_root apt-get install -y gh

  show_status
}

show_status() {
  check_apt_system

  if package_installed gh; then
    log "package: gh is installed"
  else
    log "package: gh is not installed"
  fi

  if command -v gh >/dev/null 2>&1; then
    log "binary: $(command -v gh)"
    gh --version || true
  else
    log "binary: gh was not found in PATH"
  fi

  if [[ -f "${KEYRING_PATH}" ]]; then
    log "keyring: ${KEYRING_PATH}"
  else
    log "keyring: not found at ${KEYRING_PATH}"
  fi

  if [[ -f "${SOURCE_LIST_PATH}" ]]; then
    log "source list: ${SOURCE_LIST_PATH}"
    sed 's/^/[install-gh] source: /' "${SOURCE_LIST_PATH}" || true
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
      install_gh
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
