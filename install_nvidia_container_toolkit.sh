#!/usr/bin/env bash
set -euo pipefail

TAG='[install-nvidia-container-toolkit]'
KEYRING_PATH='/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
SOURCE_LIST_PATH='/etc/apt/sources.list.d/nvidia-container-toolkit.list'
DOCKER_CONFIG='/etc/docker/daemon.json'
REPO_BASE='https://nvidia.github.io/libnvidia-container'
TMP_DIR=''

usage() {
  cat <<'EOF'
Usage: ./install_nvidia_container_toolkit.sh [install [--no-restart]|status|help]

Install NVIDIA Container Toolkit from NVIDIA's stable APT repository on
Ubuntu/Debian and configure system Docker. No command means install.
Requires an existing system Docker installation and NVIDIA GPU driver.
Docker is restarted by default, which may interrupt running containers.
Use --no-restart to restart Docker manually later. Rootless Docker is unsupported.
EOF
}

log() { printf '%s %s\n' "$TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$TAG" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
as_root() {
  if [[ "$EUID" -eq 0 ]]; then "$@"; else need_cmd sudo; sudo "$@"; fi
}
cleanup() { if [[ -n "$TMP_DIR" ]]; then rm -rf -- "$TMP_DIR"; fi; }

check_apt_system() {
  need_cmd apt-get
  need_cmd dpkg-query
  [[ -r /etc/os-release ]] || die 'cannot read /etc/os-release'
  local ID='' ID_LIKE=''
  # shellcheck disable=SC1091
  . /etc/os-release
  case " $ID $ID_LIKE " in
    *' ubuntu '*|*' debian '*) ;;
    *) die 'only Ubuntu/Debian APT systems are supported' ;;
  esac
}

preflight() {
  local restart="$1"
  check_apt_system
  need_cmd docker
  need_cmd systemctl
  if [[ "$restart" == true ]]; then
    local state
    state="$(as_root systemctl show docker.service --property=LoadState --value)" || die 'cannot access system Docker service'
    [[ "$state" == loaded ]] || die 'system docker.service is not loaded'
  fi
}

install_repository() {
  as_root apt-get update
  as_root apt-get install -y --no-install-recommends ca-certificates curl gnupg2
  TMP_DIR="$(mktemp -d)"
  trap cleanup EXIT
  curl -fsSL "$REPO_BASE/gpgkey" -o "$TMP_DIR/key.asc"
  gpg --batch --yes --dearmor --output "$TMP_DIR/key.gpg" "$TMP_DIR/key.asc"
  curl -fsSL "$REPO_BASE/stable/deb/nvidia-container-toolkit.list" -o "$TMP_DIR/source.list"
  sed "s#deb https://#deb [signed-by=$KEYRING_PATH] https://#g" "$TMP_DIR/source.list" >"$TMP_DIR/signed.list"
  [[ -s "$TMP_DIR/key.gpg" ]] || die 'downloaded keyring is empty'
  grep -q '^deb \[signed-by=' "$TMP_DIR/signed.list" || die 'downloaded source list contains no signed repository'
  as_root install -d -m 0755 "$(dirname "$KEYRING_PATH")" "$(dirname "$SOURCE_LIST_PATH")"
  as_root install -m 0644 -o root -g root "$TMP_DIR/key.gpg" "$KEYRING_PATH"
  as_root install -m 0644 -o root -g root "$TMP_DIR/signed.list" "$SOURCE_LIST_PATH"
  as_root apt-get update
  as_root apt-get install -y nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1
  cleanup
  TMP_DIR=''
}

configure_docker() {
  local restart="$1" backup=''
  if as_root test -e "$DOCKER_CONFIG"; then
    backup="${DOCKER_CONFIG}.bak.$(date +%Y%m%d%H%M%S%N)"
    as_root cp -p -- "$DOCKER_CONFIG" "$backup"
    log "Docker configuration backup: $backup"
    log "To restore: sudo cp -p -- '$backup' '$DOCKER_CONFIG'; then sudo systemctl restart docker"
  else
    log "No previous $DOCKER_CONFIG; to undo, remove the generated file only if it has no subsequent changes, then restart Docker."
  fi
  if ! as_root nvidia-ctk runtime configure --runtime=docker --config="$DOCKER_CONFIG"; then
    die 'Docker configuration failed; Docker was not restarted. Use the recovery instructions above.'
  fi
  if [[ "$restart" == true ]]; then
    log 'Restarting Docker (running containers may be interrupted)'
    if ! as_root systemctl restart docker || ! as_root systemctl is-active --quiet docker; then
      die 'Docker restart failed; inspect systemctl status docker and use the recovery instructions above.'
    fi
  else
    log 'Configuration saved; run sudo systemctl restart docker to apply it.'
  fi
}

show_status() {
  check_apt_system
  local package runtimes
  for package in nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1; do
    if ! dpkg-query -W -f='${Package}: ${Status} ${Version}\n' "$package" 2>/dev/null; then
      log "$package: not installed"
    fi
  done
  if command -v nvidia-ctk >/dev/null 2>&1; then nvidia-ctk --version; else log 'nvidia-ctk: not found'; fi
  # Query only the local system daemon, ignoring remote contexts and rootless sockets.
  if command -v docker >/dev/null 2>&1; then
    if runtimes="$(docker --host unix:///var/run/docker.sock info --format '{{json .Runtimes}}' 2>&1)"; then
      if [[ "$runtimes" == *'"nvidia"'* ]]; then
        log 'Docker NVIDIA runtime: registered'
      else
        log 'Docker NVIDIA runtime: not registered (a restart may be pending)'
      fi
    else
      log "Cannot query system Docker (service or socket permissions): $runtimes"
      return 1
    fi
  else
    log 'Docker: not found'
    return 1
  fi
}

main() {
  local action="${1:-install}" restart=true
  if [[ $# -gt 0 ]]; then shift; fi
  if [[ "$action" == install && "${1:-}" == --no-restart ]]; then restart=false; shift; fi
  [[ $# -eq 0 ]] || die 'unexpected arguments; use help'
  case "$action" in
    install)
      preflight "$restart"
      install_repository
      configure_docker "$restart"
      nvidia-ctk --version
      log 'Toolkit installed. GPU workloads require a working host NVIDIA driver.'
      ;;
    status) show_status ;;
    help|-h|--help) usage ;;
    *) die "unknown command: $action; use help" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
