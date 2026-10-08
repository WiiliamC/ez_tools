#!/usr/bin/env bash
set -euo pipefail

# Internal selector for the shared review/fix state machine.
readonly review_until_workflow=pr
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/review_until_common.sh"
