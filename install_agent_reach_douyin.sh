#!/usr/bin/env bash
# User-local Agent Reach + OpenCLI Douyin setup. Never modifies shell profiles.
set -euo pipefail

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage: install_agent_reach_douyin.sh [install|check|help]
       install_agent_reach_douyin.sh check --query "keyword"
install (default): reuse tools, install missing tools locally, register Douyin skill.
check: check tools, Douyin adapter and browser bridge; --query verifies a real search.
Requires Python >=3.10 when installing Agent Reach, Node.js >=20.18.1, and npm
when installing OpenCLI. No system packages or shell profiles are changed.
HELP
}
command_name="${1:-install}"
[[ $# -eq 0 ]] || shift
query=''
case "$command_name" in
  help|-h|--help) [[ $# -eq 0 ]] || fail 'unexpected help arguments'; usage; exit 0 ;;
  install) [[ $# -eq 0 ]] || fail 'install accepts no arguments' ;;
  check)
    if [[ $# -gt 0 ]]; then
      [[ $# -eq 2 && "$1" == '--query' && -n "$2" ]] || fail 'use check --query "keyword"'
      query="$2"
    fi ;;
  *) usage >&2; fail "unknown command: $command_name" ;;
esac

agent_managed="$HOME/.agent-reach-venv/bin/agent-reach"
opencli_managed="$HOME/.agent-reach/tools/opencli/node_modules/.bin/opencli"
agent=''
opencli=''

node_check() {
  command -v node >/dev/null 2>&1 || fail 'Node.js >=20.18.1 is required; install it manually and retry'
  local version major minor patch
  version="$(node --version)"
  if [[ "$version" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
    major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
    (( major > 20 || (major == 20 && (minor > 18 || (minor == 18 && patch >= 1))) )) || fail 'Node.js >=20.18.1 is required'
  else
    fail "cannot determine Node.js version: $version"
  fi
}
select_tools() {
  local candidate
  candidate="$(command -v agent-reach || true)"
  if [[ -n "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then
    agent="$candidate"
  elif [[ -x "$agent_managed" ]] && "$agent_managed" --version >/dev/null 2>&1; then
    agent="$agent_managed"
  fi
  candidate="$(command -v opencli || true)"
  if [[ -n "$candidate" ]] && "$candidate" douyin search --help >/dev/null 2>&1; then
    opencli="$candidate"
  elif [[ -x "$opencli_managed" ]] && "$opencli_managed" douyin search --help >/dev/null 2>&1; then
    opencli="$opencli_managed"
  fi
}
# Only replace a wrapper whose complete content matches our managed wrapper.
wrapper() {
  local name="$1" target="$2" path="$HOME/.local/bin/$1" content
  printf -v content '#!/usr/bin/env bash\n# Managed by install_agent_reach_douyin.sh\nexec %q "$@"' "$target"
  if [[ -e "$path" || -L "$path" ]]; then
    [[ -f "$path" && ! -L "$path" && "$(cat "$path")" == "$content" ]] || fail "unmanaged entry at $path; move it manually before retrying"
  else
    mkdir -p "$HOME/.local/bin"
    printf '%s\n' "$content" > "$path"
    chmod +x "$path"
  fi
}
register_skill() {
  local target="$HOME/.agents/skills/agent-reach" staging
  if [[ ! -f "$target/SKILL.md" ]]; then
    # Upstream registration overwrites skills by default. Isolate every destination.
    staging="$(mktemp -d)"
    mkdir -p "$staging/.agents/skills"
    if ! (unset OPENCLAW_HOME; export HOME="$staging"; "$agent" skill --install); then
      rm -rf "$staging"
      fail 'official Agent Reach skill registration failed'
    fi
    if [[ ! -f "$staging/.agents/skills/agent-reach/SKILL.md" ]]; then
      rm -rf "$staging"
      fail 'official registration did not produce the expected Agent Reach skill'
    fi
    mkdir -p "$target"
    # Copy only absent packaged files, preserving any partial/custom target.
    python3 - "$staging/.agents/skills/agent-reach" "$target" <<'PY_COPY'
import pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
for path in source.rglob('*'):
    destination = target / path.relative_to(source)
    if path.is_dir():
        destination.mkdir(parents=True, exist_ok=True)
    elif not destination.exists():
        shutil.copy2(path, destination)
PY_COPY
    rm -rf "$staging"
  fi
  [[ -f "$target/SKILL.md" ]] || fail 'Agent Reach skill target is missing'
  if ! python3 - "$target/SKILL.md" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
start = '<!-- BEGIN ez_tools Douyin routing -->'
end = '<!-- END ez_tools Douyin routing -->'
if text.count(start) != text.count(end) or text.count(start) > 1:
    raise SystemExit('Malformed Douyin routing markers; resolve manually before retrying')
block = '''<!-- BEGIN ez_tools Douyin routing -->
## Douyin search via OpenCLI

For Douyin searches, use the official OpenCLI browser adapter:

```bash
opencli list
opencli douyin search --help
opencli doctor
opencli douyin search "keyword" --limit 10 -f json
```

`--limit` supports 1..30. Use the installer `check --query "keyword"` to verify
nonempty JSON results. Agent Reach doctor does not check a Douyin channel;
unrelated channel failures do not determine Douyin readiness.

Requires running Chrome with the official OpenCLI extension enabled and an
existing Douyin login in that browser. The extension daemon starts on demand.
If discovery/doctor/search fails, inspect its diagnostics, open Douyin in Chrome,
complete login manually and retry. Never export cookies or request credentials.
Search plays, comments and shares are placeholder zeros, not measured metrics.
<!-- END ez_tools Douyin routing -->
'''
if start in text:
    if text.index(start) > text.index(end):
        raise SystemExit('Inverted Douyin routing markers; resolve manually before retrying')
    after = text.index(end) + len(end)
    # Consume the managed block's trailing newline without touching custom text.
    if text[after:after + 1] == '\n':
        after += 1
    updated = text[:text.index(start)] + block + text[after:]
else:
    updated = text + '\n\n' + block
if updated != text:
    p.write_text(updated)
PY
  then fail 'could not update Douyin skill routing'; fi
}

node_check
select_tools
if [[ "$command_name" == install ]]; then
  command -v python3 >/dev/null 2>&1 || fail 'Python >=3.10 is required to register the skill'
  if [[ -z "$agent" ]]; then
    python3 -c 'import sys; sys.exit(sys.version_info < (3,10))' || fail 'Python >=3.10 is required to install Agent Reach'
    # Avoid repairing/overwriting an existing broken environment without consent.
    [[ ! -e "$HOME/.agent-reach-venv" ]] || fail 'existing Agent Reach venv is not working; repair or move it manually'
    python3 -m venv "$HOME/.agent-reach-venv"
    "$HOME/.agent-reach-venv/bin/python" -m pip install 'https://github.com/Panniantong/agent-reach/archive/main.zip'
    agent="$agent_managed"
    "$agent" --version >/dev/null || fail 'Agent Reach installation did not produce a working command'
  fi
  if [[ -z "$opencli" ]]; then
    [[ ! -e "$opencli_managed" && ! -e "$HOME/.agent-reach/tools/opencli/node_modules/@jackwener/opencli" ]] || fail 'existing managed OpenCLI lacks Douyin search; update or repair it manually'
    command -v npm >/dev/null 2>&1 || fail 'missing required command: npm (install it manually)'
    npm install --prefix "$HOME/.agent-reach/tools/opencli" @jackwener/opencli
    opencli="$opencli_managed"
    "$opencli" douyin search --help >/dev/null || fail 'installed OpenCLI has no Douyin search adapter'
  fi
  [[ "$agent" != "$agent_managed" ]] || wrapper agent-reach "$agent_managed"
  [[ "$opencli" != "$opencli_managed" ]] || wrapper opencli "$opencli_managed"
  register_skill
  cat <<'INFO'
Software installed/reused and Douyin skill registered. Search has not been verified.
Add user-local wrappers to this shell if needed: export PATH="$HOME/.local/bin:$PATH"
Install/enable the official OpenCLI Chrome extension:
https://chromewebstore.google.com/detail/opencli/ildkmabpimmkaediidaifkhjpohdnifk
Keep Chrome running; open https://www.douyin.com/ and log in manually.
Then run: ./install_agent_reach_douyin.sh check --query "keyword"
INFO
else
  [[ -n "$agent" ]] || fail 'working agent-reach not found; run install first'
  [[ -n "$opencli" ]] || fail 'OpenCLI Douyin search adapter not found; run install or inspect opencli list / douyin search --help'
  doctor_report="$("$opencli" doctor)" || {
    printf '%s\n' "$doctor_report"
    fail 'OpenCLI doctor failed: check Chrome, extension connection and manual Douyin login'
  }
  printf '%s\n' "$doctor_report"
  # Upstream doctor can exit zero for missing connections; require positive probes.
  [[ "$doctor_report" == *'[OK] Daemon: running'* &&
     "$doctor_report" == *'[OK] Extension: connected'* &&
     "$doctor_report" == *'[OK] Connectivity: connected'* ]] ||
    fail 'OpenCLI browser bridge was not verified; inspect doctor diagnostics and check Chrome / extension / profile selection'
  if [[ -n "$query" ]]; then
    command -v python3 >/dev/null 2>&1 || fail 'Python is required to validate search JSON'
    result="$(mktemp)"
    trap 'rm -f "$result"' EXIT
    "$opencli" douyin search "$query" --limit 10 -f json > "$result" || fail 'Douyin search failed: inspect adapter diagnostics for bridge/authentication/timeout errors'
    python3 - "$result" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as f:
        result = json.load(f)
except (ValueError, OSError) as exc:
    raise SystemExit('Search must return valid JSON: ' + str(exc))
# JSON mode returns rows as an array; metadata/error objects are not search rows.
if not isinstance(result, list) or not result:
    raise SystemExit('Search must return a nonempty JSON array of result objects')
for row in result:
    if (not isinstance(row, dict) or not isinstance(row.get('desc'), str)
            or not row['desc'].strip() or not isinstance(row.get('url'), str)
            or not re.fullmatch(r'https://www\.douyin\.com/video/[0-9]+', row['url'])):
        raise SystemExit('Search JSON must contain usable Douyin rows with desc and video url')
PY
    printf 'Douyin search verified: nonempty valid JSON returned.\n'
  else
    printf 'Software and browser bridge checks passed. Search has not been verified; use check --query "keyword".\n'
  fi
fi
