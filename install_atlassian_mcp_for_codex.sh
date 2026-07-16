#!/usr/bin/env bash

set -euo pipefail

MCP_NAME="atlassian"
MCP_URL="https://mcp.atlassian.com/v1/mcp/authv2"
TAG="[install-atlassian-mcp]"

log() {
  printf '%s %s\n' "${TAG}" "$*"
}

die() {
  printf '%s ERROR: %s\n' "${TAG}" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

main() {
  if [[ $# -ne 0 ]]; then
    die "this script does not accept arguments"
  fi

  need_cmd codex

  if codex mcp get "${MCP_NAME}" >/dev/null 2>&1; then
    die "an MCP configuration named '${MCP_NAME}' already exists; remove it explicitly before retrying"
  fi

  log "adding global Codex MCP server '${MCP_NAME}'"
  if ! codex mcp add "${MCP_NAME}" --url "${MCP_URL}"; then
    die "could not add '${MCP_NAME}'"
  fi

  log "starting Atlassian OAuth login"
  if ! codex mcp login "${MCP_NAME}"; then
    die "MCP configuration was added, but login failed; retry with: codex mcp login ${MCP_NAME}"
  fi

  log "Atlassian MCP was configured and authenticated successfully"
}

main "$@"
