#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${1:-}" == --case ]]; then
  source "$repo_root/install_nvidia_container_toolkit.sh"
  KEYRING_PATH="$CASE_DIR/keyring.gpg"
  SOURCE_LIST_PATH="$CASE_DIR/toolkit.list"
  DOCKER_CONFIG="$CASE_DIR/daemon.json"
  check_apt_system() { :; }
  need_cmd() { :; }
  as_root() {
    if [[ "$1" == install ]]; then
      shift
      local args=()
      while [[ $# -gt 0 ]]; do
        case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
      done
      command install "${args[@]}"
    else "$@"; fi
  }
  apt-get() { printf 'apt %s\n' "$*" >>"$CASE_DIR/calls"; }
  curl() {
    printf 'download\n' >>"$CASE_DIR/calls"
    [[ "$SCENARIO" != download-fail ]] || return 1
    if [[ "$2" == */gpgkey ]]; then
      printf 'fixture key\n' >"$4"
    else
      printf 'deb https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /\n' >"$4"
    fi
  }
  gpg() { printf 'fixture converted key\n' >"$5"; }
  nvidia-ctk() {
    printf 'ctk %s\n' "$*" >>"$CASE_DIR/calls"
    [[ "$1" != runtime ]] || {
      [[ "$SCENARIO" != config-fail ]] || return 1
      # Model the upstream configuration merge without touching host files.
      printf '{"debug":true,"runtimes":{"nvidia":{}}}\n' >"$DOCKER_CONFIG"
    }
  }
  systemctl() {
    printf 'systemctl %s\n' "$*" >>"$CASE_DIR/calls"
    case "$1" in
      show) if [[ "$SCENARIO" == preflight-fail ]]; then printf 'not-found\n'; else printf 'loaded\n'; fi ;;
      restart) [[ "$SCENARIO" != restart-fail ]] ;;
      is-active) return 0 ;;
    esac
  }
  dpkg-query() { printf 'fixture installed\n'; }
  docker() {
    [[ "$SCENARIO" != status-fail ]] || { printf 'permission denied\n' >&2; return 1; }
    printf '{"nvidia":{}}\n'
  }
  case "$SCENARIO" in
    no-restart) main install --no-restart ;;
    repeat) main; main ;;
    help) main help ;;
    status|status-fail) main status ;;
    bad-args) main install --invalid ;;
    *) main ;;
  esac
  exit
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
has() { grep -Fq -- "$2" "$1" || fail "missing: $2"; }
lacks() { if grep -Fq -- "$2" "$1"; then fail "unexpected: $2"; fi; }

for scenario in default no-restart repeat preflight-fail download-fail config-fail restart-fail help status status-fail bad-args; do
  case_dir="$tmp_dir/$scenario"
  mkdir -p "$case_dir"
  printf '{"debug":true}\n' >"$case_dir/daemon.json"
  cp "$case_dir/daemon.json" "$case_dir/original"
  : >"$case_dir/calls"
  result=0
  CASE_DIR="$case_dir" SCENARIO="$scenario" bash "$0" --case >"$case_dir/output" 2>&1 || result=$?
  case "$scenario" in
    *-fail|bad-args) [[ "$result" -ne 0 ]] || fail "$scenario should fail" ;;
    *) [[ "$result" -eq 0 ]] || { cat "$case_dir/output"; fail "$scenario failed"; } ;;
  esac
  case "$scenario" in
    default|no-restart|repeat|restart-fail)
      has "$case_dir/calls" 'apt install -y nvidia-container-toolkit '
      [[ "$(grep -c '^deb ' "$case_dir/toolkit.list")" == 1 ]] || fail 'duplicate sources'
      has "$case_dir/toolkit.list" "signed-by=$case_dir/keyring.gpg"
      backups=("$case_dir"/daemon.json.bak.*)
      cmp -s "$case_dir/original" "${backups[0]}" || fail 'backup differs'
      has "$case_dir/daemon.json" '"debug":true'
      if [[ "$scenario" == no-restart ]]; then
        lacks "$case_dir/calls" 'systemctl restart'
        has "$case_dir/output" 'run sudo systemctl restart docker'
      else has "$case_dir/calls" 'systemctl restart docker'; fi
      ;;
    download-fail|config-fail)
      lacks "$case_dir/calls" 'systemctl restart'
      cmp -s "$case_dir/original" "$case_dir/daemon.json" || fail 'configuration changed on failure'
      if [[ "$scenario" == download-fail ]]; then
        [[ ! -e "$case_dir/toolkit.list" && ! -e "$case_dir/keyring.gpg" ]] || fail 'published failed download'
        lacks "$case_dir/calls" 'ctk runtime'
      fi
      ;;
    help|status|status-fail|bad-args|preflight-fail)
      lacks "$case_dir/calls" 'apt '
      lacks "$case_dir/calls" 'ctk runtime'
      lacks "$case_dir/calls" 'systemctl restart'
      cmp -s "$case_dir/original" "$case_dir/daemon.json" || fail 'read-only command mutated config'
      ;;
  esac
done
printf 'All NVIDIA Container Toolkit tests passed.\n'
