#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/safe_ssh_client.ps1"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  grep -Fq -- "$2" "$1" || fail "expected '$2' in $1"
}

assert_absent() {
  ! grep -Fiq -- "$2" "$1" || fail "did not expect '$2' in $1"
}

assert_absent_regex() {
  ! grep -Eiq -- "$2" "$1" || fail "did not expect pattern '$2' in $1"
}

[[ -f "${script}" ]] || fail "safe_ssh_client.ps1 must exist"

# The Windows helper is deliberately local-only: it creates or reuses one key
# pair and writes an isolated OpenSSH alias without contacting the target.
assert_contains "${script}" '[string]$Name'
assert_contains "${script}" '[string]$Target'
assert_contains "${script}" '[string]$Port = "22"'
assert_contains "${script}" "\$Port -cnotmatch '^[0-9]+\$'"
assert_contains "${script}" 'Get-Command "ssh-keygen.exe"'
assert_contains "${script}" 'Get-Command "ssh.exe"'
assert_contains "${script}" 'Join-Path $SafeSshDir "clients"'
assert_contains "${script}" 'Join-Path $ClientsDir $Name'
assert_contains "${script}" 'The client key directory contains an incomplete key pair'
assert_contains "${script}" 'Press Enter twice for an empty passphrase.'
assert_contains "${script}" 'Private key:'
assert_contains "${script}" 'Public key:'
assert_contains "${script}" 'Public-key line:'
assert_contains "${script}" '~/.ssh/authorized_keys'
assert_contains "${script}" 'HostName $HostName'
assert_contains "${script}" 'User $UserName'
assert_contains "${script}" 'Port $Port'
assert_contains "${script}" 'IdentityFile $ConfigIdentityFile'
assert_contains "${script}" 'IdentitiesOnly yes'
assert_contains "${script}" 'PreferredAuthentications publickey'
assert_contains "${script}" 'PasswordAuthentication no'
assert_contains "${script}" 'KbdInteractiveAuthentication no'
assert_contains "${script}" 'UserKnownHostsFile $ConfigKnownHostsFile'
assert_contains "${script}" 'GlobalKnownHostsFile NUL'
assert_contains "${script}" 'StrictHostKeyChecking ask'
assert_contains "${script}" 'ControlMaster no'
assert_contains "${script}" 'ControlPath none'
assert_contains "${script}" 'ControlPersist no'
assert_contains "${script}" '# safe_ssh managed include'
assert_contains "${script}" 'Host * # safe_ssh managed scope reset'
assert_contains "${script}" 'Refusing to replace an existing safe_ssh alias'
assert_contains "${script}" 'Refusing to take over unmanaged Host alias'
assert_contains "${script}" 'ssh $Name'
assert_contains "${script}" 'verify the server host-key fingerprint'

assert_absent "${script}" 'BootstrapIdentity'
assert_absent "${script}" 'authorized_keys.safe_ssh'
assert_absent "${script}" 'Start-Process'
assert_absent_regex "${script}" '&[[:space:]]+\$Ssh([.]Source)?([[:space:]]|$)'
assert_absent_regex "${script}" '^[[:space:]]*ssh([.]exe)?[[:space:]]'

printf 'safe_ssh_client static contract tests passed\n'
