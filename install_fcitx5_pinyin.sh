#!/usr/bin/env bash

set -euo pipefail

TAG='[install-fcitx5-pinyin]'
PACKAGES=(fcitx5 fcitx5-chinese-addons fcitx5-config-qt fcitx5-frontend-all fcitx5-material-color im-config)
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/fcitx5"

usage() {
  cat <<'EOF'
Usage: ./install_fcitx5_pinyin.sh [install|status|help]

Install Fcitx5 with its built-in Pinyin input method on Ubuntu/Debian APT systems.
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
  local profile="${CONFIG_DIR}/profile" tmp target_group max_item
  mkdir -p "$CONFIG_DIR"
  tmp="$(mktemp)"
  if [[ ! -f "$profile" ]]; then
    cat >"$tmp" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF
  else
    target_group="$(awk '
      /^\[/ { in_group = 0 }
      /^\[Groups\/[0-9]+\]$/ {
        group = $0
        sub(/^\[Groups\//, "", group)
        sub(/\]$/, "", group)
        if (first == "") first = group
        in_group = 1
        next
      }
      in_group && /^Name=Default$/ { print group; found = 1; exit }
      END { if (!found && first != "") print first }
    ' "$profile")"

    if [[ -z "$target_group" ]]; then
      cat "$profile" >"$tmp"
      cat >>"$tmp" <<'EOF'

[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=pinyin
Layout=

[GroupOrder]
0=Default
EOF
    elif awk -v group="$target_group" '
      /^\[/ { in_target = (index($0, "[Groups/" group "/Items/") == 1) }
      in_target && /^Name=pinyin$/ { found = 1 }
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
      printf '\n[Groups/%s/Items/%s]\nName=pinyin\nLayout=\n' \
        "$target_group" "$((max_item + 1))" >>"$tmp"
    fi
  fi
  replace_if_changed "$profile" "$tmp"
}

configure_fcitx5() {
  create_or_merge_profile
  upsert_keys "${CONFIG_DIR}/conf/pinyin.conf" \
    '' CloudPinyinEnabled True '' CloudPinyinIndex 2 \
    '' Prediction True '' KeepCurrentContext True
  upsert_keys "${CONFIG_DIR}/conf/cloudpinyin.conf" '' Backend Baidu
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
    in_item && /^Name=pinyin$/ { found = 1 }
    END { exit !found }
  ' "${CONFIG_DIR}/profile"; then
    log 'profile: pinyin present'
  else
    log 'profile: pinyin not present'
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
  log "cloud: $cloud_status"
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
  im-config -n fcitx5
  configure_fcitx5
  log 'configured Fcitx5 Pinyin. Log out and back in (or restart your session) to apply it.'
  log 'privacy: cloud Pinyin queries are sent to Baidu when cloud candidates are used.'
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
