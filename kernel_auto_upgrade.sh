#!/usr/bin/env bash

set -euo pipefail

MANAGED_FILE="/etc/apt/apt.conf.d/52-disable-kernel-auto-upgrades"
MANAGED_CONTENT='Unattended-Upgrade::Package-Blacklist { "linux-"; };'
TAG="[kernel-auto-upgrade]"

usage() {
  cat <<'EOF'
Usage:
  ./kernel_auto_upgrade.sh status
  ./kernel_auto_upgrade.sh disable
  ./kernel_auto_upgrade.sh enable
  ./kernel_auto_upgrade.sh help

Commands:
  status   Show whether unattended-upgrades effectively blacklists linux- packages
  disable  Write the managed APT config that blacklists linux- packages
  enable   Remove only the managed APT config file
  help     Show this help
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
  need_cmd apt-config

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

file_has_blacklist() {
  local file="$1"

  awk '
    function scan_token(token) {
      if (token == "Unattended-Upgrade") {
        current_path = token
      } else if (token == "Package-Blacklist") {
        if (in_unattended) {
          current_path = "Unattended-Upgrade::Package-Blacklist"
        } else {
          current_path = token
        }
      } else if (token == "Unattended-Upgrade::Package-Blacklist") {
        current_path = token
        in_fq_blacklist = 1
      } else if (token == "{") {
        if (current_path == "Unattended-Upgrade") {
          in_unattended++
        } else if (current_path == "Unattended-Upgrade::Package-Blacklist") {
          in_blacklist++
        }
        current_path = ""
      } else if (token == "}") {
        if (in_blacklist) {
          in_blacklist--
        } else if (in_unattended) {
          in_unattended--
        }
        current_path = ""
        in_fq_blacklist = 0
      } else if (token == "\"linux-\"") {
        if (in_blacklist || in_fq_blacklist || current_path == "Unattended-Upgrade::Package-Blacklist") {
          found = 1
        }
      } else if (token == ";") {
        current_path = ""
        in_fq_blacklist = 0
      }
    }

    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^(\/\/|#|\/\*|\*)/) {
        next
      }

      while (match(line, /Unattended-Upgrade::Package-Blacklist|Unattended-Upgrade|Package-Blacklist|"linux-"|[{};]/)) {
        scan_token(substr(line, RSTART, RLENGTH))
        line = substr(line, RSTART + RLENGTH)
      }
    }
    END {
      exit found ? 0 : 1
    }
  ' "${file}"
}

managed_file_has_blacklist() {
  [[ -f "${MANAGED_FILE}" ]] || return 1
  file_has_blacklist "${MANAGED_FILE}"
}

effective_has_blacklist() {
  apt-config dump Unattended-Upgrade::Package-Blacklist \
    | grep -Eq '^Unattended-Upgrade::Package-Blacklist(::)?[[:space:]]+"linux-"[[:space:]]*;'
}

find_unmanaged_blacklist_files() {
  local path

  for path in /etc/apt/apt.conf /etc/apt/apt.conf.d/*; do
    [[ -e "${path}" ]] || continue
    [[ "${path}" != "${MANAGED_FILE}" ]] || continue
    [[ -f "${path}" && -r "${path}" ]] || continue

    if file_has_blacklist "${path}"; then
      printf '%s\n' "${path}"
    fi
  done
}

disable_kernel_auto_upgrades() {
  check_apt_system
  need_cmd install
  need_cmd mktemp

  local tmp_file
  tmp_file="$(mktemp)"
  printf '%s\n' "${MANAGED_CONTENT}" >"${tmp_file}"

  log "writing ${MANAGED_FILE}"
  if ! as_root install -m 0644 -o root -g root "${tmp_file}" "${MANAGED_FILE}"; then
    rm -f "${tmp_file}"
    return 1
  fi
  rm -f "${tmp_file}"
  log "kernel package auto-upgrades are disabled through unattended-upgrades blacklist"
}

enable_kernel_auto_upgrades() {
  check_apt_system

  if [[ ! -e "${MANAGED_FILE}" ]]; then
    log "managed file is already absent: ${MANAGED_FILE}"
    return
  fi

  log "removing ${MANAGED_FILE}"
  as_root rm -f "${MANAGED_FILE}"
  log "removed managed blacklist file; any non-managed APT configuration was left unchanged"
}

show_status() {
  check_apt_system

  local effective="no"
  local managed="no"
  local unmanaged_files

  if effective_has_blacklist; then
    effective="yes"
  fi

  if managed_file_has_blacklist; then
    managed="yes"
  fi

  unmanaged_files="$(find_unmanaged_blacklist_files || true)"

  if [[ "${effective}" == "yes" ]]; then
    log "status: linux- packages are blacklisted in effective unattended-upgrades config"
  else
    log "status: linux- packages are not blacklisted in effective unattended-upgrades config"
  fi

  if [[ "${managed}" == "yes" ]]; then
    log "managed source: ${MANAGED_FILE}"
  else
    log "managed source: not present"
  fi

  if [[ -n "${unmanaged_files}" ]]; then
    log "non-managed source(s) also contain a linux- blacklist:"
    printf '%s\n' "${unmanaged_files}"
  else
    log "non-managed source: not detected"
  fi

  if [[ "${effective}" == "yes" && "${managed}" == "no" && -n "${unmanaged_files}" ]]; then
    log "note: enable will not remove this non-managed blacklist"
  fi
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    status)
      show_status
      ;;
    disable)
      disable_kernel_auto_upgrades
      ;;
    enable)
      enable_kernel_auto_upgrades
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
