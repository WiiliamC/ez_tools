#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./kill_process.sh <process_command_keyword>

Examples:
  ./kill_process.sh npm
  ./kill_process.sh "python -m service"
EOF
}

if [[ $# -ne 1 || -z "${1:-}" ]]; then
  usage
  exit 1
fi

keyword="$1"
script_pid="$$"
kill_command="${KILL_PROCESS_KILL:-kill}"
declare -a matched_pids=()
declare -a matched_lines=()
declare -A parent_by_pid=()
declare -A excluded_pids=()

excluded_pids["${script_pid}"]=1

while read -r pid ppid _; do
  [[ -n "${pid:-}" && -n "${ppid:-}" ]] || continue
  parent_by_pid["${pid}"]="${ppid}"
done < <(ps -eo pid=,ppid=)

ancestor_pid="${PPID:-}"
while [[ -n "${ancestor_pid}" && "${ancestor_pid}" != "0" ]]; do
  excluded_pids["${ancestor_pid}"]=1

  next_pid="${parent_by_pid[${ancestor_pid}]:-}"
  [[ -n "${next_pid}" && "${next_pid}" != "${ancestor_pid}" ]] || break
  ancestor_pid="${next_pid}"
done

while read -r pid ppid user etime stat command; do
  [[ -n "${pid:-}" ]] || continue

  [[ -n "${excluded_pids[${pid}]:-}" ]] && continue
  [[ "${command}" == *"${keyword}"* ]] || continue

  matched_pids+=("${pid}")
  matched_lines+=("$(printf '%-8s %-8s %-16s %-12s %-8s %s' "${pid}" "${ppid}" "${user}" "${etime}" "${stat}" "${command}")")
done < <(ps -eo pid=,ppid=,user=,etime=,stat=,args=)

if [[ "${#matched_pids[@]}" -eq 0 ]]; then
  echo "No matching processes found for keyword: ${keyword}"
  exit 0
fi

echo "Matching processes:"
printf '%-8s %-8s %-16s %-12s %-8s %s\n' "PID" "PPID" "USER" "ETIME" "STAT" "CMD"
printf '%s\n' "${matched_lines[@]}"
printf 'Send TERM to these %d process(es)? [y/N] ' "${#matched_pids[@]}"
if ! read -r confirmation; then
  echo
  confirmation=""
fi

case "${confirmation,,}" in
  y|yes)
    echo "Sending TERM to ${#matched_pids[@]} process(es)."
    "${kill_command}" -TERM "${matched_pids[@]}"
    ;;
  *)
    echo "No processes killed."
    ;;
esac
