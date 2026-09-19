#!/usr/bin/env bash

set -euo pipefail

TAG='[install-fcitx5-pinyin]'
PACKAGES=(fcitx5 fcitx5-data fcitx5-chinese-addons fcitx5-config-qt fcitx5-frontend-all im-config fcitx5-rime librime-plugin-lua librime-bin git python3 python3-yaml)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fcitx5"
RIME_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime"
THEME_NAME=mellow-vermilion
THEME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/themes/$THEME_NAME"

usage() {
  cat <<'EOF'
Usage: ./install_fcitx5_pinyin.sh [install|configure|status|help] [--yes]

Install Fcitx5 with Rime Ice (full Pinyin) on Ubuntu/Debian APT systems.
Selects Mellow Vermilion and sets candidate font size to 1.6 times its initial size.
install and configure set Fcitx5 as the current user default input framework.
Log out and back in for applications to inherit the input framework setting.
Comma/period turn candidate pages in Rime Ice. Existing input methods are retained.
Running install again updates Rime Ice and Mellow.
Run it as the desktop user, never with sudo.  No command means install.
configure repairs an existing installation without APT, downloads or compilation.
--yes confirms that pending input is committed and permits a session restart.
Close Fcitx5 configuration windows before applying changes.
EOF
}

log() { printf '%s %s\n' "$TAG" "$*"; }
die() { printf '%s ERROR: %s\n' "$TAG" "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

check_target_user() {
  [[ "$(id -u)" != 0 ]] || die 'do not run this script as root or with sudo; run it as the target desktop user'
}

check_apt_system() {
  need_cmd apt-get
  need_cmd dpkg-query
  [[ -r /etc/os-release ]] || die 'could not determine Linux distribution from /etc/os-release'
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-} ${ID_LIKE:-}" in
    *ubuntu*|*debian*) ;;
    *) die "this script only supports Ubuntu/Debian APT systems; detected ID=${ID:-unknown}" ;;
  esac
}

package_installed() {
  dpkg-query -W -f='${Status}\n' "$1" 2>/dev/null | grep -qx 'install ok installed'
}

backup_if_existing() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  cp -p -- "$file" "${file}.bak.$(date +%Y%m%d%H%M%S%N)"
}

replace_if_changed() {
  local destination="$1" source="$2"
  mkdir -p "$(dirname "$destination")"
  if [[ -f "$destination" ]] && cmp -s "$destination" "$source"; then
    rm -f -- "$source"
    return 0
  fi
  backup_if_existing "$destination"
  mv -- "$source" "$destination"
}

upsert_key_content() {
  local input="$1" output="$2" section="$3" key="$4" value="$5"
  if [[ -f "$input" ]]; then
    awk -v wanted_section="$section" -v wanted_key="$key" -v wanted_value="$value" '
      BEGIN { inside = (wanted_section == ""); seen = inside }
      function emit_missing() { if (inside && !found) print wanted_key "=" wanted_value }
      /^\[/ {
        emit_missing(); inside = ($0 == "[" wanted_section "]");
        if (inside) seen = 1;
        print; next
      }
      {
        if (inside && $0 ~ "^" wanted_key "=") {
          if (!found) print wanted_key "=" wanted_value;
          found = 1; next
        }
        print
      }
      END {
        emit_missing();
        if (!seen) {
          print "";
          if (wanted_section != "") print "[" wanted_section "]";
          print wanted_key "=" wanted_value
        }
      }
    ' "$input" >"$output"
  else
    if [[ -n "$section" ]]; then
      printf '[%s]\n%s=%s\n' "$section" "$key" "$value" >"$output"
    else
      printf '%s=%s\n' "$key" "$value" >"$output"
    fi
  fi
}

upsert_keys() {
  local file="$1" section key value current next
  shift
  current="$(mktemp)"
  if [[ -f "$file" ]]; then cp -- "$file" "$current"; else : >"$current"; fi
  while [[ $# -gt 0 ]]; do
    section="$1" key="$2" value="$3"
    shift 3
    next="$(mktemp)"
    upsert_key_content "$current" "$next" "$section" "$key" "$value"
    rm -f -- "$current"
    current="$next"
  done
  replace_if_changed "$file" "$current"
}

# Prepare the font and persistent baseline without changing live configuration.
prepare_candidate_font() {
  /usr/bin/python3 - "$CONFIG_DIR/conf/classicui.conf" "$CONFIG_DIR/candidate-font.json" "$1" <<'PYFONT'
import json
import pathlib
import re
import sys
from decimal import Decimal

config, state, output = map(pathlib.Path, sys.argv[1:])

def scaled(font, factor="1.6"):
    match = re.fullmatch(r"(.+?)\s+([0-9]+(?:\.[0-9]+)?)(px)?", font.strip())
    if not match or Decimal(match[2]) <= 0:
        raise ValueError("candidate font must end with a positive numeric size")
    size = format(Decimal(match[2]) * Decimal(factor), "f")
    if "." in size:
        size = size.rstrip("0").rstrip(".")
    return f"{match[1]} {size}{match[3] or ''}"

try:
    if state.exists():
        record = json.loads(state.read_text())
        if (not isinstance(record, dict) or record.get("version") not in (1, 2)
                or not isinstance(record.get("original"), str)
                or record.get("target") != scaled(record["original"], "2" if record["version"] == 1 else "1.6")):
            raise ValueError("invalid candidate font baseline")
        record = {"version": 2, "original": record["original"],
                  "target": scaled(record["original"])}
    else:
        font = "Sans 10"
        if config.exists():
            for line in config.read_text().splitlines():
                if line.strip().startswith("["):
                    break
                match = re.match(r"^\s*Font\s*=\s*(.*?)\s*$", line)
                if match:
                    font = match[1]
                    break
        record = {"version": 2, "original": font, "target": scaled(font)}
    (output / "candidate-font.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    (output / "candidate-font.txt").write_text(record["target"])
except (OSError, ValueError, TypeError) as error:
    sys.exit("Cannot prepare candidate font: " + str(error))
PYFONT
}

create_or_merge_profile() {
  local profile="${CONFIG_DIR}/profile" tmp target_group max_item preferred_group next
  mkdir -p "$CONFIG_DIR"
  tmp="$(mktemp)"
  if [[ ! -f "$profile" ]]; then
    cat >"$tmp" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[GroupOrder]
0=Default
EOF
  else
    preferred_group="$(awk '/^\[/ { inside = ($0 == "[GroupOrder]") } inside && /^0=/ { sub(/^0=/, ""); print; exit }' "$profile")"
    target_group="$(awk -v preferred="$preferred_group" '
      /^\[/ { in_group = 0 }
      /^\[Groups\/[0-9]+\]$/ {
        group = $0
        sub(/^\[Groups\//, "", group)
        sub(/\]$/, "", group)
        if (first == "") first = group
        in_group = 1
        next
      }
      in_group && /^Name=/ && substr($0, 6) == preferred { print group; found = 1; exit }
      END { if (!found && first != "") print first }
    ' "$profile")"

    if [[ -z "$target_group" ]]; then
      cat "$profile" >"$tmp"
      cat >>"$tmp" <<'EOF'

[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[GroupOrder]
0=Default
EOF
    elif awk -v group="$target_group" '
      /^\[/ { in_target = (index($0, "[Groups/" group "/Items/") == 1) }
      in_target && /^Name=rime$/ { found = 1 }
      END { exit !found }
    ' "$profile"; then
      cp -- "$profile" "$tmp"
    else
      max_item="$(awk -v group="$target_group" '
        index($0, "[Groups/" group "/Items/") == 1 {
          item = $0
          sub("^\\[Groups/" group "/Items/", "", item)
          sub(/\]$/, "", item)
          if (item ~ /^[0-9]+$/ && item + 0 > max) max = item + 0
          saw = 1
        }
        END { if (saw) print max; else print -1 }
      ' "$profile")"
      cat "$profile" >"$tmp"
      printf '\n[Groups/%s/Items/%s]\nName=rime\nLayout=\n' \
        "$target_group" "$((max_item + 1))" >>"$tmp"
    fi
  fi
  if [[ -n "${target_group:-}" ]]; then
    next="$(mktemp)"
    upsert_key_content "$tmp" "$next" "Groups/$target_group" DefaultIM rime
    mv -- "$next" "$tmp"
  fi
  replace_if_changed "$profile" "$tmp"
}

rime_build_present() {
  local root="$1"
  [[ -s "$root/build/rime_ice.schema.yaml" &&
     -s "$root/build/rime_ice.table.bin" &&
     -s "$root/build/rime_ice.prism.bin" ]]
}

# Preparation and all read-only checks share the same resource contract.
theme_present() { theme_resources "$1"; }
prepare_theme() { theme_resources "$1" "${2:-/usr/share/fcitx5/themes/default}"; }

theme_resources() {
  /usr/bin/python3 - "$@" <<'PYTHEME'
import configparser
import pathlib
import re
import shutil
import sys

try:
    root = pathlib.Path(sys.argv[1])
    fallback = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
    config = configparser.ConfigParser(interpolation=None, strict=True)
    with (root / "theme.conf").open(encoding="utf-8", newline="") as stream:
        original = stream.read()
    config.read_string(original)
    if not config.has_section("InputPanel/Background"):
        raise ValueError("theme.conf: missing [InputPanel/Background]")
    defaults = {
        "Menu/CheckBox": ("radio.png", "ez-tools-menu-checkbox.png"),
        "Menu/SubMenu": ("arrow.png", "ez-tools-menu-submenu.png"),
    }
    repairs = {}
    for name, section in config.items():
        for key in ("image", "overlay"):
            value = section.get(key, "").strip().strip('"')
            if not value:
                continue
            label = f"[{name}] {key}={value}"
            image = pathlib.Path(value)
            if image.is_absolute() or ".." in image.parts:
                raise ValueError(f"{label}: unsafe resource path")
            target = root / image
            if any(p.is_symlink() for p in (target, *target.parents)):
                raise ValueError(f"{label}: symbolic link is not allowed")
            if target.is_file() and target.stat().st_size:
                continue
            if target.exists():
                raise ValueError(f"{label}: resource is empty or not a regular file")
            if fallback is None or key != "image" or name not in defaults:
                raise ValueError(f"{label}: resource is missing")
            source_name, destination = defaults[name]
            source = fallback / source_name
            if not source.is_file() or not source.stat().st_size:
                raise ValueError(f"{label}: default theme resource {source_name} is missing or empty")
            if (root / destination).exists() or (root / destination).is_symlink():
                raise ValueError(f"{label}: fallback destination {destination} already exists")
            repairs[name] = (source, destination, label)
    # Validate everything before modifying the isolated stage. Preserve comments,
    # key spelling and unrelated settings instead of serializing ConfigParser.
    lines = original.splitlines(keepends=True)
    current = None
    replaced = set()
    for index, line in enumerate(lines):
        section = re.match(r"^\s*\[([^]]+)\]", line)
        if section:
            current = section.group(1)
        elif current in repairs:
            match = re.match(r"^(\s*image\s*[=:]\s*)[^\r\n]*(\r?\n)?$", line, re.I)
            if match:
                lines[index] = match[1] + repairs[current][1] + (match[2] or "")
                replaced.add(current)
    if replaced != set(repairs):
        raise ValueError("theme.conf: cannot safely rewrite menu Image entries")
    for source, destination, label in repairs.values():
        shutil.copyfile(source, root / destination)
        print(f"[install-fcitx5-pinyin] {label}: using default theme {source.name} as {destination}")
    if repairs:
        with (root / "theme.conf").open("w", encoding="utf-8", newline="") as stream:
            stream.write("".join(lines))
except (OSError, ValueError, configparser.Error) as error:
    print(f"[install-fcitx5-pinyin] theme validation: {error}", file=sys.stderr)
    sys.exit(1)
PYTHEME
}

paging_present() {
  /usr/bin/python3 - "$1/build/rime_ice.schema.yaml" <<'PYCHECK'
import pathlib
import sys
import yaml
try:
    config = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
    bindings = config["key_binder"]["bindings"]
    for key, action in (("comma", "Page_Up"), ("period", "Page_Down")):
        matching = [b for b in bindings if b.get("accept") == key]
        assert matching and all(b.get("when") == "has_menu" and
                                b.get("send") == action for b in matching)
except (OSError, TypeError, KeyError, AttributeError, AssertionError, yaml.YAMLError):
    sys.exit(1)
PYCHECK
}

merge_paging() {
  /usr/bin/python3 - "$1/rime_ice.custom.yaml" <<'PYPATCH'
import pathlib
import sys
import yaml

# Reject duplicate keys rather than silently discarding a user's settings.
class UniqueLoader(yaml.SafeLoader):
    pass

def mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError("duplicate YAML key")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result

UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
path = pathlib.Path(sys.argv[1])
try:
    original = path.read_text() if path.is_file() else ""
    config = yaml.load(original, Loader=UniqueLoader) if original else {}
    if config is None:
        config = {}
    if not isinstance(config, dict):
        raise ValueError("custom configuration must be a mapping")
    patch = config.setdefault("patch", {})
    if not isinstance(patch, dict):
        raise ValueError("patch must be a mapping")
    supported = {"key_binder/bindings", "key_binder/bindings/+"}
    relevant = [k for k in patch if str(k).startswith("key_binder")]
    if any(k not in supported for k in relevant) or len(relevant) > 1 or "__patch" in patch:
        raise ValueError("complex key_binder patch requires manual merging")
    key = relevant[0] if relevant else "key_binder/bindings/+"
    bindings = patch.get(key, [])
    if not isinstance(bindings, list) or any(not isinstance(b, dict) for b in bindings):
        raise ValueError("bindings must be a list of mappings")
    bindings = [b for b in bindings if b.get("accept") not in ("comma", "period")]
    bindings.extend([
        {"when": "has_menu", "accept": "comma", "send": "Page_Up"},
        {"when": "has_menu", "accept": "period", "send": "Page_Down"},
    ])
    patch[key] = bindings
    # Keep bytes unchanged when the parsed configuration already has our rules.
    if not original or yaml.load(original, Loader=UniqueLoader) != config:
        path.write_text(yaml.safe_dump(config, allow_unicode=True, sort_keys=False))
except (OSError, ValueError, TypeError, yaml.YAMLError) as error:
    sys.exit("Cannot safely merge Rime paging configuration: " + str(error))
PYPATCH
}

custom_fingerprint() {
  local file
  for file in default.custom.yaml rime_ice.custom.yaml; do
    if [[ -f "$RIME_DATA_DIR/$file" ]]; then
      sha256sum "$RIME_DATA_DIR/$file"
    else
      printf 'missing %s\n' "$file"
    fi
  done
}

# Build in isolation: a download or compilation error cannot overwrite live data.
install_rime_ice() (
  local work source stage destination file relative revision manifest custom_before theme_stage
  local -a existing_schemas=()
  destination="${RIME_DATA_DIR}"
  need_cmd git
  need_cmd rime_deployer
  work="$(mktemp -d)"
  trap 'rm -rf -- "$work"' EXIT
  source="$work/source"
  stage="$work/stage"
  manifest="$work/files"
  : >"$manifest"
  git clone --quiet --depth 1 https://github.com/iDvel/rime-ice.git "$source"
  revision="$(git -C "$source" rev-parse HEAD)"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || die 'invalid upstream revision'
  for file in default.yaml rime_ice.schema.yaml rime_ice.dict.yaml melt_eng.dict.yaml; do
    [[ -s "$source/$file" ]] || die "incomplete Rime Ice download: $file"
  done
  for file in cn_dicts en_dicts lua opencc; do
    [[ -d "$source/$file" ]] || die "incomplete Rime Ice download: $file"
  done
  # Do not follow user or upstream symlinks when copying and publishing files.
  if [[ -L "$destination" ]] ||
     [[ -n "$(find "$source" -type l -print -quit)" ]] ||
     { [[ -d "$destination" ]] && [[ -n "$(find "$destination" -type l -print -quit)" ]]; }; then
    die 'Rime data contains symlinks; use a regular directory before installing'
  fi
  custom_before="$(custom_fingerprint)"
  git clone --quiet --depth 1 https://github.com/sanweiya/fcitx5-mellow-themes.git "$work/mellow"
  theme_stage="$work/mellow/$THEME_NAME"
  [[ -z "$(find "$work/mellow" -type l -print -quit)" ]] || die 'theme download contains symlinks'
  prepare_theme "$theme_stage" || die 'could not prepare Mellow theme resources'
  theme_present "$theme_stage" || die 'Mellow theme resources are missing or invalid'
  [[ -s "$work/mellow/LICENSE" ]] || die 'Mellow license is missing'
  cp -- "$work/mellow/LICENSE" "$theme_stage/LICENSE"
  git -C "$work/mellow" rev-parse HEAD >"$theme_stage/.mellow-version"
  mkdir -p "$stage"
  if [[ -d "$destination" ]]; then cp -a "$destination/." "$stage/"; fi
  # Capture the effective list before replacing default.yaml. --add-schema only
  # extends the custom patch, which otherwise hides schemas inherited from defaults.
  /usr/bin/python3 - "$stage" >"$work/schemas" <<'PY'
import pathlib
import sys
import yaml

root = pathlib.Path(sys.argv[1])

def read(path):
    return yaml.safe_load(path.read_text()) or {} if path.is_file() else {}

custom = read(root / "default.custom.yaml").get("patch", {}) or {}
if "schema_list" in custom:
    schemas = custom["schema_list"]
else:
    for path in (root / "build/default.yaml", root / "default.yaml",
                 pathlib.Path("/usr/share/rime-data/default.yaml")):
        config = read(path)
        if "schema_list" in config:
            schemas = config["schema_list"]
            break
    else:
        schemas = []
for entry in schemas or []:
    sys.stdout.write(str(entry["schema"]) + "\0")
PY
  mapfile -d '' -t existing_schemas <"$work/schemas"
  # Only install input data, never upstream scripts, Git metadata or prebuilt files.
  while IFS= read -r -d '' file; do
    relative="${file#"$source/"}"
    case "$relative" in
      *.custom.yaml|user.yaml|installation.yaml) continue ;;
      custom_phrase.txt)
        [[ ! -e "$stage/$relative" ]] || continue ;;
    esac
    mkdir -p "$(dirname "$stage/$relative")"
    cp -- "$file" "$stage/$relative"
    printf '%s\0' "$relative" >>"$manifest"
  done < <(find "$source" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.txt' -o -name '*.lua' \) -print0)
  for file in cn_dicts en_dicts lua opencc; do
    cp -a "$source/$file" "$stage/"
  done
  while IFS= read -r -d '' file; do
    printf '%s\0' "${file#"$source/"}" >>"$manifest"
  done < <(find "$source/cn_dicts" "$source/en_dicts" "$source/lua" "$source/opencc" -type f -print0)
  printf '%s\n' "$revision" >"$stage/.rime-ice-version"
  (
    cd "$stage"
    rime_deployer --add-schema "${existing_schemas[@]}" rime_ice
    rime_deployer --set-active-schema rime_ice
  )
  merge_paging "$stage"
  printf '%s\0' .rime-ice-version default.custom.yaml user.yaml rime_ice.custom.yaml >>"$manifest"
  # Always redeploy: custom inputs may have changed since the last successful build,
  # even when the downloaded resources match the live directory.
  # Discard copied build artifacts so they cannot mask a failed compilation.
  rm -rf -- "$stage/build"
  rime_deployer --build "$stage" /usr/share/rime-data "$stage/build"
  rime_build_present "$stage" || die 'Rime Ice deployment did not produce the required dictionary files'
  # Only publish managed resources and fresh build files, never copied user DBs,
  # sync data or unrelated files that may have changed while compilation ran.
  while IFS= read -r -d '' file; do
    printf '%s\0' "${file#"$stage/"}" >>"$manifest"
  done < <(find "$stage/build" -type f -print0)
  paging_present "$stage" || die 'compiled Rime Ice paging rules are missing or conflicting'
  apply_session "$stage" "$manifest" "$custom_before" "$theme_stage"
  log "Rime Ice deployed: $revision"
)

# All live writes share this lifecycle, including repair-only configuration.
remote() { timeout 2 fcitx5-remote "$@"; }
checked_pgrep() {
  local result
  if pgrep -u "$(id -u)" "$@" >/dev/null; then return 0; else result=$?; fi
  [[ "$result" == 1 ]] || die 'could not inspect session processes'
  return 1
}
process_running() { checked_pgrep -x fcitx5; }
config_window_running() {
  checked_pgrep -f '(^|/)(fcitx5-config-qt|fcitx5-configtool)([[:space:]]|$)' >/dev/null
}
bus_owned() {
  local reply
  reply="$(timeout 2 dbus-send --session --type=method_call --print-reply \
    --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.NameHasOwner string:org.fcitx.Fcitx5 2>/dev/null)" || return 2
  case "$reply" in
    *'boolean true'*) return 0 ;;
    *'boolean false'*) return 1 ;;
    *) return 2 ;;
  esac
}

apply_session() (
  local stage="${1:-}" manifest="${2:-}" custom_before="${3:-}" theme_stage="${4:-}" file relative answer bus_state
  local desktop=False stopped=False phase=prepare snapshot deadline group live_group live_im candidate_font
  local -a managed=("$CONFIG_DIR/profile" "$CONFIG_DIR/conf/classicui.conf" "$CONFIG_DIR/candidate-font.json"
    "$RIME_DATA_DIR/user.yaml" "$RIME_DATA_DIR/default.custom.yaml" "$RIME_DATA_DIR/rime_ice.custom.yaml" "$RIME_DATA_DIR/build/rime_ice.schema.yaml" "$HOME/.xinputrc")
  for file in timeout dbus-send pgrep fcitx5-remote fcitx5 rime_deployer im-config /usr/bin/python3; do need_cmd "$file"; done
  snapshot="$(mktemp -d)"
  # EXIT also handles set -e failures; activation failures intentionally keep config.
  cleanup_session() {
    local result=$? i
    trap - EXIT
    if [[ "$phase" == writing && "$result" != 0 ]]; then
      for i in "${!managed[@]}"; do
        if [[ -f "$snapshot/$i" ]]; then
          cp -p -- "$snapshot/$i" "${managed[$i]}" || log 'WARNING: configuration restore failed'
        else
          rm -f -- "${managed[$i]}" || log 'WARNING: configuration restore failed'
        fi
      done
      log 'Configuration write failed; restored pre-write configuration where possible.'
    fi
    if [[ "$stopped" == True && "$phase" != activating && "$phase" != complete ]]; then
      timeout 10 fcitx5 -d 9>&- >/dev/null 2>&1 || log 'WARNING: could not restore the original session'
    fi
    if [[ "$result" != 0 && "$phase" != prepare ]]; then
      log 'Recovery: close configuration windows, exit Fcitx5 and wait for it to stop before restoring .bak files; then start fcitx5 -d.'
      log 'Installed resources are retained. Run configure again to retry activation.'
    fi
    rm -rf -- "$snapshot"
    exit "$result"
  }
  trap cleanup_session EXIT
  config_window_running && die 'close Fcitx5 configuration windows before continuing'
  if bus_owned; then bus_state=0; else bus_state=$?; fi
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then desktop=True; fi
  if process_running || [[ "$bus_state" == 0 ]]; then
    [[ "$bus_state" == 0 ]] || die 'Fcitx5 is running but its session D-Bus cannot be reached; no configuration was written'
    [[ "$desktop" == True ]] || die 'run from the desktop session to restart Fcitx5'
    if [[ "$ASSUME_YES" != True ]]; then
      [[ -t 0 ]] || die 'session restart requires interactive confirmation or --yes after committing pending input'
      printf '%s Commit pending input and close configuration windows. Restart Fcitx5 now? [y/N] ' "$TAG"
      read -r answer || die 'confirmation cancelled'
      [[ "$answer" == y || "$answer" == Y ]] || die 'confirmation declined'
    fi
    config_window_running && die 'close Fcitx5 configuration windows before continuing'
    remote -e || die 'could not request Fcitx5 exit; no configuration was written'
    deadline=$((SECONDS + 10))
    while :; do
      if bus_owned; then bus_state=0; else bus_state=$?; fi
      [[ "$bus_state" != 2 ]] || die 'lost D-Bus connection while waiting for exit; no configuration was written'
      if ! process_running && [[ "$bus_state" == 1 ]]; then break; fi
      (( SECONDS < deadline )) || die 'Fcitx5 did not exit within 10 seconds; no configuration was written'
      sleep 0.2
    done
    stopped=True
  elif [[ "$desktop" == True && "$bus_state" == 2 ]]; then
    die 'desktop D-Bus is unavailable; no configuration was written'
  fi
  config_window_running && die 'a configuration window opened; no configuration was written'
  process_running && die 'Fcitx5 restarted unexpectedly; no configuration was written'
  # Snapshot only after the old process has finished saving its in-memory state.
  for file in "${managed[@]}"; do
    [[ ! -L "$file" && ! -d "$file" ]] || die 'managed configuration must be a regular file'
  done
  for relative in "${!managed[@]}"; do
    file="${managed[$relative]}"
    if [[ -f "$file" ]]; then cp -p -- "$file" "$snapshot/$relative"; fi
  done
  if [[ -n "$stage" && "$custom_before" != "$(custom_fingerprint)" ]]; then
    die 'Rime schema configuration changed during preparation; retry install to compile the latest settings'
  fi
  if [[ -n "$theme_stage" ]]; then
    [[ ! -L "$THEME_DIR" ]] || die 'theme destination must not be a symlink'
    file="$THEME_DIR"
    while [[ "$file" != / ]]; do
      [[ ! -L "$file" ]] || die 'theme destination contains a symlink'
      file="$(dirname "$file")"
    done
    if [[ -d "$THEME_DIR" ]]; then
      [[ -z "$(find "$THEME_DIR" -type l -print -quit)" ]] || die 'theme destination contains symlinks'
    fi
    while IFS= read -r -d '' file; do
      relative="${file#"$theme_stage/"}"
      case "$relative" in
        theme.conf|*.svg|*.png|LICENSE|.mellow-version)
          file="$THEME_DIR/$relative"
          [[ ! -d "$file" ]] || die 'theme resource destination is a directory'
          if [[ -f "$file" ]]; then cp -p -- "$file" "$snapshot/${#managed[@]}"; fi
          managed+=("$file") ;;
      esac
    done < <(find "$theme_stage" -type f -print0)
  fi
  prepare_candidate_font "$snapshot"
  candidate_font="$(cat "$snapshot/candidate-font.txt")"
  phase=writing
  if [[ -n "$theme_stage" ]]; then
    while IFS= read -r -d '' file; do
      relative="${file#"$theme_stage/"}"
      case "$relative" in
        theme.conf|*.svg|*.png|LICENSE|.mellow-version)
          replace_if_changed "$THEME_DIR/$relative" "$file" ;;
      esac
    done < <(find "$theme_stage" -type f -print0)
    theme_present "$THEME_DIR" || die 'published Mellow theme is incomplete'
  fi
  if [[ -n "$stage" ]]; then
    # The daemon may have saved user.yaml during exit. Preserve those new fields.
    if [[ -f "$RIME_DATA_DIR/user.yaml" ]]; then cp -p -- "$RIME_DATA_DIR/user.yaml" "$stage/user.yaml"; fi
    (cd "$stage"; rime_deployer --set-active-schema rime_ice)
    while IFS= read -r -d '' relative; do
      replace_if_changed "$RIME_DATA_DIR/$relative" "$stage/$relative"
    done <"$manifest"
  else
    mkdir -p "$snapshot/selection"
    if [[ -f "$RIME_DATA_DIR/user.yaml" ]]; then cp -p -- "$RIME_DATA_DIR/user.yaml" "$snapshot/selection/user.yaml"; fi
    (cd "$snapshot/selection"; rime_deployer --set-active-schema rime_ice)
    replace_if_changed "$RIME_DATA_DIR/user.yaml" "$snapshot/selection/user.yaml"
  fi
  im-config -n fcitx5
  create_or_merge_profile
  # Select the managed theme and stable scaled font, preserving other settings.
  if [[ ! -f "$CONFIG_DIR/conf/classicui.conf" ]]; then
    upsert_keys "$CONFIG_DIR/conf/classicui.conf" \
      '' Theme "$THEME_NAME" '' 'Vertical Candidate List' False \
      '' PerScreenDPI True '' WheelForPaging True
  else
    upsert_keys "$CONFIG_DIR/conf/classicui.conf" '' Theme "$THEME_NAME"
  fi
  upsert_keys "$CONFIG_DIR/conf/classicui.conf" '' Font "$candidate_font"
  replace_if_changed "$CONFIG_DIR/candidate-font.json" "$snapshot/candidate-font.json"
  log 'Fcitx5 is configured as the current user default; log out and back in for applications to inherit this setting.'
  if [[ "$desktop" != True ]]; then
    phase=complete
    log 'Configured on disk; desktop activation is pending login and has not been verified.'
    exit 0
  fi
  phase=activating
  timeout 10 fcitx5 -d 9>&- >/dev/null 2>&1 || die 'configured but not confirmed active: Fcitx5 startup failed'
  deadline=$((SECONDS + 10))
  until bus_owned && remote --check >/dev/null 2>&1; do
    (( SECONDS < deadline )) || die 'configured but not confirmed active: startup timed out'
    sleep 0.2
  done
  group="$(awk '/^\[/ { active = ($0 == "[GroupOrder]") } active && /^0=/ { sub(/^0=/, ""); print; exit }' "$CONFIG_DIR/profile")"
  [[ -n "$group" ]] || group="$(awk '/^\[/ { active = ($0 ~ /^\[Groups\/[0-9]+\]$/) } active && /^Name=/ { sub(/^Name=/, ""); print; exit }' "$CONFIG_DIR/profile")"
  # D-Bus can be ready before applications reconnect their input contexts.
  deadline=$((SECONDS + 10))
  while :; do
    remote -g "$group" && remote -s rime || die 'configured but not confirmed active: could not select Rime'
    live_group="$(remote -q)" && live_im="$(remote -n)" || die 'configured but not confirmed active: could not query live input method'
    [[ "$live_group" == "$group" && "$live_im" == rime ]] && break
    if (( SECONDS >= deadline )); then
      if [[ "$live_group" == "$group" && -z "$live_im" ]]; then
        die 'configured but not confirmed active: no input context reconnected within 10 seconds; focus a text field and run configure again'
      fi
      die 'configured but not confirmed active: live input method differs'
    fi
    sleep 0.2
  done
  awk -v wanted="$group" '
    /^\[/ { section=$0; active=($0 ~ /^\[Groups\/[0-9]+\]$/) }
    active && /^Name=/ && substr($0,6)==wanted { target=section }
    { lines[NR]=$0; sections[NR]=section }
    END {
      for (i=1;i<=NR;i++) {
        if (sections[i]==target && lines[i]=="DefaultIM=rime") def=1
        prefix=target; sub(/\]$/, "/Items/", prefix)
        if (target!="" && index(sections[i],prefix)==1 && lines[i]=="Name=rime") item=1
      }
      exit !(def && item)
    }' "$CONFIG_DIR/profile" || die 'configured but not confirmed active: disk profile differs'
  phase=complete
  log 'Rime is active and the disk profile selects Rime. Rime Ice selection is recorded; confirm the schema and typing in the desktop UI.'
)

configure_existing() {
  local package
  for package in fcitx5 fcitx5-rime librime-bin; do
    package_installed "$package" || die "required package not installed: $package; run install"
  done
  rime_build_present "$RIME_DATA_DIR" || die 'Rime Ice build is missing or incomplete; run install'
  if [[ -L "$RIME_DATA_DIR" ]] || [[ -n "$(find "$RIME_DATA_DIR" -type l -print -quit)" ]]; then
    die 'Rime data contains symlinks; use a regular directory before configuring'
  fi
  theme_present "$THEME_DIR" || die 'Mellow theme missing or incomplete; run install'
  paging_present "$RIME_DATA_DIR" || die 'compiled paging rules missing or conflicting; run install'
  apply_session
}

show_status() {
  check_target_user
  check_apt_system
  local package im_status cloud_status theme_status
  for package in "${PACKAGES[@]}"; do
    if package_installed "$package"; then log "package: $package installed"; else log "package: $package not installed"; fi
  done
  if [[ -f "${CONFIG_DIR}/profile" ]] && awk '
    /^\[/ { in_item = ($0 ~ /^\[Groups\/[0-9]+\/Items\/[0-9]+\]$/) }
    in_item && /^Name=rime$/ { found = 1 }
    END { exit !found }
  ' "${CONFIG_DIR}/profile"; then
    log 'profile: rime present'
  else
    log 'profile: rime not present'
  fi
  if command -v im-config >/dev/null 2>&1; then
    im_status="$(im-config -m 2>/dev/null || printf 'unable to determine')"
  else
    im_status='not installed'
  fi
  cloud_status="$(grep -hE '^(Backend|CloudPinyinEnabled|CloudPinyinIndex)=' \
    "${CONFIG_DIR}/conf/"{cloudpinyin,pinyin}.conf 2>/dev/null | tr '\n' ' ' || true)"
  [[ -n "$cloud_status" ]] || cloud_status='not configured'
  theme_status="$(grep -E '^Theme=' "${CONFIG_DIR}/conf/classicui.conf" 2>/dev/null || true)"
  [[ -n "$theme_status" ]] || theme_status='not configured'
  log "im-config: $im_status"
  log "old Pinyin cloud settings: $cloud_status"
  log "configured defaults: $(grep '^DefaultIM=' "${CONFIG_DIR}/profile" 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -f "${RIME_DATA_DIR}/.rime-ice-version" ]]; then
    log "Rime Ice revision: $(cat "${RIME_DATA_DIR}/.rime-ice-version")"
  else
    log 'Rime Ice revision: not installed by this script'
  fi
  if rime_build_present "${RIME_DATA_DIR}"; then
    log 'Rime Ice build: present (does not verify the active desktop session)'
  else
    log 'Rime Ice build: missing or incomplete'
  fi
  log "theme: $theme_status"
  log "candidate font: $(grep '^Font=' "$CONFIG_DIR/conf/classicui.conf" 2>/dev/null || printf 'not configured')"
  if [[ -f "$CONFIG_DIR/candidate-font.json" ]]; then
    log 'candidate font baseline: recorded (repeat runs reuse the 1.6x size)'
  else
    log 'candidate font baseline: not recorded'
  fi
  log 'Default input framework is per user; log out and back in after changes.'
  if theme_present "$THEME_DIR"; then log 'Mellow Vermilion resources: present'; else log 'Mellow Vermilion resources: missing or incomplete'; fi
  if paging_present "$RIME_DATA_DIR"; then log 'compiled comma/period paging: present'; else log 'compiled comma/period paging: missing or conflicting'; fi
  log "recorded Rime selection (not a live query): $(grep 'previously_selected_schema:' "$RIME_DATA_DIR/user.yaml" 2>/dev/null || true)"
  if command -v fcitx5-remote >/dev/null 2>&1 && command -v dbus-send >/dev/null 2>&1 && bus_owned; then
    log "live group: $(remote -q 2>/dev/null || printf unknown)"
    log "live input method: $(remote -n 2>/dev/null || printf unknown)"
  else
    log 'live session: unavailable; activation has not been verified'
  fi
}

install_fcitx5() {
  check_target_user
  check_apt_system
  need_cmd sudo
  log "installing official packages: ${PACKAGES[*]}"
  sudo apt-get update
  sudo apt-get install -y "${PACKAGES[@]}"
  need_cmd im-config
  install_rime_ice

  log 'Rime Ice input is offline. Existing Pinyin and its cloud settings are retained as a fallback.'
}

main() {
  local action='' argument
  ASSUME_YES=False
  for argument in "$@"; do
    case "$argument" in
      --yes) ASSUME_YES=True ;;
      install|configure|status|help|-h|--help)
        [[ -z "$action" ]] || { usage >&2; exit 1; }
        action="$argument" ;;
      *) usage >&2; exit 1 ;;
    esac
  done
  case "${action:-install}" in
    install|configure)
      check_target_user
      check_apt_system
      need_cmd flock
      mkdir -p "$CONFIG_DIR"
      exec 9>"$CONFIG_DIR/.installer.lock"
      flock -n 9 || die 'another installer is running'
      if [[ "${action:-install}" == install ]]; then install_fcitx5; else configure_existing; fi ;;
    status) show_status ;;
    help|-h|--help) usage ;;
  esac
}

main "$@"
