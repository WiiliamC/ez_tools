#!/usr/bin/env bash

set -euo pipefail

readonly PROGRAM="safe_ssh"
readonly CONFIG_MARKER="# safe_ssh managed include"
readonly CONFIG_RESET="Host * # safe_ssh managed scope reset"
readonly OWNED_HEADER="# Managed by safe_ssh.sh; do not edit."
readonly PREPARED_MARKER="# safe_ssh state: prepared"
readonly ENABLED_MARKER="# safe_ssh state: enabled"
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
  safe_ssh.sh server_on --admin-user USER
  safe_ssh.sh server_off
  safe_ssh.sh server_status
  safe_ssh.sh client_add NAME USER@HOST [--port PORT] [--bootstrap-identity PATH]
  safe_ssh.sh client_test NAME
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

standard_authorized_keys_effective() {
  local effective="$1" auth
  auth="$(awk 'tolower($1)=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"${effective}")"
  [[ " ${auth} " == *" .ssh/authorized_keys "* ||
     " ${auth} " == *" %h/.ssh/authorized_keys "* ]]
}

standard_authorized_keys_all_contexts_effective() {
  local user="${1:-${INITIATOR_USER}}" effective context matched_status
  effective="$(sshd_effective)" || return 1
  standard_authorized_keys_effective "${effective}" || return 1
  for context in \
    "user=${user},host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22" \
    "user=${user},host=example.invalid,addr=192.0.2.1,laddr=192.0.2.2,lport=22"; do
    effective="$("${SSHD_BIN}" -T -C "${context}")" || return 1
    standard_authorized_keys_effective "${effective}" || return 1
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
  for token in ${auth_values}; do
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
  local effective="$1" pub pass kbd methods
  pub="$(awk 'tolower($1)=="pubkeyauthentication"{print tolower($2);exit}' <<<"${effective}")"
  pass="$(awk 'tolower($1)=="passwordauthentication"{print tolower($2);exit}' <<<"${effective}")"
  kbd="$(awk 'tolower($1)=="kbdinteractiveauthentication"{print tolower($2);exit}' <<<"${effective}")"
  methods="$(awk 'tolower($1)=="authenticationmethods"{$1="";sub(/^ /,"");print tolower($0);exit}' <<<"${effective}")"
  [[ "${pub}" == yes &&
     "${pass}" == no &&
     "${kbd}" == no &&
     "${methods}" == publickey ]]
}

owned_server_state() {
  [[ -f "${OWNED_SSHD_CONFIG}" && ! -L "${OWNED_SSHD_CONFIG}" ]] || return 1
  grep -Fqx "${OWNED_HEADER}" "${OWNED_SSHD_CONFIG}" || return 1
  if grep -Fqx "${ENABLED_MARKER}" "${OWNED_SSHD_CONFIG}"; then
    printf 'enabled\n'
  elif grep -Fqx "${PREPARED_MARKER}" "${OWNED_SSHD_CONFIG}"; then
    printf 'prepared\n'
  elif grep -Eiq '^[[:space:]]*PasswordAuthentication[[:space:]]+no[[:space:]]*$' "${OWNED_SSHD_CONFIG}" &&
       grep -Eiq '^[[:space:]]*KbdInteractiveAuthentication[[:space:]]+no[[:space:]]*$' "${OWNED_SSHD_CONFIG}" &&
       grep -Eiq '^[[:space:]]*AuthenticationMethods[[:space:]]+publickey[[:space:]]*$' "${OWNED_SSHD_CONFIG}" &&
       grep -Eiq '^[[:space:]]*PubkeyAuthentication[[:space:]]+yes[[:space:]]*$' "${OWNED_SSHD_CONFIG}"; then
    printf 'enabled\n'
  else
    printf 'unknown\n'
  fi
}

sshd_service_active() {
  "${SYSTEMCTL_BIN}" is-active --quiet ssh.service 2>/dev/null ||
    "${SYSTEMCTL_BIN}" is-active --quiet sshd.service 2>/dev/null
}

server_on() {
  require_root server_on
  ensure_server_scope
  local admin="" owned_state
  shift
  while (($#)); do
    case "$1" in
      --admin-user) (($# >= 2)) || { printf 'Error: --admin-user needs USER\n' >&2; return 2; }; admin="$2"; shift 2 ;;
      *) printf 'Error: unknown server_on option: %s\n' "$1" >&2; return 2 ;;
    esac
  done
  [[ -n "${admin}" ]] || { printf 'Error: --admin-user USER is required\n' >&2; return 2; }
  owned_state=""
  if [[ -e "${OWNED_SSHD_CONFIG}" || -L "${OWNED_SSHD_CONFIG}" ]]; then
    owned_state="$(owned_server_state 2>/dev/null)" || {
      printf 'Error: refusing to replace unowned file %s\n' "${OWNED_SSHD_CONFIG}" >&2
      return 1
    }
  fi
  if [[ -n "${owned_state}" ]]; then
    if [[ "${owned_state}" == enabled ]] &&
       ! grep -Eiq '^[[:space:]]*AuthorizedKeysFile[[:space:]]+' "${OWNED_SSHD_CONFIG}"; then
      if sshd_service_active && server_policy_all_contexts_effective "${admin}"; then
        printf 'safe_ssh server policy is already enabled.\n'
        return 0
      fi
      printf 'Error: owned enabled policy is not effective; inspect server_status before changing it\n' >&2
      return 1
    fi
    printf 'Error: legacy safe_ssh drop-in detected; run server_off before server_on\n' >&2
    return 1
  fi
  phase server_baseline
  standard_authorized_keys_all_contexts_effective "${admin}" || {
    printf 'Error: standard .ssh/authorized_keys is not effective for %s; refusing possible lockout\n' "${admin}" >&2
    return 1
  }
  admin_has_key "${admin}" ".ssh/authorized_keys" || {
    printf 'Error: %s has no usable unconditional key in .ssh/authorized_keys; refusing possible lockout\n' "${admin}" >&2
    return 1
  }
  phase server_login_probe
  admin_login_probe "${admin}" || {
    printf 'Error: public-key login probe for %s failed; refusing possible lockout\n' "${admin}" >&2
    return 1
  }
  phase server_write
  {
    printf '%s\n%s\n' "${OWNED_HEADER}" "${ENABLED_MARKER}"
    printf 'PubkeyAuthentication yes\n'
    printf 'PasswordAuthentication no\n'
    printf 'KbdInteractiveAuthentication no\n'
    printf 'ChallengeResponseAuthentication no\n'
    printf 'AuthenticationMethods publickey\n'
  } | write_atomic "${OWNED_SSHD_CONFIG}" 644
  phase server_validate
  if ! "${SSHD_BIN}" -t; then
    phase rollback
    rm -f "${OWNED_SSHD_CONFIG}"
    return 1
  fi
  if ! server_policy_all_contexts_effective "${admin}"; then
    printf 'Error: safe_ssh policy is not effective in all checked SSH connection contexts; check Include ordering and Match blocks\n' >&2
    phase rollback
    rm -f "${OWNED_SSHD_CONFIG}"
    return 1
  fi
  phase server_reload
  if ! reload_sshd; then
    phase rollback
    rm -f "${OWNED_SSHD_CONFIG}"
    "${SSHD_BIN}" -t && reload_sshd || true
    return 1
  fi
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
  local effective pub pass kbd methods auth owned=no owned_state="" service=inactive state=disabled
  effective="$(sshd_effective)" || { printf 'server: unavailable\n'; return 1; }
  pub="$(awk 'tolower($1)=="pubkeyauthentication"{print tolower($2);exit}' <<<"${effective}")"
  pass="$(awk 'tolower($1)=="passwordauthentication"{print tolower($2);exit}' <<<"${effective}")"
  kbd="$(awk 'tolower($1)=="kbdinteractiveauthentication"{print tolower($2);exit}' <<<"${effective}")"
  methods="$(awk 'tolower($1)=="authenticationmethods"{$1="";sub(/^ /,"");print tolower($0);exit}' <<<"${effective}")"
  auth="$(awk 'tolower($1)=="authorizedkeysfile"{$1="";sub(/^ /,"");print;exit}' <<<"${effective}")"
  owned_state="$(owned_server_state 2>/dev/null || true)"
  [[ -n "${owned_state}" ]] && owned=yes
  sshd_service_active && service=active
  if [[ -n "${owned_state}" ]] &&
       grep -Eiq '^[[:space:]]*AuthorizedKeysFile[[:space:]]+' "${OWNED_SSHD_CONFIG}"; then
      state=legacy
  elif [[ "${owned_state}" == prepared ]]; then
      state=legacy
  elif [[ "${owned_state}" == enabled && "${service}" == active ]] &&
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

ssh_config_tokens() {
  /usr/bin/python3 -c '
import shlex
import sys
lexer = shlex.shlex(sys.argv[1], posix=True)
lexer.whitespace_split = True
lexer.commenters = "#"
for token in lexer:
    print(token)
' "$1"
}

render_client_snippet() {
  local name="$1" target="$2" port="$3" key="$4" known="$5"
  local host="${6:-${name}}" target_host user
  target_host="${target#*@}"; target_host="${target_host#[}"; target_host="${target_host%]}"
  user="${target%@*}"
  printf '%s\n' "${OWNED_HEADER}"
  printf 'Host %s\n' "${host}"
  printf '  HostName %s\n' "${target_host}"
  printf '  User %s\n' "${user}"
  printf '  Port %s\n' "${port}"
  printf '  IdentityFile %s\n' "$(ssh_config_quote "${key}")"
  printf '%s\n' '  IdentitiesOnly yes' '  ControlMaster no' '  ControlPath none'
  printf '%s\n' '  PreferredAuthentications publickey' '  PasswordAuthentication no'
  printf '%s\n' '  KbdInteractiveAuthentication no'
  printf '  UserKnownHostsFile %s\n' "$(ssh_config_quote "${known}")"
  printf '%s\n' '  GlobalKnownHostsFile /dev/null' '  StrictHostKeyChecking ask'
}

# Return success when NAME is already an explicit Host token in the user's
# config (including files reached via Include).  This deliberately examines
# only the per-user configuration tree, never the system ssh_config.
ssh_config_host_collision() {
  local name="$1" config scan_status
  CLIENT_HOST_COLLISION_SOURCE=""
  SSH_CONFIG_SCAN_UNSUPPORTED=""
  SSH_CONFIG_HOST_ACTIVE=1
  SSH_CONFIG_MATCH_CONTEXT=0
  config="${INITIATOR_HOME}/.ssh/config"
  [[ -f "${config}" && ! -L "${config}" ]] || return 1
  declare -gA ACTIVE_SSH_CONFIGS=()
  if scan_ssh_config_for_host "${config}" "${name}"; then
    return 0
  else
    scan_status=$?
  fi
  if [[ -n "${SSH_CONFIG_SCAN_UNSUPPORTED}" ]]; then
    printf 'Error: %s\n' "${SSH_CONFIG_SCAN_UNSUPPORTED}" >&2
    return 2
  fi
  return "${scan_status}"
}

host_patterns_match() {
  local name="$1" token pattern positive=0 matched=0
  shift
  shopt -s nocasematch
  for token in "$@"; do
    if [[ "${token}" == \!* ]]; then
      pattern="${token#!}"
      [[ "${name}" == ${pattern} ]] && { shopt -u nocasematch; return 1; }
    else
      positive=1
      [[ "${name}" == ${token} ]] && matched=1
    fi
  done
  shopt -u nocasematch
  ((positive && matched))
}

owned_snippet_for_name() {
  local file="$1" name="$2" expected profile target port key known
  expected="$(client_root)/ssh_config.d/${name}.conf"
  profile="$(client_root)/clients/${name}/profile"
  [[ "${file}" == "${expected}" && ! -L "${file}" && -f "${profile}" && ! -L "${profile}" ]] || return 1
  target="$(sed -n 's/^TARGET=//p' "${profile}")"
  port="$(sed -n 's/^PORT=//p' "${profile}")"
  validate_target "${target}" >/dev/null 2>&1 && validate_port "${port}" >/dev/null 2>&1 || return 1
  key="$(client_root)/clients/${name}/id_ed25519"
  known="$(client_root)/clients/${name}/known_hosts"
  cmp -s <(render_client_snippet "${name}" "${target}" "${port}" "${key}" "${known}") "${file}" ||
    cmp -s <(render_client_snippet "${name}" "${target}" "${port}" "${key}" "${known}" \
      "safe-ssh-${name}") "${file}"
}

expand_ssh_include_path() {
  local path="$1" user record home suffix=""
  case "${path}" in
    "~")
      printf '%s\n' "${INITIATOR_HOME}"
      ;;
    "~/"*)
      printf '%s/%s\n' "${INITIATOR_HOME}" "${path#\~/}"
      ;;
    "~"*)
      user="${path#\~}"
      if [[ "${user}" == */* ]]; then
        suffix="/${user#*/}"
        user="${user%%/*}"
      fi
      record="$(passwd_record "${user}" 2>/dev/null)" || return 1
      IFS=: read -r _ _ _ _ _ home _ <<<"${record}"
      [[ "${home}" == /* ]] || return 1
      printf '%s%s\n' "${home}" "${suffix}"
      ;;
    /*)
      printf '%s\n' "${path}"
      ;;
    *)
      printf '%s/.ssh/%s\n' "${INITIATOR_HOME}" "${path}"
      ;;
  esac
}

scan_ssh_config_for_host() {
  local file="$1" name="$2" canonical line keyword remainder token include_path candidate
  local -a tokens
  canonical="$(readlink -f -- "${file}" 2>/dev/null || true)"
  [[ -n "${canonical}" && -f "${canonical}" ]] || return 1
  [[ -z "${ACTIVE_SSH_CONFIGS[${canonical}]:-}" ]] || return 1
  ACTIVE_SSH_CONFIGS["${canonical}"]=1
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    if [[ "${line}" =~ ^([[:alnum:]_]+)[[:space:]]*(=)?[[:space:]]*(.*)$ ]]; then
      keyword="${BASH_REMATCH[1]}"
      remainder="${BASH_REMATCH[3]}"
    else
      continue
    fi
    case "${keyword,,}" in
      host)
        mapfile -t tokens < <(ssh_config_tokens "${remainder}")
        for token in "${tokens[@]}"; do
          [[ "${token}" == \!* || "${token}" == *\* || "${token}" == *\? ]] && continue
          if [[ "${token,,}" == "${name,,}" ]] &&
              ! owned_snippet_for_name "${file}" "${name}"; then
            CLIENT_HOST_COLLISION_SOURCE="${file}"
            unset 'ACTIVE_SSH_CONFIGS['"${canonical}"']'
            return 0
          fi
        done
        if host_patterns_match "${name}" "${tokens[@]}"; then
          SSH_CONFIG_HOST_ACTIVE=1
        else
          SSH_CONFIG_HOST_ACTIVE=0
        fi
        ;;
      include)
        if ((SSH_CONFIG_MATCH_CONTEXT)); then
          printf -v SSH_CONFIG_SCAN_UNSUPPORTED \
            'cannot safely inspect SSH Match block in %s' "${file}"
          unset 'ACTIVE_SSH_CONFIGS['"${canonical}"']'
          return 1
        fi
        ((SSH_CONFIG_HOST_ACTIVE)) || continue
        mapfile -t tokens < <(ssh_config_tokens "${remainder}")
        for include_path in "${tokens[@]}"; do
          if ! include_path="$(expand_ssh_include_path "${include_path}")"; then
            printf -v SSH_CONFIG_SCAN_UNSUPPORTED \
              'cannot resolve SSH Include path in %s' "${file}"
            unset 'ACTIVE_SSH_CONFIGS['"${canonical}"']'
            return 1
          fi
          while IFS= read -r candidate; do
            if scan_ssh_config_for_host "${candidate}" "${name}"; then
              unset 'ACTIVE_SSH_CONFIGS['"${canonical}"']'
              return 0
            fi
            if [[ -n "${SSH_CONFIG_SCAN_UNSUPPORTED}" ]]; then
              unset 'ACTIVE_SSH_CONFIGS['"${canonical}"']'
              return 1
            fi
          done < <(compgen -G "${include_path}" | sort)
        done
        ;;
      match)
        SSH_CONFIG_MATCH_CONTEXT=1
        SSH_CONFIG_HOST_ACTIVE=0
        ;;
    esac
    [[ "${keyword,,}" == host ]] && SSH_CONFIG_MATCH_CONTEXT=0
  done <"${file}"
  unset 'ACTIVE_SSH_CONFIGS['"${canonical}"']'
  return 1
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
safe_dir() {
  [ ! -L "$1" ] && [ -d "$1" ] && [ -O "$1" ]
  chmod 700 "$1"
  mode=$(stat -c %a -- "$1")
  [ $((8#$mode & 8#022)) -eq 0 ]
}
reserve_backup() {
  suffix=$1
  stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    reserved="$backup_dir/authorized_keys-$stamp-$attempt.$suffix"
    if (umask 077; set -C; : >"$reserved") 2>/dev/null; then
      printf '%s\n' "$reserved"
      return 0
    fi
    attempt=$((attempt + 1))
  done
  return 1
}
ssh_dir="$HOME/.ssh"
[ ! -L "$ssh_dir" ]
mkdir -p "$ssh_dir"
safe_dir "$ssh_dir"
file="$ssh_dir/authorized_keys"
lock="$ssh_dir/.authorized_keys.safe_ssh.lock"
[ ! -L "$lock" ]
: >>"$lock"
[ -f "$lock" ] && [ -O "$lock" ]
chmod 600 "$lock"
exec 9<>"$lock"
flock -x 9
[ ! -L "$file" ]
[ ! -e "$file" ] || { [ -f "$file" ] && [ -O "$file" ]; }
if [ -e "$file" ]; then
  mode=$(stat -c %a -- "$file")
  [ $((8#$mode & 8#022)) -eq 0 ]
fi
source=$(mktemp "$ssh_dir/.authorized_keys.safe_ssh.source.XXXXXX")
tmp=
trap '[ -z "$source" ] || rm -f "$source"; [ -z "$tmp" ] || rm -f "$tmp"' EXIT HUP INT TERM
had_file=0
if [ -e "$file" ]; then
  cat "$file" >"$source"
  had_file=1
fi
if [ "$had_file" -eq 1 ] && grep -Fqx -- "$key" "$source"; then
  exit 0
fi
key_type=$(printf '%s\n' "$key" | awk '{print $1}')
key_blob=$(printf '%s\n' "$key" | awk '{print $2}')
if [ "$had_file" -eq 1 ] && awk -v type="$key_type" -v blob="$key_blob" '
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
  matching_key($0) {found=1}
  END {exit found ? 0 : 1}
' "$source"; then
  printf 'Error: public key is already authorized with different options or comment\n' >&2
  exit 1
fi
backup_dir="$HOME/.safe_ssh/backup"
[ ! -L "$HOME/.safe_ssh" ]
mkdir -p "$backup_dir"
safe_dir "$HOME/.safe_ssh"
safe_dir "$backup_dir"
if [ "$had_file" -eq 1 ]; then
  backup=$(reserve_backup bak) || exit 1
  cat "$source" >"$backup" && chmod 600 "$backup" || { rm -f "$backup"; exit 1; }
else
  marker=$(reserve_backup absent) || exit 1
  chmod 600 "$marker" || { rm -f "$marker"; exit 1; }
fi
tmp=$(mktemp "$ssh_dir/.authorized_keys.safe_ssh.XXXXXX")
if [ "$had_file" -eq 1 ]; then
  {
    cat "$source"
    if [ -s "$source" ] && ! tail -c 1 -- "$source" | grep -q '^$'; then
      printf '\n'
    fi
    printf '%s\n' "$key"
  } >"$tmp"
else
  printf '%s\n' "$key" >"$tmp"
fi
chmod 600 "$tmp"
if [ "$had_file" -eq 1 ]; then
  [ ! -L "$file" ] && [ -f "$file" ] && [ -O "$file" ] && cmp -s "$source" "$file"
else
  [ ! -e "$file" ]
fi
mv "$tmp" "$file"
tmp=
rm -f "$source"
source=
trap - EXIT HUP INT TERM
REMOTE
}

remote_delete_script() {
  cat <<'REMOTE'
set -eu
key=$1
key_type=$(printf '%s\n' "$key" | awk '{print $1}')
key_blob=$(printf '%s\n' "$key" | awk '{print $2}')
ssh_dir="$HOME/.ssh"
[ -e "$ssh_dir" ] || exit 0
[ ! -L "$ssh_dir" ] && [ -d "$ssh_dir" ] && [ -O "$ssh_dir" ]
chmod 700 "$ssh_dir"
mode=$(stat -c %a -- "$ssh_dir")
[ $((8#$mode & 8#022)) -eq 0 ]
file="$ssh_dir/authorized_keys"
lock="$ssh_dir/.authorized_keys.safe_ssh.lock"
[ ! -L "$lock" ]
: >>"$lock"
[ -f "$lock" ] && [ -O "$lock" ]
chmod 600 "$lock"
exec 9<>"$lock"
flock -x 9
[ ! -L "$file" ]
[ -f "$file" ] || exit 0
[ -O "$file" ]
mode=$(stat -c %a -- "$file")
[ $((8#$mode & 8#022)) -eq 0 ]
source=$(mktemp "$ssh_dir/.authorized_keys.safe_ssh.source.XXXXXX")
tmp=$(mktemp "$ssh_dir/.authorized_keys.safe_ssh.XXXXXX")
trap '[ -z "$source" ] || rm -f "$source"; [ -z "$tmp" ] || rm -f "$tmp"' EXIT HUP INT TERM
cat "$file" >"$source"
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
' "$source" >"$tmp"
if cmp -s "$source" "$tmp"; then
  exit 0
fi
backup_dir="$HOME/.safe_ssh/backup"
[ ! -L "$HOME/.safe_ssh" ]
mkdir -p "$backup_dir"
[ ! -L "$backup_dir" ] && [ -d "$backup_dir" ] && [ -O "$HOME/.safe_ssh" ] && [ -O "$backup_dir" ]
chmod 700 "$HOME/.safe_ssh" "$backup_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
attempt=0
while [ "$attempt" -lt 100 ]; do
  backup="$backup_dir/authorized_keys-$stamp-$attempt.bak"
  if (umask 077; set -C; : >"$backup") 2>/dev/null; then
    break
  fi
  backup=
  attempt=$((attempt + 1))
done
[ -n "$backup" ] || exit 1
cat "$source" >"$backup" && chmod 600 "$backup" || { rm -f "$backup"; exit 1; }
chmod 600 "$tmp"
[ ! -L "$file" ] && [ -f "$file" ] && [ -O "$file" ] && cmp -s "$source" "$file"
mv "$tmp" "$file"
tmp=
rm -f "$source"
source=
trap - EXIT HUP INT TERM
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
  local name="${2:-}" target="${3:-}" port=22 bootstrap="" root dir profile key public fingerprint known snippet remote_key target_host ssh_target authorization_completed=0 collision_status
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
  if ssh_config_host_collision "${name}"; then
    printf 'Error: client name %s conflicts with explicit Host in %s\n' \
      "${name}" "${CLIENT_HOST_COLLISION_SOURCE}" >&2
    return 1
  else
    collision_status=$?
    ((collision_status == 2)) && return 1
  fi
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
  ssh_common_args "${known}"
  SSH_ARGS+=(-p "${port}" -o "HostName=${target_host}" \
    -o ControlMaster=no -o ControlPath=none)
  if [[ -n "${bootstrap}" ]]; then
    SSH_ARGS+=(-i "${bootstrap}" -o IdentitiesOnly=yes)
  else
    SSH_ARGS+=(-i "${key}")
  fi
  phase remote_authorize
  printf -v remote_key '%q' "$(cat "${public}")"
  remote_add_script | ssh "${SSH_ARGS[@]}" "${ssh_target}" bash -s -- "${remote_key}"
  authorization_completed=1
  if ((authorization_completed)); then
    {
      printf 'TARGET=%s\nPORT=%s\nAUTHORIZATION_COMPLETED=1\n' "${target}" "${port}"
    } | write_atomic "${profile}" 600
  fi
  render_client_snippet "${name}" "${target}" "${port}" "${key}" "${known}" |
    write_atomic "${snippet}" 600
  install_include
  printf 'client %s configured as Host %s\n' "${name}" "${name}"
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

strict_client_probe() {
  local target_host ssh_target
  target_host="${TARGET#*@}"
  target_host="${target_host#[}"
  target_host="${target_host%]}"
  ssh_target="${TARGET%@*}@${target_host}"
  LC_ALL=C ssh -n -F /dev/null \
    -p "${PORT}" -i "${CLIENT_DIR}/id_ed25519" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o ChallengeResponseAuthentication=no \
    -o GSSAPIAuthentication=no \
    -o HostbasedAuthentication=no \
    -o NumberOfPasswordPrompts=0 \
    -o ConnectTimeout=5 \
    -o "UserKnownHostsFile=${CLIENT_DIR}/known_hosts" \
    -o StrictHostKeyChecking=ask \
    -o GlobalKnownHostsFile=/dev/null \
    -o "HostName=${target_host}" \
    -o ControlMaster=no \
    -o ControlPath=none \
    "${ssh_target}" true
}

client_test() {
  local name="${2:-}" output
  (($# == 2)) && [[ -n "${name}" ]] || { usage; return 2; }
  load_profile "${name}" || return 1
  phase dedicated_test
  if output="$(strict_client_probe 2>&1)"; then
    [[ -z "${output}" ]] || printf '%s\n' "${output}"
    printf 'client %s connection verified.\n' "${name}"
  else
    [[ -z "${output}" ]] || printf '%s\n' "${output}" >&2
    return 1
  fi
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
  alias="${name}"
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
  case "${control_master}" in
    false|no) control_master=no ;;
  esac
  case "${control_path}" in
    "") control_path=none ;;
  esac
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
  if output="$(strict_client_probe 2>&1)"; then
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
    client_test) require_unprivileged_client; client_test "$@" ;;
    client_delete) require_unprivileged_client; client_delete "$@" ;;
    client_status) require_unprivileged_client; client_status "$@" ;;
    -h|--help|help|"") usage ;;
    *) printf 'Error: unknown command: %s\n' "${command}" >&2; usage; return 2 ;;
  esac
}

main "$@"
