#!/usr/bin/env bash

set -euo pipefail

readonly PROGRAM="safe_ssh"
readonly CONFIG_MARKER="# safe_ssh managed include"
readonly CONFIG_RESET="Host * # safe_ssh managed scope reset"
readonly OWNED_HEADER="# Managed by safe_ssh.sh; do not edit."
SSHD_CONFIG_DIR="${SAFE_SSH_SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
SSHD_CONFIG_FILE="${SAFE_SSH_SSHD_CONFIG:-/etc/ssh/sshd_config}"
OWNED_SSHD_CONFIG="${SSHD_CONFIG_DIR}/00-safe-ssh.conf"
if [[ "${SAFE_SSH_TESTING:-}" == 1 && "${EUID}" != 0 ]]; then
  SSHD_BIN="${SAFE_SSH_SSHD:-/usr/sbin/sshd}"
  SSH_BIN="${SAFE_SSH_SSH:-/usr/bin/ssh}"
  SYSTEMCTL_BIN="${SAFE_SSH_SYSTEMCTL:-/usr/bin/systemctl}"
  PASSWD_BIN="${SAFE_SSH_GETENT:-/usr/bin/getent}"
else
  readonly SSHD_BIN="/usr/sbin/sshd"
  readonly SSH_BIN="/usr/bin/ssh"
  readonly SYSTEMCTL_BIN="/usr/bin/systemctl"
  readonly PASSWD_BIN="/usr/bin/getent"
fi
LOG_FILE=""
LOG_READY=0
LOG_FD=""

usage() {
  cat <<'EOF'
Usage:
  safe_ssh.sh server_on [--admin-user USER] [--force]
  safe_ssh.sh server_off
  safe_ssh.sh server_status
  safe_ssh.sh client_add NAME USER@HOST [--port PORT] [--bootstrap-identity PATH]
  safe_ssh.sh client_delete NAME [--local-only]
  safe_ssh.sh client_status [NAME]
EOF
}

effective_uid() {
  if [[ "${SAFE_SSH_TESTING:-}" == 1 && -n "${SAFE_SSH_TEST_EUID:-}" ]]; then
    printf '%s\n' "${SAFE_SSH_TEST_EUID}"
  else
    printf '%s\n' "${EUID}"
  fi
}

passwd_record() {
  "${PASSWD_BIN}" passwd "$1"
}

resolve_initiator() {
  local user record home uid gid
  if [[ "$(effective_uid)" == 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    user="${SUDO_USER}"
  else
    user="$(id -un)"
  fi
  record="$(passwd_record "${user}")" || {
    printf 'Error: cannot resolve initiating user %s\n' "${user}" >&2
    return 1
  }
  IFS=: read -r _ _ uid gid _ home _ <<<"${record}"
  [[ -n "${uid}" && -n "${gid}" && "${home}" == /* ]] || {
    printf 'Error: unsafe passwd record for initiating user\n' >&2
    return 1
  }
  INITIATOR_USER="${user}"
  INITIATOR_UID="${uid}"
  INITIATOR_GID="${gid}"
  INITIATOR_HOME="${home}"
}

redacted_args() {
  local arg out="" redact_next=0
  for arg in "$@"; do
    if ((redact_next)); then
      out+=" [REDACTED]"
      redact_next=0
    elif [[ "${arg}" == --password || "${arg}" == --token || "${arg}" == --private-key ]]; then
      out+=" ${arg} [REDACTED]"
      redact_next=1
    elif [[ "${arg}" == *password=* || "${arg}" == *token=* || "${arg}" == *private_key=* ]]; then
      out+=" [REDACTED]"
    else
      printf -v quoted '%q' "${arg}"
      out+=" ${quoted}"
    fi
  done
  printf '%s\n' "${out# }"
}

init_log() {
  resolve_initiator || return 1
  local timestamp subcommand="${1:-help}" handoff_token="" expected_log safe_subcommand
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"

  if [[ -z "${SAFE_SSH_LOG_HANDOFF_FD:-}" ]]; then
    if [[ -n "${SAFE_SSH_LOG_FD:-}${SAFE_SSH_LOG_FILE:-}${SAFE_SSH_LOG_TIMESTAMP:-}${SAFE_SSH_LOG_HANDOFF_TOKEN:-}" ]]; then
      printf 'Error: refusing caller-supplied invocation logging state\n' >&2
      return 1
    fi
    exec /usr/bin/python3 /dev/fd/3 \
      "$0" "${INITIATOR_HOME}" "${INITIATOR_UID}" "${INITIATOR_GID}" \
      "${timestamp}" "${subcommand}" "$@" 3<<'PY'
import os
import re
import secrets
import sys

script, home, uid, gid, timestamp, subcommand = sys.argv[1:7]
args = sys.argv[7:]
uid, gid = int(uid), int(gid)
directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC

def open_absolute_directory(path):
    fd = os.open("/", directory_flags)
    try:
        for component in path.split("/"):
            if not component:
                continue
            if component in (".", ".."):
                raise OSError("unsafe component in log path")
            next_fd = os.open(component, directory_flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise

def open_private_directory(parent_fd, name):
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    fd = os.open(name, directory_flags, dir_fd=parent_fd)
    os.fchmod(fd, 0o700)
    if os.geteuid() == 0:
        os.fchown(fd, uid, gid)
    return fd

try:
    home_fd = open_absolute_directory(home)
    try:
        base_fd = open_private_directory(home_fd, ".safe_ssh")
    finally:
        os.close(home_fd)
    try:
        logs_fd = open_private_directory(base_fd, "logs")
    finally:
        os.close(base_fd)
    try:
        safe_subcommand = re.sub(r"[^A-Za-z0-9._-]", "_", subcommand)
        filename = f"{timestamp}-{safe_subcommand}-{os.getpid()}.log"
        log_fd = os.open(
            filename,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=logs_fd,
        )
    finally:
        os.close(logs_fd)
    os.fchmod(log_fd, 0o600)
    if os.geteuid() == 0:
        os.fchown(log_fd, uid, gid)
    os.set_inheritable(log_fd, True)
    handoff_read, handoff_write = os.pipe2(os.O_CLOEXEC)
    handoff_token = secrets.token_hex(32)
    os.write(handoff_write, handoff_token.encode())
    os.close(handoff_write)
    os.set_inheritable(handoff_read, True)
    env = os.environ.copy()
    env["SAFE_SSH_LOG_FD"] = str(log_fd)
    env["SAFE_SSH_LOG_FILE"] = os.path.join(home, ".safe_ssh", "logs", filename)
    env["SAFE_SSH_LOG_TIMESTAMP"] = timestamp
    env["SAFE_SSH_LOG_HANDOFF_FD"] = str(handoff_read)
    env["SAFE_SSH_LOG_HANDOFF_TOKEN"] = handoff_token
    os.execve(os.path.abspath(script), [script, *args], env)
except OSError as error:
    print(f"Error: cannot safely create invocation log: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
  fi

  [[ "${SAFE_SSH_LOG_HANDOFF_FD}" =~ ^[0-9]+$ &&
     "${SAFE_SSH_LOG_FD:-}" =~ ^[0-9]+$ &&
     -n "${SAFE_SSH_LOG_FILE:-}" &&
     "${SAFE_SSH_LOG_TIMESTAMP:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ &&
     -n "${SAFE_SSH_LOG_HANDOFF_TOKEN:-}" &&
     -e "/proc/self/fd/${SAFE_SSH_LOG_HANDOFF_FD}" ]] || {
    printf 'Error: invalid invocation log handoff\n' >&2
    return 1
  }
  IFS= read -r -u "${SAFE_SSH_LOG_HANDOFF_FD}" handoff_token || [[ -n "${handoff_token}" ]]
  exec {SAFE_SSH_LOG_HANDOFF_FD}<&-
  [[ "${handoff_token}" == "${SAFE_SSH_LOG_HANDOFF_TOKEN}" ]] || {
    printf 'Error: invalid invocation log handoff\n' >&2
    return 1
  }
  unset SAFE_SSH_LOG_HANDOFF_FD SAFE_SSH_LOG_HANDOFF_TOKEN

  LOG_FD="${SAFE_SSH_LOG_FD}"
  LOG_FILE="${SAFE_SSH_LOG_FILE}"
  timestamp="${SAFE_SSH_LOG_TIMESTAMP}"
  unset SAFE_SSH_LOG_FD SAFE_SSH_LOG_FILE SAFE_SSH_LOG_TIMESTAMP
  safe_subcommand="${subcommand//[^A-Za-z0-9._-]/_}"
  expected_log="${INITIATOR_HOME}/.safe_ssh/logs/${timestamp}-${safe_subcommand}-$$.log"
  [[ "${LOG_FILE}" == "${expected_log}" &&
     -f "/proc/self/fd/${LOG_FD}" &&
     "$(readlink "/proc/self/fd/${LOG_FD}")" == "${LOG_FILE}" &&
     "$(stat -Lc '%a:%u:%h' "/proc/self/fd/${LOG_FD}")" == "600:${INITIATOR_UID}:1" ]] || {
    printf 'Error: invalid invocation log descriptor\n' >&2
    return 1
  }
  LOG_READY=1
  exec > >(tee -a "/proc/self/fd/${LOG_FD}") 2>&1
  printf 'timestamp=%s user=%s subcommand=%s pid=%s args=%s\n' \
    "${timestamp}" "${INITIATOR_USER}" "${subcommand}" "$$" "$(redacted_args "$@")"
}

finish() {
  local status=$?
  if ((LOG_READY)); then
    printf 'exit_code=%s\n' "${status}"
  fi
}
trap finish EXIT

phase() {
  printf 'phase=%s\n' "$1"
}

require_root() {
  [[ "$(effective_uid)" == 0 ]] || {
    printf 'Error: %s requires root (use sudo).\n' "$1" >&2
    return 1
  }
}

require_unprivileged_client() {
  [[ "$(effective_uid)" != 0 ]] || {
    printf 'Error: client commands must not be run as root or through sudo.\n' >&2
    return 1
  }
}

validate_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || {
    printf 'Error: invalid client name: %s\n' "$1" >&2
    return 1
  }
}

validate_target() {
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9._-]*@([A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])$ ]] || {
    printf 'Error: target must be USER@HOST without shell syntax\n' >&2
    return 1
  }
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)) || {
    printf 'Error: invalid port: %s\n' "$1" >&2
    return 1
  }
}

user_home() {
  local record home
  record="$(passwd_record "$1")" || return 1
  IFS=: read -r _ _ _ _ _ home _ <<<"${record}"
  [[ "${home}" == /* ]] || return 1
  printf '%s\n' "${home}"
}

ensure_server_scope() {
  local os_release="${SAFE_SSH_OS_RELEASE:-/etc/os-release}" os_id os_like version
  [[ -r "${os_release}" ]] || { printf 'Error: Ubuntu or Debian is required.\n' >&2; return 1; }
  os_id="$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print tolower($2); exit}' "${os_release}")"
  os_like="$(awk -F= '$1=="ID_LIKE"{gsub(/"/,"",$2); print tolower($2); exit}' "${os_release}")"
  [[ "${os_id}" == ubuntu || "${os_id}" == debian || " ${os_like} " == *" debian "* ]] || {
    printf 'Error: safe_ssh server management supports Ubuntu/Debian only.\n' >&2
    return 1
  }
  "${SYSTEMCTL_BIN}" --version >/dev/null 2>&1 || {
    printf 'Error: systemd systemctl is required.\n' >&2
    return 1
  }
  version="$("${SSHD_BIN}" -V 2>&1)" || [[ "${version}" == *OpenSSH* ]] || {
    printf 'Error: OpenSSH sshd is required.\n' >&2
    return 1
  }
  [[ "${version}" == *OpenSSH* ]] || {
    printf 'Error: unsupported sshd implementation (OpenSSH required).\n' >&2
    return 1
  }
}

sshd_effective() {
  "${SSHD_BIN}" -T
}

matched_policy_directive() {
  local debug file line matched files=()
  debug="$("${SSHD_BIN}" -T -ddd 2>&1)" || return 2
  while IFS= read -r line; do
    case "${line}" in
      *"load_server_config: filename "*)
        file="${line#*load_server_config: filename }"
        ;;
      *": including "*)
        file="${line#*: including }"
        ;;
      *)
        continue
        ;;
    esac
    [[ -f "${file}" && -r "${file}" ]] || return 2
    files+=("${file}")
  done <<<"${debug}"
  ((${#files[@]})) || return 2
  matched="$(awk '
    /^[[:space:]]*(#|$)/ {next}
    {
      keyword=tolower($1)
      if (keyword=="match" && tolower($2)!="all") {
        print FILENAME ":" FNR ":" $0
        exit
      }
    }
  ' "${files[@]}")"
  [[ -n "${matched}" ]] || return 1
  printf '%s\n' "${matched}"
}

server_policy_all_contexts_effective() {
  local user="${1:-${INITIATOR_USER}}" effective context matched_status
  effective="$(sshd_effective)" || return 1
  server_policy_effective "${effective}" || return 1
  for context in \
    "user=${user},host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22" \
    "user=${user},host=example.invalid,addr=192.0.2.1,laddr=192.0.2.2,lport=22" \
    "user=root,host=localhost,addr=::1,laddr=::1,lport=22"; do
    effective="$("${SSHD_BIN}" -T -C "${context}")" || return 1
    server_policy_effective "${effective}" || return 1
  done
  if matched_policy_directive >/dev/null; then
    return 1
  else
    matched_status=$?
    [[ "${matched_status}" == 1 ]]
  fi
}

reload_sshd() {
  "${SYSTEMCTL_BIN}" reload ssh.service 2>/dev/null ||
    "${SYSTEMCTL_BIN}" reload sshd.service
}

write_atomic() {
  local target="$1" mode="$2" tmp
  mkdir -p "$(dirname "${target}")"
  tmp="$(mktemp "$(dirname "${target}")/.safe_ssh.tmp.XXXXXX")"
  cat >"${tmp}"
  chmod "${mode}" "${tmp}"
  mv -f "${tmp}" "${target}"
}

authorized_key_path_is_safe() {
  local file="$1" home="$2" uid="$3" path owner mode stop="/"
  if [[ "${file}" == "${home}"/* ]]; then
    stop="${home}"
  fi
  path="${file}"
  while :; do
    [[ ! -L "${path}" ]] || return 1
    read -r owner mode < <(stat -Lc '%u %a' -- "${path}") || return 1
    [[ "${owner}" == 0 || "${owner}" == "${uid}" ]] || return 1
    (( (8#${mode} & 8#022) == 0 )) || return 1
    [[ "${path}" != "${stop}" ]] || break
    path="$(dirname "${path}")"
    [[ "${path}" != "." ]] || return 1
  done
}

authorized_key_file_has_key() {
  local file="$1" home="$2" uid="$3" line key_type
  [[ -f "${file}" && ! -L "${file}" ]] || return 1
  authorized_key_path_is_safe "${file}" "${home}" "${uid}" || return 1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    read -r key_type _ <<<"${line}"
    case "${key_type}" in
      ssh-*|ecdsa-*|sk-*)
        printf '%s\n' "${line}" |
          ssh-keygen -lf /dev/stdin >/dev/null 2>&1 && return 0
        ;;
    esac
  done <"${file}"
  return 1
}

admin_has_key() {
  local admin="$1" auth_values="$2" home uid token file
  home="$(user_home "${admin}")" || return 1
  uid="$(passwd_record "${admin}" | awk -F: '{print $3}')"
  for token in ${auth_values} .safe_ssh/authorized_keys; do
    [[ "${token}" != none ]] || continue
    token="${token//%%/%}"
    token="${token//%h/${home}}"
    token="${token//%u/${admin}}"
    token="${token//%U/${uid}}"
    [[ "${token}" != *%* ]] || continue
    if [[ "${token}" == /* ]]; then
      file="${token}"
    else
      file="${home}/${token}"
    fi
    authorized_key_file_has_key "${file}" "${home}" "${uid}" && return 0
  done
  return 1
}

admin_login_probe() {
  local admin="$1" effective port host=127.0.0.1
  effective="$("${SSHD_BIN}" -T -C \
    "user=${admin},host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22")" ||
    return 1
  port="$(awk 'tolower($1)=="port"{print $2;exit}' <<<"${effective}")"
  validate_port "${port:-22}" >/dev/null 2>&1 || return 1
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    read -r _ _ host _ <<<"${SSH_CONNECTION}"
  fi
  "${SSH_BIN}" -n \
    -F /dev/null \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o ChallengeResponseAuthentication=no \
    -o NumberOfPasswordPrompts=0 \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -p "${port:-22}" -l "${admin}" "${host}" true
}

server_policy_effective() {
  local effective="$1" pub pass kbd methods auth
  pub="$(awk 'tolower($1)=="pubkeyauthentication"{print tolower($2);exit}' <<<"${effective}")"
  pass="$(awk 'tolower($1)=="passwordauthentication"{print tolower($2);exit}' <<<"${effective}")"
  kbd="$(awk 'tolower($1)=="kbdinteractiveauthentication"{print tolower($2);exit}' <<<"${effective}")"
  methods="$(awk 'tolower($1)=="authenticationmethods"{$1="";sub(/^ /,"");print tolower($0);exit}' <<<"${effective}")"
  auth="$(awk 'tolower($1)=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"${effective}")"
  [[ "${pub}" == yes &&
     "${pass}" == no &&
     "${kbd}" == no &&
     "${methods}" == publickey &&
     " ${auth} " == *" .safe_ssh/authorized_keys "* ]]
}

sshd_service_active() {
  "${SYSTEMCTL_BIN}" is-active --quiet ssh.service 2>/dev/null ||
    "${SYSTEMCTL_BIN}" is-active --quiet sshd.service 2>/dev/null
}

server_on() {
  require_root server_on
  ensure_server_scope
  local admin="" force=0 baseline auth_values prior="" had_prior=0
  shift
  while (($#)); do
    case "$1" in
      --admin-user) (($# >= 2)) || { printf 'Error: --admin-user needs USER\n' >&2; return 2; }; admin="$2"; shift 2 ;;
      --force) force=1; shift ;;
      *) printf 'Error: unknown server_on option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  phase server_baseline
  baseline="$(sshd_effective)" || { printf 'Error: cannot read effective sshd configuration\n' >&2; return 1; }
  auth_values="$(awk 'tolower($1)=="authorizedkeysfile" {$1=""; sub(/^ /,""); print; exit}' <<<"${baseline}")"
  [[ -n "${auth_values}" ]] || auth_values=".ssh/authorized_keys .ssh/authorized_keys2"
  if ((!force)); then
    [[ -n "${admin}" ]] || { printf 'Error: --admin-user is required unless --force is used\n' >&2; return 1; }
    admin_has_key "${admin}" "${auth_values}" || {
      printf 'Error: %s has no usable key in the current or safe_ssh authorization files; refusing possible lockout\n' "${admin}" >&2
      return 1
    }
    phase server_login_probe
    admin_login_probe "${admin}" || {
      printf 'Error: public-key login probe for %s failed; refusing possible lockout\n' "${admin}" >&2
      return 1
    }
  fi
  if [[ " ${auth_values} " != *" .safe_ssh/authorized_keys "* ]]; then
    auth_values+=" .safe_ssh/authorized_keys"
  fi
  mkdir -p "${SSHD_CONFIG_DIR}"
  if [[ -e "${OWNED_SSHD_CONFIG}" ]]; then
    grep -Fqx "${OWNED_HEADER}" "${OWNED_SSHD_CONFIG}" || {
      printf 'Error: refusing to replace unowned file %s\n' "${OWNED_SSHD_CONFIG}" >&2
      return 1
    }
    prior="$(mktemp "${SSHD_CONFIG_DIR}/.safe_ssh.rollback.XXXXXX")"
    cp -p "${OWNED_SSHD_CONFIG}" "${prior}"
    had_prior=1
  fi
  phase server_write
  {
    printf '%s\n' "${OWNED_HEADER}"
    printf 'PubkeyAuthentication yes\n'
    printf 'PasswordAuthentication no\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'ChallengeResponseAuthentication no\n'
    printf 'AuthenticationMethods publickey\n'
    printf 'AuthorizedKeysFile %s\n' "${auth_values}"
  } | write_atomic "${OWNED_SSHD_CONFIG}" 644
  phase server_validate
  if ! "${SSHD_BIN}" -t; then
    phase rollback
    if ((had_prior)); then mv -f "${prior}" "${OWNED_SSHD_CONFIG}"; else rm -f "${OWNED_SSHD_CONFIG}"; fi
    return 1
  fi
  if ! server_policy_all_contexts_effective "${admin:-${INITIATOR_USER}}"; then
    printf 'Error: safe_ssh policy is not effective in all checked SSH connection contexts; check Include ordering and Match blocks\n' >&2
    phase rollback
    if ((had_prior)); then mv -f "${prior}" "${OWNED_SSHD_CONFIG}"; else rm -f "${OWNED_SSHD_CONFIG}"; fi
    return 1
  fi
  phase server_reload
  if ! reload_sshd; then
    phase rollback
    if ((had_prior)); then mv -f "${prior}" "${OWNED_SSHD_CONFIG}"; else rm -f "${OWNED_SSHD_CONFIG}"; fi
    "${SSHD_BIN}" -t && reload_sshd || true
    return 1
  fi
  [[ -z "${prior}" ]] || rm -f "${prior}"
  printf 'safe_ssh server policy enabled.\n'
}

server_off() {
  require_root server_off
  ensure_server_scope
  local prior=""
  shift
  (($# == 0)) || { printf 'Error: server_off takes no arguments\n' >&2; return 2; }
  if [[ ! -e "${OWNED_SSHD_CONFIG}" ]]; then
    printf 'safe_ssh server policy is already disabled.\n'
    return 0
  fi
  grep -Fqx "${OWNED_HEADER}" "${OWNED_SSHD_CONFIG}" || {
    printf 'Error: refusing to remove unowned file %s\n' "${OWNED_SSHD_CONFIG}" >&2
    return 1
  }
  prior="$(mktemp "${SSHD_CONFIG_DIR}/.safe_ssh.rollback.XXXXXX")"
  cp -p "${OWNED_SSHD_CONFIG}" "${prior}"
  phase server_remove
  rm -f "${OWNED_SSHD_CONFIG}"
  phase server_validate
  if ! "${SSHD_BIN}" -t || ! reload_sshd; then
    phase rollback
    mv -f "${prior}" "${OWNED_SSHD_CONFIG}"
    "${SSHD_BIN}" -t && reload_sshd || true
    return 1
  fi
  rm -f "${prior}"
  printf 'safe_ssh server policy disabled; baseline sshd configuration restored.\n'
}

server_status() {
  require_root server_status
  shift
  (($# == 0)) || { printf 'Error: server_status takes no arguments\n' >&2; return 2; }
  local effective pub pass kbd methods auth owned=no service=inactive state=disabled
  effective="$(sshd_effective)" || { printf 'server: unavailable\n'; return 1; }
  pub="$(awk 'tolower($1)=="pubkeyauthentication"{print tolower($2);exit}' <<<"${effective}")"
  pass="$(awk 'tolower($1)=="passwordauthentication"{print tolower($2);exit}' <<<"${effective}")"
  kbd="$(awk 'tolower($1)=="kbdinteractiveauthentication"{print tolower($2);exit}' <<<"${effective}")"
  methods="$(awk 'tolower($1)=="authenticationmethods"{$1="";sub(/^ /,"");print tolower($0);exit}' <<<"${effective}")"
  auth="$(awk 'tolower($1)=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"${effective}")"
  [[ -f "${OWNED_SSHD_CONFIG}" ]] && grep -Fqx "${OWNED_HEADER}" "${OWNED_SSHD_CONFIG}" && owned=yes
  sshd_service_active && service=active
  if [[ "${owned}" == yes && "${service}" == active ]] &&
     server_policy_effective "${effective}" &&
     server_policy_all_contexts_effective "${INITIATOR_USER}"; then
    state=enabled
  fi
  printf 'server: %s (service=%s, owned_dropin=%s, pubkey=%s, password=%s, keyboard_interactive=%s, authentication_methods=%s, authorized_keys=%s)\n' \
    "${state}" "${service}" "${owned}" "${pub:-unknown}" "${pass:-unknown}" "${kbd:-unknown}" \
    "${methods:-unknown}" "${auth:-unknown}"
  [[ "${state}" == enabled ]]
}

client_root() {
  if [[ "$(effective_uid)" == 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    printf '%s/.config/safe_ssh\n' "${INITIATOR_HOME}"
  else
    printf '%s/safe_ssh\n' "${XDG_CONFIG_HOME:-${INITIATOR_HOME}/.config}"
  fi
}

ensure_client_layout() {
  local root
  root="$(client_root)"
  [[ ! -L "${root}" && ! -L "${root}/clients" && ! -L "${root}/ssh_config.d" ]] || {
    printf 'Error: unsafe symlink in safe_ssh client path\n' >&2
    return 1
  }
  mkdir -p "${root}/clients" "${root}/ssh_config.d"
  chmod 700 "${root}" "${root}/clients" "${root}/ssh_config.d"
}

include_line() {
  printf 'Include %s\n' "$(ssh_config_quote "$(client_root)/ssh_config.d/*")"
}

ssh_config_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "${value}"
}

install_include() {
  local ssh_dir="${INITIATOR_HOME}/.ssh" config tmp filtered include
  config="${ssh_dir}/config"
  include="$(include_line)"
  [[ ! -L "${ssh_dir}" && ! -L "${config}" ]] || { printf 'Error: unsafe symlink in SSH config path\n' >&2; return 1; }
  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"
  tmp="$(mktemp "${ssh_dir}/.safe_ssh.config.XXXXXX")"
  filtered="$(mktemp)"
  if [[ -f "${config}" ]]; then
    awk -v marker="${CONFIG_MARKER}" -v reset="${CONFIG_RESET}" '
      skip {skip=0; next}
      $0==marker {skip=1; next}
      $0==reset {next}
      {print}
    ' "${config}" >"${filtered}"
  fi
  {
    printf '%s\n%s\n%s\n' "${CONFIG_MARKER}" "${include}" "${CONFIG_RESET}"
    cat "${filtered}"
  } >"${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${config}"
  rm -f "${filtered}"
}

remove_include_if_unused() {
  local root config tmp
  root="$(client_root)"
  find "${root}/clients" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null | grep -q . && return 0
  config="${INITIATOR_HOME}/.ssh/config"
  [[ -f "${config}" && ! -L "${config}" ]] || return 0
  tmp="$(mktemp "$(dirname "${config}")/.safe_ssh.config.XXXXXX")"
  awk -v marker="${CONFIG_MARKER}" -v reset="${CONFIG_RESET}" '
    skip {skip=0; next}
    $0==marker {skip=1; next}
    $0==reset {next}
    {print}
  ' "${config}" >"${tmp}"
  chmod 600 "${tmp}"
  mv -f "${tmp}" "${config}"
}

ssh_common_args() {
  local known="$1"
  SSH_ARGS=(-o "UserKnownHostsFile=${known}" -o StrictHostKeyChecking=ask -o GlobalKnownHostsFile=/dev/null)
}

remote_add_script() {
  cat <<'REMOTE'
set -eu
key=$1
umask 077
dir="$HOME/.safe_ssh"
[ ! -L "$dir" ]
mkdir -p "$dir"
[ -d "$dir" ] && [ -O "$dir" ]
chmod 700 "$dir"
file="$dir/authorized_keys"
[ ! -L "$file" ]
touch "$file"
chmod 600 "$file"
if ! grep -Fqx -- "$key" "$file"; then
  tmp="$file.safe_ssh.$$"
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  { cat "$file"; printf '%s\n' "$key"; } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$file"
  trap - EXIT HUP INT TERM
fi
REMOTE
}

remote_delete_script() {
  cat <<'REMOTE'
set -eu
key=$1
key_type=$(printf '%s\n' "$key" | awk '{print $1}')
key_blob=$(printf '%s\n' "$key" | awk '{print $2}')
file="$HOME/.safe_ssh/authorized_keys"
[ ! -L "$HOME/.safe_ssh" ]
[ ! -L "$file" ]
[ -f "$file" ] || exit 0
tmp="$file.safe_ssh.$$"
awk -v type="$key_type" -v blob="$key_blob" '
  function matching_key(line, fields, count, i, char, token, quoted, escaped) {
    if (line ~ /^[[:space:]]*#/) return 0
    fields[1]=fields[2]=fields[3]=""
    count=0
    token=""
    quoted=0
    escaped=0
    for (i=1; i<=length(line); i++) {
      char=substr(line, i, 1)
      if (escaped) {
        token=token char
        escaped=0
      } else if (char=="\\") {
        token=token char
        escaped=1
      } else if (char=="\"") {
        token=token char
        quoted=!quoted
      } else if (!quoted && char ~ /[[:space:]]/) {
        if (token!="") {
          fields[++count]=token
          token=""
          if (count==3) break
        }
      } else {
        token=token char
      }
    }
    if (token!="" && count<3) fields[++count]=token
    return (fields[1]==type && fields[2]==blob) ||
           (fields[2]==type && fields[3]==blob)
  }
  {
    if (!matching_key($0)) print
  }
' "$file" >"$tmp"
chmod 600 "$tmp"
mv "$tmp" "$file"
! awk -v type="$key_type" -v blob="$key_blob" '
  function matching_key(line, fields, count, i, char, token, quoted, escaped) {
    if (line ~ /^[[:space:]]*#/) return 0
    fields[1]=fields[2]=fields[3]=""
    count=0
    token=""
    quoted=0
    escaped=0
    for (i=1; i<=length(line); i++) {
      char=substr(line, i, 1)
      if (escaped) {
        token=token char
        escaped=0
      } else if (char=="\\") {
        token=token char
        escaped=1
      } else if (char=="\"") {
        token=token char
        quoted=!quoted
      } else if (!quoted && char ~ /[[:space:]]/) {
        if (token!="") {
          fields[++count]=token
          token=""
          if (count==3) break
        }
      } else {
        token=token char
      }
    }
    if (token!="" && count<3) fields[++count]=token
    return (fields[1]==type && fields[2]==blob) ||
           (fields[2]==type && fields[3]==blob)
  }
  {
    if (matching_key($0)) found=1
  }
  END {exit found ? 0 : 1}
' "$file"
REMOTE
}

client_add() {
  local name="${2:-}" target="${3:-}" port=22 bootstrap="" root dir profile key public fingerprint known snippet remote_key target_host ssh_target existing=0 authorized=0 authorization_completed=0
  [[ -n "${name}" && -n "${target}" ]] || { usage; return 2; }
  validate_name "${name}"
  validate_target "${target}"
  target_host="${target#*@}"
  target_host="${target_host#[}"
  target_host="${target_host%]}"
  ssh_target="${target%@*}@${target_host}"
  shift 3
  while (($#)); do
    case "$1" in
      --port) (($# >= 2)) || return 2; validate_port "$2"; port="$2"; shift 2 ;;
      --bootstrap-identity) (($# >= 2)) || return 2; bootstrap="$2"; [[ -f "${bootstrap}" && ! -L "${bootstrap}" ]] || { printf 'Error: invalid bootstrap identity\n' >&2; return 1; }; shift 2 ;;
      *) printf 'Error: unknown client_add option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  ensure_client_layout
  root="$(client_root)"; dir="${root}/clients/${name}"; profile="${dir}/profile"; key="${dir}/id_ed25519"
  public="${key}.pub"; known="${dir}/known_hosts"; snippet="${root}/ssh_config.d/${name}.conf"
  [[ ! -L "${dir}" && ! -L "${profile}" && ! -L "${key}" && ! -L "${public}" && ! -L "${known}" ]] || {
    printf 'Error: unsafe symlink in client profile path\n' >&2
    return 1
  }
  if [[ -e "${snippet}" ]] && ! grep -Fqx "${OWNED_HEADER}" "${snippet}"; then
    printf 'Error: refusing to replace unowned SSH snippet %s\n' "${snippet}" >&2
    return 1
  fi
  if [[ -f "${profile}" ]]; then
    existing=1
    [[ -f "${key}" && -f "${public}" && -f "${known}" ]] || {
      printf 'Error: incomplete client profile: %s\n' "${name}" >&2
      return 1
    }
    TARGET="$(sed -n 's/^TARGET=//p' "${profile}")"
    PORT="$(sed -n 's/^PORT=//p' "${profile}")"
    authorization_completed="$(sed -n 's/^AUTHORIZATION_COMPLETED=//p' "${profile}")"
    [[ -n "${authorization_completed}" ]] || authorization_completed=1
    validate_target "${TARGET}" && validate_port "${PORT}" &&
      [[ "${authorization_completed}" =~ ^[01]$ ]] || {
      printf 'Error: unsafe client profile: %s\n' "${profile}" >&2
      return 1
    }
    [[ "${TARGET}" == "${target}" && "${PORT}" == "${port}" ]] || {
      printf 'Error: client name %s already belongs to a different target\n' "${name}" >&2
      return 1
    }
  else
    mkdir -p "${dir}"; chmod 700 "${dir}"
    phase key_generate
    ssh-keygen -q -t ed25519 -N '' -C "safe_ssh:${name}" -f "${key}"
    : >"${known}"; chmod 600 "${known}" "${key}" "${public}"
    {
      printf 'TARGET=%s\nPORT=%s\nAUTHORIZATION_COMPLETED=0\n' "${target}" "${port}"
    } | write_atomic "${profile}" 600
  fi
  fingerprint="$(ssh-keygen -lf "${public}" | awk '{print $2}')"
  printf 'key_type=ssh-ed25519 key_fingerprint=%s\n' "${fingerprint}"
  if ((existing)); then
    phase dedicated_verify
    ssh_common_args "${known}"
    if ssh "${SSH_ARGS[@]}" -p "${port}" -i "${key}" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
      -o ChallengeResponseAuthentication=no -o GSSAPIAuthentication=no \
      -o HostbasedAuthentication=no -o NumberOfPasswordPrompts=0 \
      -o "HostName=${target_host}" \
      -o ControlMaster=no -o ControlPath=none \
      "${ssh_target}" true; then
      authorized=1
      authorization_completed=1
    fi
  fi
  if ((!authorized)); then
    ssh_common_args "${known}"
    SSH_ARGS+=(-p "${port}" -o "HostName=${target_host}" \
      -o ControlMaster=no -o ControlPath=none)
    [[ -z "${bootstrap}" ]] || SSH_ARGS+=(-i "${bootstrap}" -o IdentitiesOnly=yes)
    phase remote_authorize
    printf -v remote_key '%q' "$(cat "${public}")"
    remote_add_script | ssh "${SSH_ARGS[@]}" "${ssh_target}" bash -s -- "${remote_key}"
    authorization_completed=1
  fi
  if ((authorization_completed)); then
    {
      printf 'TARGET=%s\nPORT=%s\nAUTHORIZATION_COMPLETED=1\n' "${target}" "${port}"
    } | write_atomic "${profile}" 600
  fi
  if ((!authorized)); then
    phase dedicated_verify
    ssh_common_args "${known}"
    ssh "${SSH_ARGS[@]}" -p "${port}" -i "${key}" -o IdentitiesOnly=yes \
      -o BatchMode=yes -o PreferredAuthentications=publickey \
      -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no \
      -o ChallengeResponseAuthentication=no -o GSSAPIAuthentication=no \
      -o HostbasedAuthentication=no -o NumberOfPasswordPrompts=0 \
      -o "HostName=${target_host}" \
      -o ControlMaster=no -o ControlPath=none \
      "${ssh_target}" true
  fi
  {
    printf '%s\n' "${OWNED_HEADER}"
    printf 'Host safe-ssh-%s\n' "${name}"
    printf '  HostName %s\n' "${target_host}"
    printf '  User %s\n' "${target%@*}"
    printf '  Port %s\n' "${port}"
    printf '  IdentityFile %s\n' "$(ssh_config_quote "${key}")"
    printf '  IdentitiesOnly yes\n'
    printf '  ControlMaster no\n'
    printf '  ControlPath none\n'
    printf '  PreferredAuthentications publickey\n'
    printf '  PasswordAuthentication no\n'
    printf '  KbdInteractiveAuthentication no\n'
    printf '  UserKnownHostsFile %s\n' "$(ssh_config_quote "${known}")"
    printf '  GlobalKnownHostsFile /dev/null\n'
    printf '  StrictHostKeyChecking ask\n'
  } | write_atomic "${snippet}" 600
  install_include
  printf 'client %s ready as Host safe-ssh-%s\n' "${name}" "${name}"
}

load_profile() {
  local name="$1" dir
  validate_name "${name}" || return 1
  dir="$(client_root)/clients/${name}"
  [[ ! -L "${dir}" &&
     -f "${dir}/profile" && ! -L "${dir}/profile" &&
     -f "${dir}/id_ed25519" && ! -L "${dir}/id_ed25519" &&
     -f "${dir}/id_ed25519.pub" && ! -L "${dir}/id_ed25519.pub" &&
     -f "${dir}/known_hosts" && ! -L "${dir}/known_hosts" ]] || {
    printf 'Error: unknown or unsafe client: %s\n' "${name}" >&2
    return 1
  }
  TARGET=""; PORT=""; AUTHORIZATION_COMPLETED=""
  TARGET="$(sed -n 's/^TARGET=//p' "${dir}/profile")"
  PORT="$(sed -n 's/^PORT=//p' "${dir}/profile")"
  AUTHORIZATION_COMPLETED="$(sed -n 's/^AUTHORIZATION_COMPLETED=//p' "${dir}/profile")"
  [[ -n "${AUTHORIZATION_COMPLETED}" ]] || AUTHORIZATION_COMPLETED=1
  validate_target "${TARGET}" >/dev/null 2>&1 &&
    validate_port "${PORT}" >/dev/null 2>&1 &&
    [[ "${AUTHORIZATION_COMPLETED}" =~ ^[01]$ ]] || {
    printf 'Error: unsafe client profile: %s\n' "${dir}/profile" >&2
    return 1
  }
  CLIENT_DIR="${dir}"
}

client_delete() {
  local name="${2:-}" public fingerprint snippet remote_key target_host ssh_target local_only=0
  [[ -n "${name}" ]] || { usage; return 2; }
  if (($# == 3)) && [[ "${3}" == --local-only ]]; then
    local_only=1
  elif (($# != 2)); then
    usage
    return 2
  fi
  load_profile "${name}"
  target_host="${TARGET#*@}"
  target_host="${target_host#[}"
  target_host="${target_host%]}"
  ssh_target="${TARGET%@*}@${target_host}"
  snippet="$(client_root)/ssh_config.d/${name}.conf"
  if [[ -e "${snippet}" ]] &&
      { [[ ! -f "${snippet}" || -L "${snippet}" ]] ||
        ! grep -Fqx "${OWNED_HEADER}" "${snippet}"; }; then
    printf 'Error: refusing to remove unowned SSH snippet %s\n' "${snippet}" >&2
    return 1
  fi
  if ((local_only)); then
    if ((AUTHORIZATION_COMPLETED)); then
      printf 'Error: local-only deletion is allowed only when initial authorization never completed.\n' >&2
      return 1
    fi
    phase local_cleanup
    rm -f "${snippet}"
    rm -rf -- "${CLIENT_DIR}"
    remove_include_if_unused
    printf 'client %s deleted locally; remote key was not revoked.\n' "${name}"
    return
  fi
  public="$(ssh-keygen -y -f "${CLIENT_DIR}/id_ed25519")" || {
    printf 'Error: cannot derive public key from client private key; local profile retained.\n' >&2
    return 1
  }
  fingerprint="$(ssh-keygen -lf <(printf '%s\n' "${public}") | awk '{print $2}')"
  printf 'key_type=ssh-ed25519 key_fingerprint=%s\n' "${fingerprint}"
  phase remote_revoke
  ssh_common_args "${CLIENT_DIR}/known_hosts"
  printf -v remote_key '%q' "${public}"
  remote_delete_script | ssh "${SSH_ARGS[@]}" -p "${PORT}" -i "${CLIENT_DIR}/id_ed25519" \
    -o IdentitiesOnly=yes -o BatchMode=yes -o "HostName=${target_host}" \
    -o ControlMaster=no -o ControlPath=none \
    "${ssh_target}" bash -s -- "${remote_key}" || {
      printf 'Error: remote revocation failed; local profile retained.\n' >&2
      return 1
    }
  rm -f "${snippet}"
  rm -rf -- "${CLIENT_DIR}"
  remove_include_if_unused
  printf 'client %s revoked and deleted.\n' "${name}"
}

status_one() {
  local name="$1" root snippet include output effective alias hostname target_host user port identity identities_only control_master control_path preferred password kbd known global_known strict
  if ! load_profile "${name}" >/dev/null 2>&1; then
    printf '%s: missing\n' "${name}"
    return 1
  fi
  root="$(client_root)"
  snippet="${root}/ssh_config.d/${name}.conf"
  include="$(include_line)"
  if [[ ! -f "${snippet}" || -L "${snippet}" ||
        "$(head -n 1 "${snippet}" 2>/dev/null || true)" != "${OWNED_HEADER}" ||
        ! -f "${INITIATOR_HOME}/.ssh/config" ||
        "$(grep -Fxc -- "${include}" "${INITIATOR_HOME}/.ssh/config" 2>/dev/null || true)" != 1 ]]; then
    printf '%s: local-only (%s)\n' "${name}" "${TARGET}"
    return 1
  fi
  alias="safe-ssh-${name}"
  if ! effective="$(ssh -G "${alias}" 2>/dev/null)"; then
    printf '%s: local-only (%s)\n' "${name}" "${TARGET}"
    return 1
  fi
  hostname="$(awk '$1=="hostname"{print $2; exit}' <<<"${effective}")"
  user="$(awk '$1=="user"{print $2; exit}' <<<"${effective}")"
  port="$(awk '$1=="port"{print $2; exit}' <<<"${effective}")"
  identity="$(awk '$1=="identityfile"{$1=""; sub(/^ /,""); print; exit}' <<<"${effective}")"
  identities_only="$(awk '$1=="identitiesonly"{print $2; exit}' <<<"${effective}")"
  control_master="$(awk '$1=="controlmaster"{print $2; exit}' <<<"${effective}")"
  control_path="$(awk '$1=="controlpath"{$1=""; sub(/^ /,""); print; exit}' <<<"${effective}")"
  preferred="$(awk '$1=="preferredauthentications"{print $2; exit}' <<<"${effective}")"
  password="$(awk '$1=="passwordauthentication"{print $2; exit}' <<<"${effective}")"
  kbd="$(awk '$1=="kbdinteractiveauthentication"{print $2; exit}' <<<"${effective}")"
  known="$(awk '$1=="userknownhostsfile"{$1=""; sub(/^ /,""); print; exit}' <<<"${effective}")"
  global_known="$(awk '$1=="globalknownhostsfile"{$1=""; sub(/^ /,""); print; exit}' <<<"${effective}")"
  strict="$(awk '$1=="stricthostkeychecking"{print $2; exit}' <<<"${effective}")"
  target_host="${TARGET#*@}"
  target_host="${target_host#[}"
  target_host="${target_host%]}"
  if [[ "${hostname}" != "${target_host}" || "${user}" != "${TARGET%@*}" ||
        "${port}" != "${PORT}" || "${identity}" != "${CLIENT_DIR}/id_ed25519" ||
        "${identities_only}" != yes || "${control_master}" != no ||
        "${control_path}" != none || "${preferred}" != publickey ||
        "${password}" != no || "${kbd}" != no ||
        "${known}" != "${CLIENT_DIR}/known_hosts" ||
        "${global_known}" != /dev/null || "${strict}" != ask ]]; then
    printf '%s: local-only (%s)\n' "${name}" "${TARGET}"
    return 1
  fi
  if output="$(LC_ALL=C ssh -n -o BatchMode=yes -o ConnectTimeout=5 "${alias}" true 2>&1)"; then
    [[ -z "${output}" ]] || printf '%s\n' "${output}"
    printf '%s: ready (%s)\n' "${name}" "${TARGET}"
  else
    [[ -z "${output}" ]] || printf '%s\n' "${output}"
    if [[ "${output}" == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* ||
          "${output}" == *"Host key verification failed"* ]]; then
      printf '%s: host-key-error (%s)\n' "${name}" "${TARGET}"
    elif [[ "${output}" == *"Permission denied"* ]]; then
      printf '%s: unauthorized (%s)\n' "${name}" "${TARGET}"
    else
      printf '%s: unreachable (%s)\n' "${name}" "${TARGET}"
    fi
    return 1
  fi
}

client_status() {
  local name="${2:-}" root any=0 failed=0 dir
  (($# <= 2)) || { usage; return 2; }
  if [[ -n "${name}" ]]; then
    status_one "${name}"
    return
  fi
  root="$(client_root)"
  if [[ -d "${root}/clients" ]]; then
    while IFS= read -r -d '' dir; do
      any=1
      status_one "$(basename "${dir}")" || failed=1
    done < <(find "${root}/clients" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
  fi
  ((any)) || printf 'No safe_ssh clients configured.\n'
  ((failed == 0))
}

main() {
  init_log "$@"
  local command="${1:-}"
  case "${command}" in
    server_on) server_on "$@" ;;
    server_off) server_off "$@" ;;
    server_status) server_status "$@" ;;
    client_add) require_unprivileged_client; client_add "$@" ;;
    client_delete) require_unprivileged_client; client_delete "$@" ;;
    client_status) require_unprivileged_client; client_status "$@" ;;
    -h|--help|help|"") usage ;;
    *) printf 'Error: unknown command: %s\n' "${command}" >&2; usage; return 2 ;;
  esac
}

main "$@"
