#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/install_agent_reach_douyin.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" LOG="$tmp/log" PATH="$tmp/bin:/usr/bin:/bin"
mkdir -p "$HOME/.agents/skills/agent-reach" "$tmp/bin"
printf 'custom skill\n<!-- BEGIN ez_tools Douyin routing -->\nstale commands\n<!-- END ez_tools Douyin routing -->\ncustom footer\n' > "$HOME/.agents/skills/agent-reach/SKILL.md"
cat > "$tmp/bin/node" <<'MOCK'
#!/bin/bash
echo "${NODE_VERSION:-v20.18.1}"
MOCK
cat > "$tmp/bin/agent-reach" <<'MOCK'
#!/bin/bash
echo "agent $*" >> "$LOG"
if [[ "$*" == '--version' ]]; then echo agent-reach; exit 0; fi
if [[ "$*" == 'skill --install' ]]; then
 mkdir -p "$HOME/.agents/skills/agent-reach"
 echo upstream > "$HOME/.agents/skills/agent-reach/SKILL.md"
 exit 0
fi
exit 99
MOCK
cat > "$tmp/bin/opencli" <<'MOCK'
#!/bin/bash
echo "opencli $*" >> "$LOG"
case "$*" in
 'douyin search --help') exit "${ADAPTER_STATUS:-0}" ;;
 doctor) printf '%s\n' "${DOCTOR_MESSAGE:-[OK] Daemon: running
[OK] Extension: connected (v1.0.0)
[OK] Connectivity: connected in 0.1s}"; exit "${DOCTOR_STATUS:-0}" ;;
 'douyin search '*) if [[ -v SEARCH_RESULT ]]; then printf '%s\n' "$SEARCH_RESULT"; else echo '[{"desc":"example","url":"https://www.douyin.com/video/123456"}]'; fi; exit "${SEARCH_STATUS:-0}" ;;
 *) exit 99 ;;
esac
MOCK
chmod +x "$tmp/bin/"*
contains() { [[ "$1" == *"$2"* ]] || { printf 'Missing: %s\nOutput: %s\n' "$2" "$1" >&2; exit 1; }; }
fails() {
 local result
 if result="$("$script" "$@" 2>&1)"; then echo 'Expected failure' >&2; exit 1; fi
 contains "$result" "$EXPECTED"
}
output="$("$script" install)"
contains "$output" 'Search has not been verified'
contains "$(cat "$HOME/.agents/skills/agent-reach/SKILL.md")" 'custom skill'
contains "$(cat "$HOME/.agents/skills/agent-reach/SKILL.md")" 'opencli douyin search'
contains "$(cat "$HOME/.agents/skills/agent-reach/SKILL.md")" 'custom footer'
[[ "$(cat "$HOME/.agents/skills/agent-reach/SKILL.md")" != *'stale commands'* ]]
cp "$HOME/.agents/skills/agent-reach/SKILL.md" "$tmp/skill"
"$script" install > /dev/null
cmp "$tmp/skill" "$HOME/.agents/skills/agent-reach/SKILL.md"
[[ "$(cat "$LOG")" != *'skill --install'* ]]
"$script" check --query example > /dev/null
export SEARCH_RESULT='[]' EXPECTED='nonempty'
fails check --query example
export SEARCH_RESULT='not json' EXPECTED='valid JSON'
fails check --query example
export SEARCH_RESULT='[{"error":"authentication required"}]' EXPECTED='usable Douyin rows'
fails check --query example
unset SEARCH_RESULT
export DOCTOR_STATUS=1 DOCTOR_MESSAGE='bridge unavailable' EXPECTED='bridge unavailable'
fails check
unset DOCTOR_STATUS DOCTOR_MESSAGE
export DOCTOR_MESSAGE=$'[OK] Daemon: running\n[MISSING] Extension: not connected\n[FAIL] Connectivity: failed' EXPECTED='browser bridge was not verified'
fails check
unset DOCTOR_MESSAGE
export SEARCH_STATUS=1 EXPECTED='search failed'
fails check --query example
unset SEARCH_STATUS
export NODE_VERSION=v20.18.0 EXPECTED='20.18.1'
fails install
unset NODE_VERSION
# Force managed OpenCLI selection and ensure an unrelated wrapper is preserved.
mkdir -p "$HOME/.agent-reach/tools/opencli/node_modules/.bin" "$HOME/.local/bin"
cp "$tmp/bin/opencli" "$HOME/.agent-reach/tools/opencli/node_modules/.bin/opencli"
mv "$tmp/bin/opencli" "$tmp/opencli"
printf '#!/bin/bash\necho custom\n' > "$HOME/.local/bin/opencli"
export EXPECTED='unmanaged'
fails install
contains "$(cat "$HOME/.local/bin/opencli")" 'echo custom'
# Existing managed installation creates a stable wrapper; repeat never installs/upgrades.
rm "$HOME/.local/bin/opencli"
"$script" install > /dev/null
"$HOME/.local/bin/opencli" douyin search --help
"$script" install > /dev/null
# Missing skill is registered in isolated HOME, preserving other client skills.
rm "$HOME/.agents/skills/agent-reach/SKILL.md"
mkdir -p "$HOME/.claude/skills/agent-reach"
echo claude-custom > "$HOME/.claude/skills/agent-reach/SKILL.md"
"$script" install > /dev/null
contains "$(cat "$HOME/.agents/skills/agent-reach/SKILL.md")" upstream
contains "$(cat "$HOME/.claude/skills/agent-reach/SKILL.md")" claude-custom
mv "$tmp/bin/node" "$tmp/node"
# Exclude system node while retaining shell helpers.
mkdir "$tmp/minbin"
for name in bash dirname mkdir mktemp cp rm cat chmod mv python3; do ln -s "$(command -v "$name")" "$tmp/minbin/$name"; done
export EXPECTED='Node.js'
PATH="$tmp/minbin" fails install
# Fresh installation is simulated, including Python venv/pip and npm prefix.
export PATH="$tmp/bin:/usr/bin:/bin"
mv "$tmp/node" "$tmp/bin/node"
export HOME="$tmp/fresh-home" AGENT_TEMPLATE="$tmp/bin/agent-reach" OPENCLI_TEMPLATE="$tmp/opencli"
mkdir -p "$HOME"
mv "$tmp/bin/agent-reach" "$tmp/agent-template"
export AGENT_TEMPLATE="$tmp/agent-template"
export REAL_PYTHON="$(command -v python3)"
cat > "$tmp/bin/python3" <<'MOCK'
#!/bin/bash
if [[ "$1" == -m && "$2" == venv ]]; then
 echo "venv $3" >> "$LOG"
 mkdir -p "$3/bin"
 cp "$AGENT_TEMPLATE" "$3/bin/agent-reach"
 cat > "$3/bin/python" <<'PIP'
#!/bin/bash
printf 'pip %s\n' "$*" >> "$LOG"
PIP
 chmod +x "$3/bin/python"
else
 exec "$REAL_PYTHON" "$@"
fi
MOCK
cat > "$tmp/bin/npm" <<'MOCK'
#!/bin/bash
echo "npm $*" >> "$LOG"
[[ "$1" == install && "$2" == --prefix && "$4" == @jackwener/opencli ]] || exit 99
mkdir -p "$3/node_modules/.bin"
cp "$OPENCLI_TEMPLATE" "$3/node_modules/.bin/opencli"
MOCK
chmod +x "$tmp/bin/python3" "$tmp/bin/npm"
"$script" install > /dev/null
contains "$(cat "$LOG")" 'https://github.com/Panniantong/agent-reach/archive/main.zip'
contains "$(cat "$LOG")" 'npm install --prefix'
"$HOME/.local/bin/agent-reach" --version > /dev/null
"$HOME/.local/bin/opencli" douyin search --help
cp "$LOG" "$tmp/before-repeat"
"$script" install > /dev/null
[[ "$(/usr/bin/grep -c -E '^(venv|pip|npm) ' "$LOG")" == "$(/usr/bin/grep -c -E '^(venv|pip|npm) ' "$tmp/before-repeat")" ]]
# Python version and npm are required only for missing tool installation.
export HOME="$tmp/missing-python-home"
cat > "$tmp/bin/python3" <<'MOCK'
#!/bin/bash
exit 1
MOCK
export EXPECTED='Python >=3.10'
fails install
rm "$tmp/bin/python3"
export HOME="$tmp/missing-npm-home"
mkdir -p "$HOME"
cp "$AGENT_TEMPLATE" "$tmp/bin/agent-reach"
mv "$tmp/bin/npm" "$tmp/npm"
export EXPECTED='npm'
PATH="$tmp/bin:$tmp/minbin" fails install
printf 'All Agent Reach Douyin installer tests passed.\n'
