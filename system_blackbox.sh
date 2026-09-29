#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  system_blackbox.sh install [--interval SECONDS] [--retention-days DAYS] [--log-dir ABSOLUTE_PATH]
  system_blackbox.sh status
  system_blackbox.sh uninstall

Run install/uninstall as root in your terminal. Defaults: 1 second, 2 calendar
days, /var/log/system-blackbox. Reinstall replaces configuration with the supplied
options and defaults. Uninstall preserves configuration and recorded logs.
EOF
}

action="${1:-help}"
if [[ $# -gt 0 ]]; then shift; fi
case "$action" in
    help|-h|--help) usage; exit 0 ;;
    install|uninstall|status) ;;
    *) usage >&2; exit 2 ;;
esac

if [[ "$action" == status ]]; then
    [[ $# == 0 ]] || { usage >&2; exit 2; }
    systemctl --no-pager --full status system-blackbox.service
    exit
fi

interval=1
retention=2
log_dir=/var/log/system-blackbox
while [[ $# -gt 0 ]]; do
    [[ "$action" == install && $# -ge 2 ]] || { usage >&2; exit 2; }
    case "$1" in
        --interval) interval="$2" ;;
        --retention-days) retention="$2" ;;
        --log-dir) log_dir="$2" ;;
        *) usage >&2; exit 2 ;;
    esac
    shift 2
done

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this command as root in your own terminal (for example with sudo)." >&2
    exit 1
fi
command -v systemctl >/dev/null

if [[ "$action" == uninstall ]]; then
    if [[ -f /etc/systemd/system/system-blackbox.service ]]; then
        systemctl disable --now system-blackbox.service
        rm -f /etc/systemd/system/system-blackbox.service
    fi
    rm -f /usr/local/lib/system-blackbox/system_blackbox.py
    systemctl daemon-reload
    echo "Service removed. Logs and /etc/default/system-blackbox were preserved."
    exit
fi

command -v python3 >/dev/null
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$source_dir/system_blackbox.py" ]] || { echo "Collector is missing." >&2; exit 1; }
config_tmp="$(mktemp)"
trap 'rm -f -- "$config_tmp"' EXIT
python3 - "$interval" "$retention" "$log_dir" > "$config_tmp" <<'PY'
import math
import os
from pathlib import Path
import sys

interval = float(sys.argv[1])
days = int(sys.argv[2])
directory = Path(sys.argv[3])
if not math.isfinite(interval) or interval <= 0 or days <= 0:
    raise SystemExit("interval and retention must be positive")
if not directory.is_absolute() or any(ord(c) < 32 for c in str(directory)):
    raise SystemExit("log directory must be an absolute path without control characters")
if any(p.is_symlink() for p in [directory, *directory.parents]):
    raise SystemExit("log directory cannot have symlink components")
directory = Path(os.path.abspath(directory))
if directory in (Path('/'), Path('/var'), Path('/var/log'), Path('/tmp'), Path('/home')):
    raise SystemExit("use a dedicated log subdirectory")
if directory.exists() and any(p.name != '.lock' and not (len(p.name) == 16 and p.name.endswith('.jsonl')) for p in directory.iterdir()):
    raise SystemExit("log directory contains unrelated files; use a dedicated directory")
escaped = str(directory).replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$')
print('BLACKBOX_INTERVAL=' + str(interval))
print('BLACKBOX_RETENTION_DAYS=' + str(days))
print('BLACKBOX_LOG_DIR="' + escaped + '"')
PY

install -d -m 0755 /usr/local/lib/system-blackbox
install -m 0755 "$source_dir/system_blackbox.py" /usr/local/lib/system-blackbox/system_blackbox.py
install -m 0600 "$config_tmp" /etc/default/system-blackbox
install -d -m 0700 -- "$log_dir"
cat > /etc/systemd/system/system-blackbox.service <<'EOF'
[Unit]
Description=System blackbox telemetry for abrupt shutdown investigation
After=local-fs.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
EnvironmentFile=/etc/default/system-blackbox
ExecStart=/usr/bin/python3 /usr/local/lib/system-blackbox/system_blackbox.py run --interval ${BLACKBOX_INTERVAL} --retention-days ${BLACKBOX_RETENTION_DAYS} --log-dir ${BLACKBOX_LOG_DIR}
Restart=on-failure
RestartSec=5
TimeoutStopSec=10
KillMode=control-group
UMask=0077
NoNewPrivileges=true
Nice=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable system-blackbox.service
systemctl restart system-blackbox.service
systemctl --no-pager --full status system-blackbox.service
echo "Installed. Check journalctl --list-boots separately for historical journal availability."
