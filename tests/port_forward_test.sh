#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/port_forward.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# shellcheck source=../port_forward.sh
source "${script}"
original_get_ssh_config="$(declare -f get_ssh_config)"

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

[[ "$(resolve_target_host 10.0.0.5)" == 10.0.0.5 ]] || fail "IPv4 compatibility failed"
is_valid_ipv4 255.255.255.255 || fail "valid IPv4 was rejected"
if is_valid_ipv4 256.0.0.1 || is_valid_ipv4 1234.0.0.1; then
    fail "invalid IPv4 was accepted"
fi

get_ssh_config() {
    case "$1" in
        ms5090) printf 'hostname 192.168.0.102\nuser chan\nport 22\n' ;;
        dns-host) printf 'hostname server.example.test\n' ;;
        jump-host) printf 'hostname 10.0.0.8\nproxyjump gateway\n' ;;
        command-host) printf 'hostname 10.0.0.9\nproxycommand ssh gateway -W %%h:%%p\n' ;;
        missing-host) return 1 ;;
        *) printf 'hostname %s\n' "$1" ;;
    esac
}

resolve_ipv4_address() {
    [[ "$1" == server.example.test ]] && printf '10.20.30.40\n'
}

[[ "$(resolve_target_host ms5090)" == 192.168.0.102 ]] || fail "SSH alias did not resolve"
[[ "$(resolve_target_host dns-host)" == 10.20.30.40 ]] || fail "SSH HostName DNS did not resolve"

for rejected_host in jump-host command-host missing-host bad@host; do
    if resolve_target_host "${rejected_host}" >/dev/null 2>&1; then
        fail "unsafe or unsupported host was accepted: ${rejected_host}"
    fi
done

# Verify sudo invocations read SSH configuration as the initiating user.
eval "${original_get_ssh_config}"
effective_uid() { printf '0\n'; }
getent() {
    [[ "$1" == passwd && "$2" == tester ]] || return 1
    printf 'tester:x:1001:1001::/home/tester:/bin/bash\n'
}
runuser() {
    printf '%s\n' "$*" >"${tmp_dir}/runuser.args"
    printf 'hostname 192.168.0.102\n'
}
SUDO_USER=tester get_ssh_config ms5090 >/dev/null
assert_file_contains "${tmp_dir}/runuser.args" '-u tester -- env HOME=/home/tester USER=tester LOGNAME=tester ssh -G -- ms5090'

# Restore deterministic resolver mocks and verify add creates the existing rule set.
get_ssh_config() { printf 'hostname 192.168.0.102\n'; }
iptables_log="${tmp_dir}/iptables.log"
: >"${iptables_log}"
iptables() {
    if [[ "$*" == '-t nat -S PREROUTING' ]]; then
        return 0
    fi
    printf '%s\n' "$*" >>"${iptables_log}"
}
enable_ip_forward() { :; }

output="$(add_rule 8080 ms5090 80)"
assert_contains "${output}" 'ms5090 (192.168.0.102):80'
assert_file_contains "${iptables_log}" '-t nat -A PREROUTING -p tcp --dport 8080 -m comment --comment ez_tools_port_forward local=8080 target=192.168.0.102:80 -j DNAT --to-destination 192.168.0.102:80'
assert_file_contains "${iptables_log}" '-t nat -A POSTROUTING -p tcp -d 192.168.0.102 --dport 80 -m comment --comment ez_tools_port_forward local=8080 target=192.168.0.102:80 -j MASQUERADE'
assert_file_contains "${iptables_log}" '-A FORWARD -p tcp -d 192.168.0.102 --dport 80 -m comment --comment ez_tools_port_forward local=8080 target=192.168.0.102:80 -j ACCEPT'

saved_rule='-A PREROUTING -p tcp --dport 8080 -m comment --comment "ez_tools_port_forward local=8080 target=192.168.0.102:80" -j DNAT --to-destination 192.168.0.102:80'
iptables() {
    if [[ "$*" == '-t nat -S PREROUTING' ]]; then
        printf '%s\n' "${saved_rule}"
        return 0
    fi
    printf '%s\n' "$*" >>"${iptables_log}"
}
list_output="$(list_rules)"
assert_contains "${list_output}" '8080'
assert_contains "${list_output}" '192.168.0.102'

: >"${iptables_log}"
remove_rule 8080 >/dev/null
assert_file_contains "${iptables_log}" '-t nat -D PREROUTING -p tcp --dport 8080'
assert_file_contains "${iptables_log}" '-t nat -D POSTROUTING -p tcp -d 192.168.0.102 --dport 80'
assert_file_contains "${iptables_log}" '-D FORWARD -p tcp -d 192.168.0.102 --dport 80'

iptables() {
    if [[ "$*" == *'-L PREROUTING -n --line-numbers'* ||
          "$*" == *'-L POSTROUTING -n --line-numbers'* ||
          "$*" == '-L FORWARD -n --line-numbers' ]]; then
        printf '3 managed rule %s\n' "${RULE_COMMENT_PREFIX}"
        return 0
    fi
    printf '%s\n' "$*" >>"${iptables_log}"
}
: >"${iptables_log}"
flush_rules >/dev/null
assert_file_contains "${iptables_log}" '-t nat -D PREROUTING 3'
assert_file_contains "${iptables_log}" '-t nat -D POSTROUTING 3'
assert_file_contains "${iptables_log}" '-D FORWARD 3'

before_count="$(wc -l <"${iptables_log}")"
if (add_rule 8081 bad@host 80) >/dev/null 2>&1; then
    fail "invalid host add unexpectedly succeeded"
fi
after_count="$(wc -l <"${iptables_log}")"
[[ "${before_count}" == "${after_count}" ]] || fail "invalid host changed iptables"

help_output="$("${script}" --help)"
assert_contains "${help_output}" 'add <local_port> <target_host> <target_port>'
assert_contains "${help_output}" 'ms5090'

printf 'port_forward tests passed\n'
