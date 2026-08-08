#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/safe_ssh.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || fail "expected '$2' in: $1"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

[[ -x "${script}" ]] || fail "safe_ssh.sh must exist and be executable"

home="${tmp_dir}/home"
mkdir -p "${home}" "${tmp_dir}/bin"
chmod 700 "${home}"
cat >"${tmp_dir}/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '%s:x:%s:%s::%s:/bin/bash\n' "$2" "$(id -u)" "$(id -g)" "${TEST_HOME}"
EOF
cat >"${tmp_dir}/bin/sshd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TEST_SSHD_CALLS}"
debug_printf() {
  if [[ "${TEST_SSHD_DEBUG_LF_ONLY:-0}" == 1 ]]; then
    printf '%s\n' "$*" >&2
  else
    printf '%s\r\n' "$*" >&2
  fi
}
if [[ "$1" == -T ]]; then
  if [[ " $* " == *" -ddd "* ]]; then
    [[ "${TEST_SSHD_FAIL_DEBUG:-0}" != 1 ]] || exit 1
    if [[ "${TEST_SSHD_DEBUG_NO_FILES:-0}" != 1 ]]; then
      debug_printf "debug2: load_server_config: filename ${TEST_SSHD_CONFIG}"
      while IFS= read -r file; do
        debug_printf "debug2: load_server_config: filename ${file}"
      done < <(find -L "${TEST_SSHD_DIR}" -type f | sort)
      if [[ -n "${TEST_SSHD_EXTRA_CONFIG:-}" ]]; then
        debug_printf "debug2: load_server_config: filename ${TEST_SSHD_EXTRA_CONFIG}"
      fi
    fi
  fi
  if [[ " $* " != *" -C "* && " $* " != *" -ddd "* &&
        "${TEST_SSHD_FAIL_EFFECTIVE_DEFAULT:-0}" == 1 ]]; then
    exit 1
  fi
  if [[ " $* " == *" -C "* && "$*" == *"host=example.invalid"* &&
        "${TEST_SSHD_FAIL_EFFECTIVE_REMOTE:-0}" == 1 ]]; then
    exit 1
  fi
  printf 'pubkeyauthentication yes\n'
  if [[ -f "${TEST_SSHD_DIR}/00-safe-ssh.conf" &&
        "${TEST_SSHD_IGNORE_DROPIN:-0}" != 1 ]]; then
    password="$(awk 'tolower($1)=="passwordauthentication"{print tolower($2);exit}' "${TEST_SSHD_DIR}/00-safe-ssh.conf")"
    kbd="$(awk 'tolower($1)=="kbdinteractiveauthentication"{print tolower($2);exit}' "${TEST_SSHD_DIR}/00-safe-ssh.conf")"
    methods="$(awk 'tolower($1)=="authenticationmethods"{$1="";sub(/^ /,"");print tolower($0);exit}' "${TEST_SSHD_DIR}/00-safe-ssh.conf")"
    if [[ "${TEST_SSHD_MATCH_WEAK:-0}" == 1 && " $* " == *" -C "* ]]; then
      password=yes
      kbd=yes
    fi
    printf 'passwordauthentication %s\n' "${password:-yes}"
    printf 'kbdinteractiveauthentication %s\n' "${kbd:-yes}"
    printf 'authenticationmethods %s\n' "${methods:-any}"
    awk 'tolower($1)=="authorizedkeysfile"{print tolower($0)}' "${TEST_SSHD_DIR}/00-safe-ssh.conf"
  else
    printf 'passwordauthentication yes\nkbdinteractiveauthentication yes\n'
    printf 'authenticationmethods any\n'
    if [[ "${TEST_SSHD_NONSTANDARD_AUTH:-0}" == 1 ]]; then
      printf 'authorizedkeysfile .ssh/custom_keys\n'
    else
      printf 'authorizedkeysfile .ssh/authorized_keys .ssh/custom_keys\n'
    fi
  fi
elif [[ "$1" == -t ]]; then
  [[ "${TEST_SSHD_FAIL_VALIDATE:-0}" != 1 ]]
elif [[ "$1" == -V ]]; then
  printf 'OpenSSH_9.6p1\n' >&2
  exit "${TEST_SSHD_VERSION_EXIT:-0}"
fi
EOF
cat >"${tmp_dir}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${TEST_SYSTEMCTL_CALLS}"
if [[ "$*" == "is-active --quiet ssh.service" || "$*" == "is-active --quiet sshd.service" ]]; then
  [[ "${TEST_SYSTEMCTL_INACTIVE:-0}" != 1 ]]
  exit
fi
[[ "${TEST_SYSTEMCTL_FAIL:-0}" != 1 ]]
EOF
cat >"${tmp_dir}/bin/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == -lf ]]; then
  [[ "$(cat "$2")" != *"ssh-ed25519 garbage"* ]] || exit 1
  printf '256 SHA256:focused-fingerprint safe_ssh (ED25519)\n'
  exit 0
fi
if [[ "$1" == -y && "$2" == -f ]]; then
  name="$(basename "$(dirname "$3")")"
  printf 'ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_%s\n' "${name}"
  exit 0
fi
file=""
while (($#)); do
  if [[ "$1" == -f ]]; then file="$2"; shift 2; else shift; fi
done
printf '%s\n' 'PRIVATE-KEY-MUST-NOT-BE-LOGGED' >"${file}"
name="$(basename "$(dirname "${file}")")"
printf 'ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_%s safe_ssh:%s\n' \
  "${name}" "${name}" >"${file}.pub"
EOF
cat >"${tmp_dir}/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"${TEST_SSH_CALLS}"
printf '\n' >>"${TEST_SSH_CALLS}"
if [[ " $* " == *" PreferredAuthentications=publickey "* &&
      ( "${TEST_CLIENT_TEST_FAIL:-0}" == 1 ||
        "${TEST_SSH_LOGIN_PROBE_FAIL:-0}" == 1 ) ]]; then
  exit 255
fi
if [[ "${1:-}" == -G ]]; then
  name="$2"
  snippet="${XDG_CONFIG_HOME}/safe_ssh/ssh_config.d/${name}.conf"
  awk '
    function value() {
      $1=""
      sub(/^ /, "")
      if (substr($0, 1, 1) == "\"" && substr($0, length($0), 1) == "\"") {
        return substr($0, 2, length($0) - 2)
      }
      return $0
    }
    $1=="HostName" {print "hostname " $2}
    $1=="User" {print "user " $2}
    $1=="Port" {print "port " $2}
    $1=="IdentityFile" {print "identityfile " value()}
    $1=="IdentitiesOnly" {print "identitiesonly " tolower($2)}
    $1=="ControlMaster" {
      setting=tolower($2)
      if (ENVIRON["TEST_SSH_G_LITERAL_DISABLED"] != "1" && setting=="no") {
        setting="false"
      }
      print "controlmaster " setting
    }
    $1=="ControlPath" {
      setting=value()
      if (ENVIRON["TEST_SSH_G_LITERAL_DISABLED"] == "1" ||
          tolower(setting)!="none") {
        print "controlpath " setting
      }
    }
    $1=="PreferredAuthentications" {print "preferredauthentications " tolower($2)}
    $1=="PasswordAuthentication" {print "passwordauthentication " tolower($2)}
    $1=="KbdInteractiveAuthentication" {print "kbdinteractiveauthentication " tolower($2)}
    $1=="UserKnownHostsFile" {print "userknownhostsfile " value()}
    $1=="GlobalKnownHostsFile" {print "globalknownhostsfile " value()}
    $1=="StrictHostKeyChecking" {print "stricthostkeychecking " tolower($2)}
  ' "${snippet}"
  exit
fi
if [[ " $* " == *" -n "* && "${TEST_SSH_LOCALE_PROBE:-0}" == 1 ]]; then
  if [[ "${LC_ALL:-}" == C ]]; then
    printf 'Permission denied (publickey).\n' >&2
  else
    printf '权限被拒绝 (publickey).\n' >&2
  fi
  exit 255
fi
script_body=""
[[ " $* " == *" -n "* ]] || script_body="$(cat)"
if [[ "$*" == *"bash -s --"* && "${TEST_SSH_DELETE_FAIL:-0}" == 1 &&
      "${script_body}" == *'key_blob='* ]]; then
  exit 23
fi
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[i]}" == bash && "${args[i+1]:-}" == -s ]]; then
    remote_command="${args[*]:i}"
    HOME="${TEST_REMOTE_HOME}" bash -c "${remote_command}" <<<"${script_body}"
    exit
  fi
done
EOF
chmod +x "${tmp_dir}/bin/"*

export TEST_HOME="${home}"
export TEST_SSHD_DIR="${tmp_dir}/sshd_config.d"
export TEST_SSHD_CONFIG="${tmp_dir}/sshd_config"
export TEST_SYSTEMCTL_CALLS="${tmp_dir}/systemctl.calls"
export TEST_SSH_CALLS="${tmp_dir}/ssh.calls"
export TEST_SSHD_CALLS="${tmp_dir}/sshd.calls"
export TEST_REMOTE_HOME="${tmp_dir}/remote-home"
export SAFE_SSH_TESTING=1
export SAFE_SSH_GETENT="${tmp_dir}/bin/getent"
export SAFE_SSH_SSHD="${tmp_dir}/bin/sshd"
export SAFE_SSH_SSH="${tmp_dir}/bin/ssh"
export SAFE_SSH_SYSTEMCTL="${tmp_dir}/bin/systemctl"
export SAFE_SSH_SSHD_CONFIG_DIR="${TEST_SSHD_DIR}"
export SAFE_SSH_SSHD_CONFIG="${TEST_SSHD_CONFIG}"
export PATH="${tmp_dir}/bin:${PATH}"
export HOME="${home}"
export XDG_CONFIG_HOME="${home}/.config"
mkdir -p "${TEST_REMOTE_HOME}"
: >"${TEST_SSH_CALLS}"
printf 'Include %s/*.conf\n' "${TEST_SSHD_DIR}" >"${TEST_SSHD_CONFIG}"

# Executable injection hooks exist only behind the non-root test boundary.
if grep -Fq '${SAFE_SSH_PYTHON3' "${script}"; then
  fail "SAFE_SSH_PYTHON3 executable override remains"
fi
assert_file_contains "${script}" '[[ "${SAFE_SSH_TESTING:-}" == 1 && "${EUID}" != 0 ]]'

# Every invocation initializes a private log before command work.
"${script}" client_status >/dev/null
[[ "$(stat -c %a "${home}/.safe_ssh/logs")" == 700 ]] || fail "unsafe log directory mode"
log="$(find "${home}/.safe_ssh/logs" -type f -print -quit)"
[[ -n "${log}" && "$(stat -c %a "${log}")" == 600 ]] || fail "unsafe log file mode"
[[ "$(stat -c %u "${log}")" == "$(id -u)" ]] || fail "wrong log owner"
assert_file_contains "${log}" "subcommand=client_status"

# Caller-supplied internal logging state is rejected rather than trusted.
set +e
SAFE_SSH_LOG_FD=1 SAFE_SSH_LOG_FILE="${tmp_dir}/forged.log" \
  SAFE_SSH_LOG_TIMESTAMP=20000101T000000Z \
  "${script}" client_status >/dev/null 2>&1
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "caller-supplied logging state was accepted"

# Logging refuses a symlinked directory without changing its target.
symlink_home="${tmp_dir}/symlink-home"
symlink_target="${tmp_dir}/symlink-target"
mkdir -p "${symlink_home}" "${symlink_target}"
chmod 755 "${symlink_target}"
ln -s "${symlink_target}" "${symlink_home}/.safe_ssh"
set +e
TEST_HOME="${symlink_home}" HOME="${symlink_home}" "${script}" client_status >/dev/null 2>&1
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "symlinked log directory was accepted"
[[ "$(stat -c %a "${symlink_target}")" == 755 ]] ||
  fail "symlink target mode was changed"

# Server hardening is optional and never rewrites AuthorizedKeysFile.  Old
# managed drop-ins are reported as legacy and must be removed explicitly.
mkdir -p "${TEST_SSHD_DIR}"
printf 'leave me\n' >"${TEST_SSHD_DIR}/90-unrelated.conf"
set +e
"${script}" server_prepare >/dev/null 2>&1
status=$?
set -e
[[ "${status}" == 2 ]] || fail "removed server_prepare remained available"
set +e
status_output="$(SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=1000 "${script}" server_status)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "unprivileged server_status was accepted"
assert_contains "${status_output}" "server_status requires root"
set +e
status_output="$(SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_status)"
set -e
assert_contains "${status_output}" "server: disabled"

# server_on takes no arguments, including the removed --admin-user option.
reload_calls_before="$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)"
set +e
SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on --admin-user tester >/dev/null
status=$?
set -e
[[ "${status}" == 2 ]] || fail "server_on argument did not return usage error 2"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
  fail "argument error created a server drop-in"
[[ "$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)" == "${reload_calls_before}" ]] ||
  fail "argument error changed service state"

# An existing unowned drop-in must never be overwritten.
printf 'PasswordAuthentication yes\n' >"${TEST_SSHD_DIR}/00-safe-ssh.conf"
unowned_checksum="$(sha256sum "${TEST_SSHD_DIR}/00-safe-ssh.conf")"
set +e
SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on </dev/null >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on accepted an unowned drop-in"
[[ "$(sha256sum "${TEST_SSHD_DIR}/00-safe-ssh.conf")" == "${unowned_checksum}" ]] ||
  fail "server_on overwrote an unowned drop-in"
rm "${TEST_SSHD_DIR}/00-safe-ssh.conf"

# First enable requires exact lowercase y. Every other response, including EOF,
# cancels without writing configuration or touching the service.
for response in n yes Y ""; do
  reload_calls_before="$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)"
  set +e
  warning="$(printf '%s\n' "${response}" |
    SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_on 2>&1)"
  status=$?
  set -e
  [[ "${status}" -ne 0 ]] || fail "server_on accepted confirmation '${response}'"
  [[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
    fail "cancelled server_on wrote a drop-in for '${response}'"
  [[ "$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)" == "${reload_calls_before}" ]] ||
    fail "cancelled server_on touched the service for '${response}'"
done
reload_calls_before="$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)"
set +e
warning="$(SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on </dev/null 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on accepted EOF confirmation"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
  fail "EOF-cancelled server_on wrote a drop-in"
[[ "$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)" == "${reload_calls_before}" ]] ||
  fail "EOF-cancelled server_on touched the service"
assert_contains "${warning}" "client public-key-only login test"
assert_contains "${warning}" "Password and keyboard-interactive authentication will be disabled"
assert_contains "${warning}" "lock you out"

# Login readiness is the operator's responsibility: server_on neither invokes
# ssh nor depends on AuthorizedKeysFile or local key files.
ssh_calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
printf 'y\n' | TEST_SSHD_NONSTANDARD_AUTH=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on >/dev/null
[[ "$(wc -l <"${TEST_SSH_CALLS}")" == "${ssh_calls_before}" ]] ||
  fail "server_on invoked ssh"
assert_file_contains "${TEST_SSHD_DIR}/00-safe-ssh.conf" "# safe_ssh state: enabled"
assert_file_contains "${TEST_SSHD_DIR}/00-safe-ssh.conf" "PasswordAuthentication no"
status_output="$(SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_status)"
assert_contains "${status_output}" "server: enabled"
set +e
status_output="$(TEST_SYSTEMCTL_INACTIVE=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_status)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "inactive SSH service reported enabled"
assert_contains "${status_output}" "server: disabled"
enabled_checksum="$(sha256sum "${TEST_SSHD_DIR}/00-safe-ssh.conf")"
ssh_calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on </dev/null >/dev/null
[[ "$(sha256sum "${TEST_SSHD_DIR}/00-safe-ssh.conf")" == "${enabled_checksum}" ]] ||
  fail "idempotent server_on rewrote its drop-in"
[[ "$(wc -l <"${TEST_SSH_CALLS}")" == "${ssh_calls_before}" ]] ||
  fail "idempotent server_on invoked ssh"
grep -Fq -- '-ddd' "${TEST_SSHD_CALLS}" ||
  fail "server policy validation did not inspect conditional SSH contexts"
TEST_SSHD_DEBUG_LF_ONLY=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on </dev/null >/dev/null
[[ "$(sha256sum "${TEST_SSHD_DIR}/00-safe-ssh.conf")" == "${enabled_checksum}" ]] ||
  fail "LF-only Match inspection rewrote the enabled drop-in"

# A failed first enable removes its new drop-in.
SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_off >/dev/null
reload_calls_before="$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)"
set +e
failure_output="$(printf 'y\n' |
  TEST_SSHD_MATCH_WEAK=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
    "${script}" server_on 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on accepted a weak matched context"
assert_contains "${failure_output}" \
  "sshd policy mismatch (context=user-local-ipv4, pubkey=yes, password=yes"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] || fail "weak context left a drop-in"
match_config="${tmp_dir}/match-user.conf"
printf '%s\n' \
  'Match User bob' \
    '    PasswordAuthentication yes' >"${match_config}"
set +e
failure_output="$(printf 'y\n' |
  TEST_SSHD_EXTRA_CONFIG="${match_config}" \
    SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_on 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on accepted an unverified conditional SSH context"
assert_contains "${failure_output}" \
  "conditional SSH Match directive found: ${match_config}:1:Match User bob"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
  fail "conditional SSH context left a drop-in"

set +e
failure_output="$(printf 'y\n' |
  TEST_SSHD_FAIL_EFFECTIVE_DEFAULT=1 \
    SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_on 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on ignored default effective-config failure"
assert_contains "${failure_output}" "cannot evaluate sshd policy (context=default)"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
  fail "default effective-config failure left a drop-in"

set +e
failure_output="$(printf 'y\n' |
  TEST_SSHD_FAIL_EFFECTIVE_REMOTE=1 \
    SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_on 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on ignored contextual effective-config failure"
assert_contains "${failure_output}" "cannot evaluate sshd policy (context=user-remote-ipv4)"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
  fail "contextual effective-config failure left a drop-in"

set +e
failure_output="$(printf 'y\n' |
  TEST_SSHD_FAIL_DEBUG=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
    "${script}" server_on 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on ignored SSH Match inspection failure"
assert_contains "${failure_output}" "SSH Match inspection failed"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
  fail "SSH Match inspection failure left a drop-in"

set +e
failure_output="$(printf 'y\n' |
  TEST_SSHD_DEBUG_NO_FILES=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
    "${script}" server_on 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on accepted an empty SSH config inspection"
assert_contains "${failure_output}" "SSH Match inspection failed"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] ||
  fail "empty SSH config inspection left a drop-in"
[[ "$(grep -Ec '^reload ' "${TEST_SYSTEMCTL_CALLS}" || true)" == "${reload_calls_before}" ]] ||
  fail "server policy validation failure reloaded SSH"

# Enabling validation and reload failures leave no new drop-in.
set +e
printf 'y\n' | TEST_SSHD_FAIL_VALIDATE=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on accepted invalid sshd configuration"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] || fail "validation failure left a drop-in"
set +e
printf 'y\n' | TEST_SYSTEMCTL_FAIL=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on ignored reload failure"
[[ ! -e "${TEST_SSHD_DIR}/00-safe-ssh.conf" ]] || fail "reload failure left a drop-in"

# A pre-marker owned full-policy drop-in remains recognized as enabled.
{
  printf '%s\n' '# Managed by safe_ssh.sh; do not edit.'
  printf '%s\n' \
    'PubkeyAuthentication yes' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'AuthenticationMethods publickey' \
    'AuthorizedKeysFile .ssh/authorized_keys .safe_ssh/authorized_keys'
} >"${TEST_SSHD_DIR}/00-safe-ssh.conf"
set +e
status_output="$(SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_status)"
set -e
assert_contains "${status_output}" "server: legacy"
set +e
SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_on </dev/null >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on overwrote a legacy drop-in"
set +e
TEST_SSHD_IGNORE_DROPIN=1 SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" server_on </dev/null >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "server_on trusted an ineffective enabled marker"
SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 "${script}" server_off >/dev/null

# Clients use independent keys/known_hosts and a single marked Include without
# disturbing an unrelated SSH host.
set +e
"${script}" client_add Foo alice@example.test >/dev/null 2>&1
status=$?
set -e
[[ "${status}" -ne 0 && ! -e "${home}/.config/safe_ssh/clients/Foo" ]] ||
  fail "uppercase client name was accepted"

mkdir -p "${home}/.ssh/config.d"
printf 'Host Wild* !blocked\nHost shared BLOCKED\n' >"${home}/.ssh/config.d/hosts.conf"
printf 'Include = config.d/hosts.conf\n' >"${home}/.ssh/config.d/nested.conf"
printf 'Host hidden\n' >"${home}/.ssh/config.d/inactive.conf"
printf 'Host tildeuser\n' >"${home}/.ssh/config.d/tilde-user.conf"
printf 'Host other\n' >"${home}/.ssh/config.d/repeated.conf"
printf 'Host replayed\n' >"${home}/.ssh/config.d/replayed.conf"
printf 'ServerAliveInterval 30\nInclude = config.d/nested.conf\nHost *\nInclude ~%s/.ssh/config.d/tilde-user.conf\nHost=equalhost\nHost existing\n  IdentityFile ~/.ssh/existing\nHost safe-ssh-prefixed\nHost other\n  Include config.d/inactive.conf\nHost replay*\n  Include config.d/repeated.conf\nHost replay*\n  Include config.d/repeated.conf\n  Include config.d/replayed.conf\nHost *\n' \
  "$(id -un)" >"${home}/.ssh/config"

# Explicit user Host names, including names in reached Include files and
# multi-token Host lines, reserve a client name before any local or remote
# state is created.  Wildcards and negated tokens do not reserve it.
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
set +e
collision_output="$("${script}" client_add blocked alice@example.test 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "existing SSH Host name was accepted"
assert_contains "${collision_output}" "blocked"
assert_contains "${collision_output}" "${home}/.ssh/config.d/hosts.conf"
[[ ! -e "${home}/.config/safe_ssh/clients/blocked" &&
   ! -e "${home}/.config/safe_ssh/ssh_config.d/blocked.conf" ]] ||
  fail "Host collision created local client state"
[[ "$(wc -l <"${TEST_SSH_CALLS}")" == "${calls_before}" ]] ||
  fail "Host collision attempted remote authorization"
set +e
collision_output="$("${script}" client_add existing alice@example.test 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "main SSH config Host name was accepted"
assert_contains "${collision_output}" "${home}/.ssh/config"
[[ ! -e "${home}/.config/safe_ssh/clients/existing" ]] ||
  fail "main-config Host collision created local client state"
set +e
collision_output="$("${script}" client_add equalhost alice@example.test 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "Host=NAME collision was accepted"
assert_contains "${collision_output}" "${home}/.ssh/config"
[[ ! -e "${home}/.config/safe_ssh/clients/equalhost" ]] ||
  fail "Host=NAME collision created local client state"
set +e
collision_output="$("${script}" client_add tildeuser alice@example.test 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "~user SSH Include collision was accepted"
assert_contains "${collision_output}" "${home}/.ssh/config.d/tilde-user.conf"

# Repeated Includes are replayed in their current Host context.  The second
# pass changes the active context, so the following Include is inactive.
"${script}" client_add replayed alice@example.test >/dev/null
"${script}" client_delete replayed >/dev/null
"${script}" client_add wild alice@example.test >/dev/null
"${script}" client_delete wild >/dev/null
"${script}" client_add prefixed alice@example.test >/dev/null
"${script}" client_delete prefixed >/dev/null
mkdir -p "${TEST_REMOTE_HOME}/.ssh"
chmod 777 "${TEST_REMOTE_HOME}/.ssh"
"${script}" client_add hidden alice@example.test >/dev/null
"${script}" client_delete hidden >/dev/null

# Match blocks without Includes do not prevent collision scanning, while an
# Include whose applicability depends on Match fails closed before side effects.
printf 'Match host elsewhere\n  ServerAliveInterval 10\nHost *\n' >>"${home}/.ssh/config"
"${script}" client_add matched alice@example.test >/dev/null
"${script}" client_delete matched >/dev/null
printf 'Match host elsewhere\n  Include config.d/inactive.conf\n' >>"${home}/.ssh/config"
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
set +e
collision_output="$("${script}" client_add matchinclude alice@example.test 2>&1)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "Match-conditional Include did not fail closed"
assert_contains "${collision_output}" "cannot safely inspect SSH Match block"
[[ ! -e "${home}/.config/safe_ssh/clients/matchinclude" ]] ||
  fail "unsupported Match Include created local client state"
[[ "$(wc -l <"${TEST_SSH_CALLS}")" == "${calls_before}" ]] ||
  fail "unsupported Match Include attempted remote authorization"
sed -i '$d' "${home}/.ssh/config"
sed -i '$d' "${home}/.ssh/config"

# A failed initial authorization can be discarded explicitly without requiring
# access to the unreachable target, freeing the profile name for reuse.
set +e
TEST_REMOTE_HOME=/dev/null \
  "${script}" client_add orphan alice@unreachable.test >/dev/null 2>&1
status=$?
set -e
orphan="${home}/.config/safe_ssh/clients/orphan"
[[ "${status}" -ne 0 && -d "${orphan}" ]] ||
  fail "failed initial client authorization did not retain recovery state"
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
"${script}" client_delete orphan --local-only >/dev/null
[[ ! -e "${orphan}" ]] || fail "local-only deletion retained the unusable profile"
[[ "$(wc -l <"${TEST_SSH_CALLS}")" == "${calls_before}" ]] ||
  fail "local-only deletion attempted remote revocation"
"${script}" client_add orphan alice@example.test >/dev/null
"${script}" client_delete orphan >/dev/null

backup_dir="${TEST_REMOTE_HOME}/.safe_ssh/backup"
# Reusing a key with different comments or options must not add a broader,
# unrestricted authorization for the same key identity.
conflicting_key='from="192.0.2.1" ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_conflict changed-comment'
printf '%s\n' "${conflicting_key}" >"${TEST_REMOTE_HOME}/.ssh/authorized_keys"
cp "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "${tmp_dir}/authorized_keys.before-conflict"
set +e
"${script}" client_add conflict alice@example.test >/dev/null 2>&1
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "conflicting authorization was accepted"
cmp -s "${tmp_dir}/authorized_keys.before-conflict" \
  "${TEST_REMOTE_HOME}/.ssh/authorized_keys" ||
  fail "conflicting authorization changed authorized_keys"
[[ "$(grep -Fc 'AAAA_SAFE_SSH_PUBLIC_KEY_conflict' \
    "${TEST_REMOTE_HOME}/.ssh/authorized_keys")" == 1 ]] ||
  fail "conflicting authorization duplicated the key identity"
"${script}" client_delete conflict --local-only >/dev/null

existing_key='ssh-ed25519 AAAA_PREEXISTING existing'
printf '%s' "${existing_key}" >"${TEST_REMOTE_HOME}/.ssh/authorized_keys"
"${script}" client_add alpha alice@example.test --port 2222 >/dev/null
grep -Fqx -- "${existing_key}" "${TEST_REMOTE_HOME}/.ssh/authorized_keys" ||
  fail "authorization corrupted an unterminated existing key"
grep -Fqx -- 'ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_alpha safe_ssh:alpha' \
  "${TEST_REMOTE_HOME}/.ssh/authorized_keys" ||
  fail "authorization concatenated a new key onto an unterminated line"
cp "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "${tmp_dir}/authorized_keys.before-beta"
backups_before_beta="$(find "${backup_dir}" -name '*.bak' | wc -l)"
"${script}" client_add beta bob@example.net >/dev/null
[[ "$(find "${backup_dir}" -name '*.bak' | wc -l)" == "$((backups_before_beta + 1))" ]] ||
  fail "content-changing authorization did not back up authorized_keys"
beta_backup="$(find "${backup_dir}" -name '*.bak' \
  -exec cmp -s "${tmp_dir}/authorized_keys.before-beta" {} \; -print -quit)"
[[ -n "${beta_backup}" ]] ||
  fail "authorization backup did not preserve the prior file"
cp "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "${tmp_dir}/authorized_keys.before-backup-failure"
mv "${backup_dir}" "${TEST_REMOTE_HOME}/.safe_ssh/backup.saved"
mkdir "${tmp_dir}/unsafe-backup-target"
ln -s "${tmp_dir}/unsafe-backup-target" "${backup_dir}"
set +e
"${script}" client_add backupfail carol@example.org >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "authorization continued after backup rejection"
cmp -s "${tmp_dir}/authorized_keys.before-backup-failure" \
  "${TEST_REMOTE_HOME}/.ssh/authorized_keys" ||
  fail "backup failure changed authorized_keys"
rm "${backup_dir}"
mv "${TEST_REMOTE_HOME}/.safe_ssh/backup.saved" "${backup_dir}"
"${script}" client_delete backupfail --local-only >/dev/null
alpha="${home}/.config/safe_ssh/clients/alpha"
beta="${home}/.config/safe_ssh/clients/beta"
[[ -f "${alpha}/id_ed25519" && -f "${beta}/id_ed25519" ]] || fail "missing client identities"
[[ "${alpha}/id_ed25519" != "${beta}/id_ed25519" ]] || fail "identities are not independent"
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
set +e
"${script}" client_delete alpha --local-only >/dev/null 2>&1
status=$?
set -e
[[ "${status}" -ne 0 && -d "${alpha}" ]] ||
  fail "local-only deletion discarded an authorized profile"
[[ "$(wc -l <"${TEST_SSH_CALLS}")" == "${calls_before}" ]] ||
  fail "rejected local-only deletion attempted remote revocation"
assert_file_contains "${home}/.config/safe_ssh/ssh_config.d/alpha.conf" "Host alpha"
assert_file_contains "${home}/.config/safe_ssh/ssh_config.d/beta.conf" "Host beta"
if grep -Fq 'Host safe-ssh-' "${home}/.config/safe_ssh/ssh_config.d/alpha.conf"; then
  fail "generated SSH snippet retained compatibility alias"
fi
assert_file_contains "${home}/.config/safe_ssh/ssh_config.d/alpha.conf" \
  "GlobalKnownHostsFile /dev/null"
assert_file_contains "${home}/.config/safe_ssh/ssh_config.d/alpha.conf" \
  "PreferredAuthentications publickey"
assert_file_contains "${home}/.config/safe_ssh/ssh_config.d/alpha.conf" \
  "PasswordAuthentication no"
assert_file_contains "${home}/.config/safe_ssh/ssh_config.d/alpha.conf" \
  "KbdInteractiveAuthentication no"
[[ "$(grep -Fc '# safe_ssh managed include' "${home}/.ssh/config")" == 1 ]] ||
  fail "SSH config must contain exactly one managed include"
[[ "$(head -1 "${home}/.ssh/config")" == '# safe_ssh managed include' ]] ||
  fail "managed include is not at the top"
assert_file_contains "${home}/.ssh/config" "Host * # safe_ssh managed scope reset"
assert_file_contains "${home}/.ssh/config" "ServerAliveInterval 30"
assert_file_contains "${home}/.ssh/config" "Host existing"
assert_file_contains "${TEST_SSH_CALLS}" "UserKnownHostsFile=${alpha}/known_hosts"
if grep -q 'id_ed25519 .* true $' "${TEST_SSH_CALLS}"; then
  fail "client_add performed a dedicated-key verification"
fi
alpha_authorize_call="$(grep "${alpha}/id_ed25519" "${TEST_SSH_CALLS}" | grep 'bash -s --' | head -1)"
assert_contains "${alpha_authorize_call}" "-i ${alpha}/id_ed25519"
[[ "${alpha_authorize_call}" != *"IdentitiesOnly=yes"* ]] ||
  fail "default authorization prevented fallback identities"
assert_file_contains "${TEST_REMOTE_HOME}/.ssh/authorized_keys" \
  "ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_alpha safe_ssh:alpha"
[[ "$(stat -c %a "${TEST_REMOTE_HOME}/.ssh")" == 700 ]] ||
  fail "existing remote SSH directory mode was not secured"
[[ "$(stat -c %a "${TEST_REMOTE_HOME}/.ssh/authorized_keys")" == 600 &&
    "$(stat -c %a "${backup_dir}")" == 700 ]] ||
  fail "remote authorization paths have unsafe modes"
[[ "$(find "${backup_dir}" -name '*.absent' | wc -l)" == 1 ]] ||
  fail "first authorization did not preserve an absent marker"
while IFS= read -r backup; do
  [[ "$(stat -c %a "${backup}")" == 600 ]] ||
    fail "authorization backup has an unsafe mode"
done < <(find "${backup_dir}" -type f)

# Bracketed IPv6 input is stored as entered but passed to OpenSSH without
# brackets, both as a destination and as a generated HostName.
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
"${script}" client_add ipv6 alice@[::1] >/dev/null
ipv6_calls="$(tail -n "+$((calls_before + 1))" "${TEST_SSH_CALLS}")"
assert_contains "${ipv6_calls}" "alice@::1"
assert_contains "${ipv6_calls}" "HostName=::1"
assert_contains "${ipv6_calls}" "ControlMaster=no"
assert_contains "${ipv6_calls}" "ControlPath=none"
[[ "${ipv6_calls}" != *'alice@\[::1\]'* ]] ||
  fail "bracketed IPv6 destination was passed to ssh"
assert_file_contains "${home}/.config/safe_ssh/ssh_config.d/ipv6.conf" "HostName ::1"
status_output="$("${script}" client_status ipv6)"
assert_contains "${status_output}" "ipv6: ready"
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
"${script}" client_delete ipv6 >/dev/null
ipv6_delete_calls="$(tail -n "+$((calls_before + 1))" "${TEST_SSH_CALLS}")"
assert_contains "${ipv6_delete_calls}" "alice@::1"
assert_contains "${ipv6_delete_calls}" "HostName=::1"
assert_contains "${ipv6_delete_calls}" "ControlMaster=no"
assert_contains "${ipv6_delete_calls}" "ControlPath=none"
[[ "${ipv6_delete_calls}" != *'alice@\[::1\]'* ]] ||
  fail "bracketed IPv6 destination was passed to ssh during deletion"

calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
backups_before_retry="$(find "${backup_dir}" -type f | wc -l)"
"${script}" client_add alpha alice@example.test --port 2222 >/dev/null
retry_calls="$(tail -n "+$((calls_before + 1))" "${TEST_SSH_CALLS}")"
[[ "$(wc -l <<<"${retry_calls}")" == 1 ]] ||
  fail "existing profile retry made unexpected SSH calls"
[[ "${retry_calls}" == *"bash -s --"* ]] ||
  fail "existing profile retry did not repeat exact authorization"
assert_contains "${retry_calls}" "ControlMaster=no"
assert_contains "${retry_calls}" "ControlPath=none"
assert_contains "${retry_calls}" "HostName=example.test"
[[ "$(grep -Fc 'safe_ssh:alpha' "${TEST_REMOTE_HOME}/.ssh/authorized_keys")" == 1 ]] ||
  fail "existing profile retry duplicated the remote key"
[[ "$(find "${backup_dir}" -type f | wc -l)" == "${backups_before_retry}" ]] ||
  fail "idempotent authorization created a backup"

# Re-adding an existing profile upgrades its exact legacy managed snippet to
# the direct Host name without mistaking that snippet for a user collision.
alpha_snippet="${home}/.config/safe_ssh/ssh_config.d/alpha.conf"
sed -i 's/^Host alpha$/Host safe-ssh-alpha/' "${alpha_snippet}"
"${script}" client_add alpha alice@example.test --port 2222 >/dev/null
assert_file_contains "${alpha_snippet}" "Host alpha"
if grep -Fq 'Host safe-ssh-alpha' "${alpha_snippet}"; then
  fail "legacy managed snippet was not upgraded"
fi

# Revoking a key that is present only in a comment is also idempotent.
"${script}" client_add noop alice@example.test >/dev/null
sed -i '/safe_ssh:noop/d' "${TEST_REMOTE_HOME}/.ssh/authorized_keys"
noop_comment='# ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_noop is documentation'
printf '%s\n' "${noop_comment}" >>"${TEST_REMOTE_HOME}/.ssh/authorized_keys"
backups_before_noop_delete="$(find "${backup_dir}" -type f | wc -l)"
"${script}" client_delete noop >/dev/null
[[ "$(find "${backup_dir}" -type f | wc -l)" == "${backups_before_noop_delete}" ]] ||
  fail "idempotent revocation created a backup"
assert_file_contains "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "${noop_comment}"

# A missing remote SSH directory proves the key is already revoked, so deletion
# can still remove the local profile.
"${script}" client_add missingdir alice@example.test >/dev/null
mv "${TEST_REMOTE_HOME}/.ssh" "${TEST_REMOTE_HOME}/ssh.saved"
"${script}" client_delete missingdir >/dev/null
[[ ! -e "${home}/.config/safe_ssh/clients/missingdir" ]] ||
  fail "missing remote SSH directory prevented local profile cleanup"
mv "${TEST_REMOTE_HOME}/ssh.saved" "${TEST_REMOTE_HOME}/.ssh"

# Connection proof is an explicit, strict dedicated-key command.
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
test_output="$("${script}" client_test alpha)"
assert_contains "${test_output}" "client alpha connection verified."
test_call="$(tail -n "+$((calls_before + 1))" "${TEST_SSH_CALLS}")"
assert_contains "${test_call}" "-i ${alpha}/id_ed25519"
assert_contains "${test_call}" "IdentitiesOnly=yes"
assert_contains "${test_call}" "BatchMode=yes"
assert_contains "${test_call}" "PreferredAuthentications=publickey"
assert_contains "${test_call}" "PasswordAuthentication=no"
assert_contains "${test_call}" "KbdInteractiveAuthentication=no"
assert_contains "${test_call}" "NumberOfPasswordPrompts=0"
assert_contains "${test_call}" "ControlMaster=no"
assert_contains "${test_call}" "ControlPath=none"
assert_contains "${test_call}" "UserKnownHostsFile=${alpha}/known_hosts"
set +e
TEST_CLIENT_TEST_FAIL=1 "${script}" client_test alpha >/dev/null
status=$?
set -e
[[ "${status}" == 1 ]] || fail "client_test connection failure did not exit 1"
set +e
"${script}" client_test >/dev/null
status=$?
set -e
[[ "${status}" == 2 ]] || fail "client_test usage error did not exit 2"

set +e
"${script}" client_add alpha alice@different.test >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "same name with different target was accepted"

status_output="$("${script}" client_status)"
assert_contains "${status_output}" "alpha: ready"
assert_contains "${status_output}" "beta: ready"
assert_file_contains "${TEST_SSH_CALLS}" "-G alpha"
status_output="$(TEST_SSH_G_LITERAL_DISABLED=1 "${script}" client_status alpha)"
assert_contains "${status_output}" "alpha: ready"
set +e
status_output="$(TEST_SSH_LOCALE_PROBE=1 "${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "failed status probe reported ready"
assert_contains "${status_output}" "alpha: unauthorized"

# Status requires an owned snippet whose effective alias settings still match
# the profile; a regular but replaced or corrupted snippet is not ready.
alpha_snippet="${home}/.config/safe_ssh/ssh_config.d/alpha.conf"
assert_file_contains "${alpha_snippet}" "ControlMaster no"
assert_file_contains "${alpha_snippet}" "ControlPath none"
cp "${alpha_snippet}" "${tmp_dir}/alpha.conf"
sed '1d' "${tmp_dir}/alpha.conf" >"${alpha_snippet}"
set +e
status_output="$("${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "unowned snippet reported ready"
assert_contains "${status_output}" "alpha: local-only"
cp "${tmp_dir}/alpha.conf" "${alpha_snippet}"
sed -i 's/HostName example.test/HostName corrupted.test/' "${alpha_snippet}"
set +e
status_output="$("${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "corrupted effective alias reported ready"
assert_contains "${status_output}" "alpha: local-only"
cp "${tmp_dir}/alpha.conf" "${alpha_snippet}"
sed -i '/GlobalKnownHostsFile/d' "${alpha_snippet}"
set +e
status_output="$("${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "alias using global known hosts reported ready"
assert_contains "${status_output}" "alpha: local-only"
cp "${tmp_dir}/alpha.conf" "${alpha_snippet}"
sed -i 's/StrictHostKeyChecking ask/StrictHostKeyChecking no/' "${alpha_snippet}"
set +e
status_output="$("${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "alias with disabled host-key checking reported ready"
assert_contains "${status_output}" "alpha: local-only"
cp "${tmp_dir}/alpha.conf" "${alpha_snippet}"
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "${alpha_snippet}"
set +e
status_output="$("${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "alias allowing password authentication reported ready"
assert_contains "${status_output}" "alpha: local-only"
cp "${tmp_dir}/alpha.conf" "${alpha_snippet}"
sed -i 's/ControlMaster no/ControlMaster auto/' "${alpha_snippet}"
set +e
status_output="$("${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "alias allowing multiplexing reported ready"
assert_contains "${status_output}" "alpha: local-only"
cp "${tmp_dir}/alpha.conf" "${alpha_snippet}"
sed -i 's|ControlPath none|ControlPath ~/.ssh/control-%C|' "${alpha_snippet}"
set +e
status_output="$("${script}" client_status alpha)"
status=$?
set -e
[[ "${status}" -ne 0 ]] || fail "alias with a multiplexing control path reported ready"
assert_contains "${status_output}" "alpha: local-only"
cp "${tmp_dir}/alpha.conf" "${alpha_snippet}"

# Remote revocation failure retains all local state. Successful deletion removes
# only that profile, and deleting the last profile removes only our Include.
sed -i '/safe_ssh:alpha/d' "${TEST_REMOTE_HOME}/.ssh/authorized_keys"
printf '%s\n%s\n' \
  'from="192.0.2.1" ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_alpha changed-comment' \
  'ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_alpha duplicate-comment' \
  >>"${TEST_REMOTE_HOME}/.ssh/authorized_keys"
set +e
TEST_SSH_DELETE_FAIL=1 "${script}" client_delete alpha >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 && -d "${alpha}" ]] || fail "failed revocation removed local state"
cp "${beta}/id_ed25519.pub" "${alpha}/id_ed25519.pub"
cp "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "${tmp_dir}/authorized_keys.before-alpha-delete"
backups_before_alpha_delete="$(find "${backup_dir}" -name '*.bak' | wc -l)"
"${script}" client_delete alpha >/dev/null
[[ ! -d "${alpha}" && -d "${beta}" ]] || fail "client deletion was not isolated"
[[ "$(find "${backup_dir}" -name '*.bak' | wc -l)" == "$((backups_before_alpha_delete + 1))" ]] ||
  fail "content-changing revocation did not back up authorized_keys"
alpha_delete_backup="$(find "${backup_dir}" -name '*.bak' \
  -exec cmp -s "${tmp_dir}/authorized_keys.before-alpha-delete" {} \; -print -quit)"
[[ -n "${alpha_delete_backup}" ]] ||
  fail "revocation backup did not preserve the prior file"
if grep -Fq "AAAA_SAFE_SSH_PUBLIC_KEY_alpha" "${TEST_REMOTE_HOME}/.ssh/authorized_keys"; then
  fail "remote revocation did not remove all forms of the public key"
fi
assert_file_contains "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "safe_ssh:beta"
assert_file_contains "${home}/.ssh/config" "# safe_ssh managed include"
quoted_option_key='command="echo ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_beta done" ssh-ed25519 AAAA_UNRELATED quoted-option'
quoted_comment='# ssh-ed25519 AAAA_SAFE_SSH_PUBLIC_KEY_beta is not a key'
printf '%s\n%s\n' "${quoted_option_key}" "${quoted_comment}" \
  >>"${TEST_REMOTE_HOME}/.ssh/authorized_keys"
"${script}" client_delete beta >/dev/null
assert_file_contains "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "${quoted_option_key}"
assert_file_contains "${TEST_REMOTE_HOME}/.ssh/authorized_keys" "${quoted_comment}"
[[ "$(grep -Fc '# safe_ssh managed include' "${home}/.ssh/config")" == 0 ]] ||
  fail "last deletion left managed include"
assert_file_contains "${home}/.ssh/config" "Host existing"

# A replaced, unowned Host snippet blocks deletion before remote state changes.
"${script}" client_add guarded dave@example.dev >/dev/null
printf 'Host unrelated\n' >"${home}/.config/safe_ssh/ssh_config.d/guarded.conf"
calls_before="$(wc -l <"${TEST_SSH_CALLS}")"
set +e
"${script}" client_delete guarded >/dev/null
status=$?
set -e
[[ "${status}" -ne 0 && -d "${home}/.config/safe_ssh/clients/guarded" ]] ||
  fail "unowned SSH snippet was deleted"
[[ "$(wc -l <"${TEST_SSH_CALLS}")" == "${calls_before}" ]] ||
  fail "remote revocation ran before unowned snippet rejection"

# Generated SSH configuration remains effective when its managed paths contain
# spaces, and status compares the complete values reported by ssh -G.
space_home="${tmp_dir}/home with space"
mkdir -p "${space_home}"
chmod 700 "${space_home}"
TEST_HOME="${space_home}"
HOME="${space_home}"
XDG_CONFIG_HOME="${space_home}/config with space"
export TEST_HOME HOME XDG_CONFIG_HOME
"${script}" client_add spaced erin@example.space >/dev/null
spaced_root="${XDG_CONFIG_HOME}/safe_ssh"
assert_file_contains "${space_home}/.ssh/config" \
  "Include \"${spaced_root}/ssh_config.d/*\""
assert_file_contains "${spaced_root}/ssh_config.d/spaced.conf" \
  "IdentityFile \"${spaced_root}/clients/spaced/id_ed25519\""
status_output="$("${script}" client_status spaced)"
assert_contains "${status_output}" "spaced: ready"
"${script}" client_add spaced erin@example.space >/dev/null
assert_file_contains "${spaced_root}/ssh_config.d/spaced.conf" "Host spaced"
if grep -Fq 'Host safe-ssh-spaced' "${spaced_root}/ssh_config.d/spaced.conf"; then
  fail "spaced profile retained compatibility alias"
fi
"${script}" client_delete spaced >/dev/null
TEST_HOME="${home}"
HOME="${home}"
XDG_CONFIG_HOME="${home}/.config"
export TEST_HOME HOME XDG_CONFIG_HOME

# Sudo logging resolves SUDO_USER through passwd, uses private modes, and logs
# only the key fingerprint—not private/public key material or token values.
set +e
SUDO_USER=tester SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" client_add gamma carol@example.org >/dev/null 2>&1
status=$?
set -e
[[ "${status}" -ne 0 &&
   ! -e "${home}/.config/safe_ssh/clients/gamma" &&
   ! -e "${home}/.config/safe_ssh/ssh_config.d/gamma.conf" ]] ||
  fail "sudo client command created root-owned client artifacts"
SUDO_USER=tester SAFE_SSH_TESTING=1 SAFE_SSH_TEST_EUID=0 \
  "${script}" client_add gamma carol@example.org --bootstrap-identity "${tmp_dir}/missing" >/dev/null 2>&1 || true
set +e
"${script}" unknown --token super-secret-token >/dev/null 2>&1
set -e
all_logs="$(cat "${home}/.safe_ssh/logs/"*.log)"
assert_contains "${all_logs}" "[REDACTED]"
assert_contains "${all_logs}" "user=tester subcommand=client_add"
[[ "${all_logs}" != *"super-secret-token"* ]] || fail "token leaked to log"
[[ "${all_logs}" != *"PRIVATE-KEY-MUST-NOT-BE-LOGGED"* ]] || fail "private key leaked to log"
[[ "${all_logs}" != *"AAAA_SAFE_SSH_PUBLIC_KEY"* ]] || fail "public key leaked to log"

printf 'safe_ssh tests passed\n'
