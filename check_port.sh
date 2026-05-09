#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./check_port.sh <port>

Examples:
  ./check_port.sh 8080
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

port="$1"

if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
  echo "Error: port must be an integer between 1 and 65535." >&2
  exit 1
fi

if command -v lsof >/dev/null 2>&1; then
  result="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "$result" ]]; then
    echo "Port $port is in use:"
    echo "$result"
    exit 0
  fi
elif command -v ss >/dev/null 2>&1; then
  result="$(ss -ltnp "sport = :$port" 2>/dev/null || true)"
  if [[ "$result" == *":$port"* ]]; then
    echo "Port $port is in use:"
    echo "$result"
    exit 0
  fi
elif command -v netstat >/dev/null 2>&1; then
  result="$(netstat -ltnp 2>/dev/null | awk -v port=":$port" '$4 ~ port "$"')"
  if [[ -n "$result" ]]; then
    echo "Port $port is in use:"
    echo "$result"
    exit 0
  fi
else
  echo "Error: requires one of lsof, ss, or netstat." >&2
  exit 2
fi

echo "Port $port is available."
