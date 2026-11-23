#!/usr/bin/env bash
# Ubuntu 24.04 Shadowsocks server with a portable Clash client profile.
set -euo pipefail

CONFIG_DIR=/etc/ez-clash-server
UNIT_PATH=/etc/systemd/system/ez-clash-server.service

usage() {
  cat <<'HELP'
Usage: sudo ./install_clash_server.sh install --server PUBLIC_IPV4_OR_HOST [--port 18443]
       ./install_clash_server.sh status
       ./install_clash_server.sh help

Ubuntu 24.04 with systemd only. Installs shadowsocks-libev from Ubuntu APT.
--server is the public IPv4 address or DNS name clients connect to (no URL).
The server listens on IPv4, TCP + UDP; ports 1024..65535 are supported.
Generates /etc/ez-clash-server/{server.json,clash.yaml,share-uri.txt} (root only).
Existing configuration is never overwritten. Firewall rules are not changed.
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

validate_endpoint() {
  python3 - "$1" "$2" <<'PY'
import ipaddress
import re
import sys
host, port = sys.argv[1:]
if not re.fullmatch(r"[0-9]{1,5}", port) or not 1024 <= int(port) <= 65535:
    sys.exit("Port must be an integer from 1024 to 65535")
try:
    address = ipaddress.ip_address(host)
except ValueError:
    if (len(host) > 253 or re.fullmatch(r"[0-9.]+", host)
        or not all(re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
                   for label in host.split("."))):
        sys.exit("Use an IPv4 address or ASCII DNS name, not a URL")
else:
    if address.version != 4 or not address.is_global:
        sys.exit("Use a public IPv4 address; IPv6-only endpoints are not supported")
PY
}

write_profiles() {
  # Arguments contain no credentials. Generate and serialize the secret internally.
  python3 - "$1" "$2" "$3" <<'PY'
import base64
import json
import os
from pathlib import Path
import secrets
import sys

os.umask(0o077)
directory, host, port = sys.argv[1:]
directory = Path(directory)
port = int(port)
password = secrets.token_urlsafe(32)
cipher = "chacha20-ietf-poly1305"
server = {"server": "0.0.0.0", "server_port": port, "password": password,
          "timeout": 300, "method": cipher, "mode": "tcp_and_udp"}
(directory / "server.json").write_text(json.dumps(server, indent=2) + "\n")
# JSON quoted strings are valid YAML scalars; never interpolate raw input into YAML.
profile = f'''mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: false
proxies:
  - name: Cloud-SS
    type: ss
    server: {json.dumps(host)}
    port: {port}
    cipher: {cipher}
    password: {json.dumps(password)}
    udp: true
proxy-groups:
  - name: PROXY
    type: select
    proxies: [Cloud-SS, DIRECT]
rules:
  - MATCH,PROXY
'''
(directory / "clash.yaml").write_text(profile)
auth = base64.urlsafe_b64encode(f"{cipher}:{password}".encode()).decode().rstrip("=")
(directory / "share-uri.txt").write_text(f"ss://{auth}@{host}:{port}#Cloud-SS\n")
PY
}

write_unit() {
  cat <<'UNIT'
[Unit]
Description=Shadowsocks server for Clash clients
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=server.json:/etc/ez-clash-server/server.json
ExecStart=/usr/bin/ss-server -c %d/server.json -u
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
}

install_server() {
  local host="$1" port="$2" ID='' VERSION_ID='' listeners
  [[ $EUID -eq 0 ]] || die 'run install with sudo'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'requires Ubuntu 24.04'
  [[ -d /run/systemd/system ]] || die 'requires systemd running as PID 1'
  command -v python3 >/dev/null || die 'install python3 first: sudo apt-get install python3'
  validate_endpoint "$host" "$port"
  # Lock before checking/writing configuration to prevent concurrent installs.
  exec 9>/run/lock/ez-clash-server.lock
  flock -n 9 || die 'another installation is running'
  [[ ! -e $CONFIG_DIR && ! -L $CONFIG_DIR && ! -e $UNIT_PATH && ! -L $UNIT_PATH ]] ||
    die 'installation files already exist; see README for restart/recovery/removal'
  command -v ss >/dev/null || die 'install iproute2 first: sudo apt-get install iproute2'
  port=$((10#$port))
  listeners=$(ss -H -lntu "sport = :$port")
  [[ -z $listeners ]] || die "TCP or UDP port $port is already in use"
  apt-get update
  apt-get install -y --no-install-recommends shadowsocks-libev
  # APT may start the package default service; do not displace any existing listener.
  listeners=$(ss -H -lntu "sport = :$port")
  [[ -z $listeners ]] || die "port $port became occupied; choose another port"
  umask 077
  install -d -m 0700 -o root -g root "$CONFIG_DIR"
  write_profiles "$CONFIG_DIR" "$host" "$port"
  write_unit > "$UNIT_PATH"
  chmod 0644 "$UNIT_PATH"
  systemctl daemon-reload
  systemctl enable --now ez-clash-server.service
  sleep 2
  if ! systemctl is-active --quiet ez-clash-server.service; then
    die 'service failed; inspect sudo journalctl -u ez-clash-server.service -n 50'
  fi
  printf 'Service started. Client profile: %s/clash.yaml\n' "$CONFIG_DIR"
  printf 'In cloud security groups and host firewall, allow inbound TCP AND UDP %s.\n' "$port"
  printf 'If UFW is already active: sudo ufw allow %s/tcp && sudo ufw allow %s/udp\n' "$port" "$port"
  printf 'Import the private profile into your client; see README for transfer and phone setup.\n'
  printf 'Local startup was checked; connectivity from your PC/phone still needs verification.\n'
}

main() {
  local action="${1:-help}" host='' port=18443
  (($# == 0)) || shift
  case "$action" in
    help|-h|--help) [[ $# == 0 ]] || die 'unexpected arguments'; usage ;;
    status) [[ $# == 0 ]] || die 'unexpected arguments'; systemctl --no-pager status ez-clash-server.service ;;
    install)
      while (($#)); do
        case "$1" in
          --server|--port)
            [[ $# -ge 2 && -n $2 ]] || die "missing value for $1"
            if [[ $1 == --server ]]; then host=$2; else port=$2; fi
            shift 2 ;;
          *) die "unknown argument: $1" ;;
        esac
      done
      [[ -n $host ]] || die '--server is required; use help'
      install_server "$host" "$port"
      ;;
    *) die "unknown command: $action" ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
