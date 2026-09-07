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

if ! [[ "$port" =~ ^[0-9]+$ ]]; then
  echo "Error: port must be an integer between 1 and 65535." >&2
  exit 1
fi

# Normalize decimal input before arithmetic (leading zeros are not octal).
while [[ "$port" == 0* && ${#port} -gt 1 ]]; do
  port="${port#0}"
done
if (( ${#port} > 5 )) || (( port < 1 || port > 65535 )); then
  echo "Error: port must be an integer between 1 and 65535." >&2
  exit 1
fi

# Socket tables own the listening-state decision. Process visibility does not.
# Return 0 for listening, 1 for no listener, and 2 for an unknown state.
query_listener() {
  local result status
  if command -v ss >/dev/null 2>&1; then
    if result="$(ss -H -ltn "sport = :$port")"; then
      listener_details="$result"
      [[ -n "$result" ]] && return 0
      return 1
    else
      status=$?
      echo "Warning: ss query failed (exit $status); trying another backend." >&2
    fi
  fi

  if command -v netstat >/dev/null 2>&1; then
    if result="$(netstat -ltn)"; then
      if listener_details="$(awk -v port="$port" '
        ($1 == "tcp" || $1 == "tcp6") && $6 == "LISTEN" {
          address = $4
          sub(/^.*:/, "", address)
          if (address == port) print
        }
      ' <<< "$result")"; then
        [[ -n "$listener_details" ]] && return 0
        return 1
      fi
      echo "Warning: could not parse netstat output; trying another backend." >&2
    else
      status=$?
      echo "Warning: netstat query failed (exit $status); trying another backend." >&2
    fi
  fi

  # lsof can establish presence, but an empty result cannot establish absence.
  if command -v lsof >/dev/null 2>&1; then
    if result="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN)"; then
      if [[ -n "$result" ]]; then
        listener_details="$result"
        details_from_lsof=true
        return 0
      fi
    else
      status=$?
      echo "Warning: lsof could not confirm a listener (exit $status)." >&2
    fi
  fi
  return 2
}

listener_details=""
details_from_lsof=false
if query_listener; then
  echo "TCP port $port has a listener:"
  printf '%s\n' "$listener_details"
  if [[ "$details_from_lsof" == false ]] && command -v lsof >/dev/null 2>&1; then
    # Optional process details must never change the confirmed socket state.
    if process_details="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null)"; then
      if [[ -n "$process_details" ]]; then
        printf '\nProcess details:\n%s\n' "$process_details"
      fi
    fi
  fi
  exit 0
else
  status=$?
fi

if (( status == 2 )); then
  echo "Error: cannot determine TCP port $port listening state; requires a successful ss or netstat query, or a listener visible to lsof." >&2
  exit 2
fi

echo "No TCP listener found on port $port."
