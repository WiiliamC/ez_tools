#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/install_clash_server.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

validate_endpoint proxy.example.com 18443
validate_endpoint proxy.example.com 01024
for host in 'https://proxy.example.com' 'proxy.example.com:443' 'bad_name' '999.1.1.1' '127.0.0.1' '::1' $'example.com\nrules:'; do
  if validate_endpoint "$host" 18443 > /dev/null 2>&1; then
    printf 'Accepted invalid host\n' >&2; exit 1
  fi
done
for port in 0 443 65536 -1 1.5 '1;id' 99999999999999999999; do
  if validate_endpoint proxy.example.com "$port" >/dev/null 2>&1; then
    printf 'Accepted invalid port\n' >&2; exit 1
  fi
done
mkdir "$tmp/first" "$tmp/second"
write_profiles "$tmp/first" proxy.example.com 18443
write_profiles "$tmp/second" proxy.example.com 18443
# PyYAML is a test-only dependency (Ubuntu: python3-yaml).
python3 - "$tmp" <<'PY'
import base64
import json
from pathlib import Path
import stat
import sys
import yaml

root = Path(sys.argv[1])
a = json.loads((root / 'first/server.json').read_text())
b = json.loads((root / 'second/server.json').read_text())
profile = yaml.safe_load((root / 'first/clash.yaml').read_text())
node = profile['proxies'][0]
assert a['password'] != b['password'] and len(a['password']) >= 40
assert node['password'] == a['password']
assert node['cipher'] == a['method'] == 'chacha20-ietf-poly1305'
assert node['port'] == a['server_port'] == 18443
assert node['server'] == 'proxy.example.com'
assert node['udp'] and a['mode'] == 'tcp_and_udp'
assert a['server'] == '0.0.0.0' and not profile['allow-lan']
assert profile['rules'] == ['MATCH,PROXY']
assert profile['proxy-groups'][0]['proxies'][0] == node['name']
uri = (root / 'first/share-uri.txt').read_text().strip()
auth, endpoint = uri.removeprefix('ss://').split('@')
assert base64.urlsafe_b64decode(auth + '=' * (-len(auth) % 4)).decode() == f"{a['method']}:{a['password']}"
assert endpoint == 'proxy.example.com:18443#Cloud-SS'
for directory in root.iterdir():
    for path in directory.iterdir():
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
PY
bash "$repo_root/install_clash_server.sh" help >/dev/null
if bash "$repo_root/install_clash_server.sh" install >/dev/null 2>&1; then
  printf 'Accepted missing endpoint\n' >&2; exit 1
fi
if bash "$repo_root/install_clash_server.sh" install --server >/dev/null 2>&1; then
  printf 'Accepted missing option value\n' >&2; exit 1
fi
printf 'install_clash_server tests passed\n'
