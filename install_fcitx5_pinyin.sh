#!/usr/bin/env bash

set -euo pipefail

TAG='[install-fcitx5-pinyin]'
PACKAGES=(fcitx5 fcitx5-chinese-addons fcitx5-config-qt fcitx5-frontend-all fcitx5-material-color im-config fcitx5-rime librime-plugin-lua librime-bin git python3 python3-yaml)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fcitx5"
RIME_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/fcitx5/rime"

usage() {
  cat <<'EOF'
Usage: ./install_fcitx5_pinyin.sh [install|status|help]

Install Fcitx5 with Rime Ice (full Pinyin) on Ubuntu/Debian APT systems.
Existing input methods are retained. Running install again updates Rime Ice.
Run it as the desktop user, never with sudo.  No command means install.
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

# Build in isolation: a download or compilation error cannot overwrite live data.
install_rime_ice() (
  local work source stage destination file relative revision manifest
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
  printf '%s\0' .rime-ice-version default.custom.yaml user.yaml >>"$manifest"
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
  while IFS= read -r -d '' relative; do
    replace_if_changed "$destination/$relative" "$stage/$relative"
  done <"$manifest"
  log "Rime Ice deployed: $revision"
)

configure_fcitx5() {
  create_or_merge_profile
  upsert_keys "${CONFIG_DIR}/conf/classicui.conf" \
    '' Theme Material-Color-black \
    '' 'Vertical Candidate List' False \
    '' PerScreenDPI True \
    '' WheelForPaging True
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
  im-config -n fcitx5
  configure_fcitx5
  log 'configured Fcitx5 Rime Ice (full Pinyin). Log out and back in (or restart your session) to apply it.'
  log 'Rime Ice input is offline. Existing Pinyin and its cloud settings are retained as a fallback.'
}

main() {
  [[ $# -le 1 ]] || { usage >&2; exit 1; }
  case "${1:-install}" in
    install) install_fcitx5 ;;
    status) show_status ;;
    help|-h|--help) usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
