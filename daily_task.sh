#!/usr/bin/env bash
# Daily scheduling is a compatibility mode of the shared task manager.
set -euo pipefail
script_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec "${script_dir}/repeat_task.sh" --daily "$@"
