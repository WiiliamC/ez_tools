#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/install_fcitx5_pinyin.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fqx -- "$2" "$1" || fail "missing $2 in $1"; }

# Exercise the default data path independently of the caller's environment.
unset XDG_DATA_HOME

make_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HOME}/apt.calls"
exit 0
EOF
  cat >"$bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'install ok installed\n'
EOF
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  cat >"$bin/im-config" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HOME}/im-config.calls"
EOF
  cat >"$bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then printf '%s\n' "${STUB_UID:-1000}"; else command /usr/bin/id "$@"; fi
EOF
  cat >"$bin/git" <<'EOF'
#!/usr/bin/env bash
set -eu
if [[ "$1" == clone ]]; then
  [[ "${STUB_DOWNLOAD_FAIL:-0}" == 0 ]] || exit 1
  target="${@: -1}"
  mkdir -p "$target"/{cn_dicts,en_dicts,lua,opencc}
  for file in default.yaml rime_ice.schema.yaml rime_ice.dict.yaml melt_eng.dict.yaml; do
    printf 'fixture: %s\n' "${STUB_REVISION:-one}" >"$target/$file"
  done
  printf 'upstream phrase\n' >"$target/custom_phrase.txt"
  printf 'fixture\n' >"$target/lua/test.lua"
  [[ "${STUB_MISSING_RESOURCE:-0}" == 0 ]] || rm "$target/rime_ice.dict.yaml"
else
  printf '%040d\n' "${STUB_REVISION_NUMBER:-1}"
fi
EOF
  cat >"$bin/rime_deployer" <<'EOF'
#!/usr/bin/env bash
set -eu
case "$1" in
  --add-schema)
    # Match librime: only extend patch/schema_list, never read default.yaml.
    /usr/bin/python3 - "${@:2}" <<'PY'
import pathlib
import sys
import yaml
path = pathlib.Path("default.custom.yaml")
config = yaml.safe_load(path.read_text()) or {} if path.exists() else {}
schemas = config.setdefault("patch", {}).setdefault("schema_list", [])
for schema in sys.argv[1:]:
    if not any(entry["schema"] == schema for entry in schemas):
        schemas.append({"schema": schema})
path.write_text(yaml.safe_dump(config))
PY
    ;;
  --set-active-schema)
    touch user.yaml
    if ! grep -qx 'previously_selected_schema: rime_ice' user.yaml; then
      printf 'previously_selected_schema: rime_ice\n' >>user.yaml
    fi ;;
  --build)
    printf 'build\n' >>"${HOME}/deploy.calls"
    if [[ -n "${STUB_LIVE_DATA:-}" ]]; then
      printf 'new learned fixture\n' >"$STUB_LIVE_DATA"
    fi
    [[ "${STUB_DEPLOY_FAIL:-0}" == 0 ]] || exit 1
    mkdir -p "$4"
    if [[ "${STUB_INCOMPLETE_BUILD:-0}" == 0 ]]; then
      for file in rime_ice.schema.yaml rime_ice.table.bin rime_ice.prism.bin; do
        printf 'compiled\n' >"$4/$file"
      done
      if [[ -f "$2/rime_ice.custom.yaml" ]]; then
        cat "$2/rime_ice.custom.yaml" >>"$4/rime_ice.schema.yaml"
      fi
    fi ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin"/*
}

run_install() {
  HOME="$1" XDG_CONFIG_HOME="$1/.config" PATH="$2:$PATH" bash "$script" install
}

stub_bin="${tmp_dir}/bin"
make_stubs "$stub_bin"

# Fresh configuration creates a usable keyboard + Rime profile and compiled dictionary.
fresh_home="${tmp_dir}/fresh"
mkdir -p "$fresh_home"
run_install "$fresh_home" "$stub_bin"
profile="${fresh_home}/.config/fcitx5/profile"
assert_contains "$profile" '[Groups/0/Items/0]'
assert_contains "$profile" 'Name=keyboard-us'
assert_contains "$profile" '[Groups/0/Items/1]'
assert_contains "$profile" 'Name=rime'
assert_contains "$profile" 'DefaultIM=rime'
[[ "$(cat "${fresh_home}/apt.calls")" == *'fcitx5-rime librime-plugin-lua librime-bin git'* ]] || fail 'missing Rime dependencies'
assert_contains "${fresh_home}/.local/share/fcitx5/rime/user.yaml" 'previously_selected_schema: rime_ice'
[[ ! -e "${fresh_home}/.config/fcitx5/conf/pinyin.conf" ]] || fail 'fresh install configured old Pinyin'
[[ -s "${fresh_home}/.local/share/fcitx5/rime/build/rime_ice.table.bin" ]] || fail 'missing compiled dictionary'
assert_contains "${fresh_home}/.config/fcitx5/conf/classicui.conf" 'Theme=Material-Color-black'

# An existing multi-IM profile is retained, Rime is merged into the first ordered group,
# and a second run has no content changes or new backups.
merge_home="${tmp_dir}/merge"
mkdir -p "${merge_home}/.config/fcitx5/conf"
cat >"${merge_home}/.config/fcitx5/profile" <<'EOF'
[Groups/0]
Name=Work
Default Layout=jp
DefaultIM=mozc

[Groups/0/Items/0]
Name=mozc
Layout=

[Groups/1]
Name=Default
Default Layout=us
DefaultIM=keyboard-us

[Groups/1/Items/0]
Name=keyboard-us
Layout=

[Groups/1/Items/1]
Name=anthy
Layout=

[Groups/1/Items/2]
Name=pinyin
Layout=

[Unrelated]
Keep=This

[GroupOrder]
0=Work
1=Default
EOF
cat >"${merge_home}/.config/fcitx5/conf/pinyin.conf" <<'EOF'
# preserve me
OtherSetting=keep
CloudPinyinEnabled=True
EOF
run_install "$merge_home" "$stub_bin"
merge_profile="${merge_home}/.config/fcitx5/profile"
assert_contains "$merge_profile" 'Name=mozc'
assert_contains "$merge_profile" 'Name=anthy'
assert_contains "$merge_profile" '[Groups/0/Items/1]'
[[ "$(grep -c '^Name=rime$' "$merge_profile")" == 1 ]] || fail 'Rime was not added exactly once'
assert_contains "$merge_profile" 'Keep=This'
[[ "$(awk '/^\[/ { active = ($0 == "[Groups/0]") } active && /^DefaultIM=/ { print }' "$merge_profile")" == DefaultIM=rime ]] || fail 'priority group default was not switched'
[[ "$(awk '/^\[/ { active = ($0 == "[Groups/1]") } active && /^DefaultIM=/ { print }' "$merge_profile")" == DefaultIM=keyboard-us ]] || fail 'unrelated group default changed'
assert_contains "${merge_home}/.config/fcitx5/conf/pinyin.conf" '# preserve me'
if grep -Eq '^\[(Behavior|Prediction|CloudPinyin|Theme)\]$' "${merge_home}/.config/fcitx5/conf/"*.conf; then
  fail 'Fcitx5 option keys must be written at the top level'
fi
backup_count="$(find "${merge_home}/.config/fcitx5" -name '*.bak.*' | wc -l)"
[[ "$backup_count" -gt 0 ]] || fail 'changed existing files should be backed up'
snapshot="$(sha256sum "$merge_profile" "${merge_home}/.config/fcitx5/conf/"*.conf)"
run_install "$merge_home" "$stub_bin"
[[ "$snapshot" == "$(sha256sum "$merge_profile" "${merge_home}/.config/fcitx5/conf/"*.conf)" ]] || fail 'repeat run changed configuration'
[[ "$backup_count" == "$(find "${merge_home}/.config/fcitx5" -name '*.bak.*' | wc -l)" ]] || fail 'repeat run made redundant backup'

assert_contains "$merge_profile" 'Name=pinyin'
assert_contains "${merge_home}/.config/fcitx5/conf/pinyin.conf" 'CloudPinyinEnabled=True'
[[ "$(wc -l <"${merge_home}/deploy.calls")" == 2 ]] || fail 'repeat install did not redeploy'

# Preserve inherited lists before the upstream default replaces the local file.
# Also retain compiled effective lists and honor explicit custom replacements.
for schema_source in inherited compiled custom; do
  schema_home="$tmp_dir/schemas-$schema_source"
  schema_dir="$schema_home/.local/share/fcitx5/rime"
  mkdir -p "$schema_dir"
  printf 'schema_list: [{schema: inherited_one}, {schema: inherited_two}]\n' >"$schema_dir/default.yaml"
  printf 'patch:\n  menu/page_size: 9\n' >"$schema_dir/default.custom.yaml"
  expected='inherited_one inherited_two rime_ice'
  case "$schema_source" in
    compiled)
      mkdir -p "$schema_dir/build"
      printf 'schema_list: [{schema: compiled_one}]\n' >"$schema_dir/build/default.yaml"
      expected='compiled_one rime_ice' ;;
    custom)
      printf '  schema_list: [{schema: custom_one}]\n' >>"$schema_dir/default.custom.yaml"
      expected='custom_one rime_ice' ;;
  esac
  for attempt in 1 2; do
    run_install "$schema_home" "$stub_bin" >/dev/null
    /usr/bin/python3 - "$schema_dir/default.custom.yaml" "$expected" <<'PY'
import sys
import yaml
with open(sys.argv[1]) as stream:
    patch = yaml.safe_load(stream)["patch"]
assert [entry["schema"] for entry in patch["schema_list"]] == sys.argv[2].split()
assert patch["menu/page_size"] == 9
PY
  done
done

# Download/deploy errors leave existing resources and profile byte-for-byte intact.
for failure in STUB_DOWNLOAD_FAIL STUB_MISSING_RESOURCE STUB_DEPLOY_FAIL STUB_INCOMPLETE_BUILD; do
  before="$(find "${merge_home}/.config" "${merge_home}/.local/share" -type f -exec sha256sum {} + | sort)"
  im_before="$(cat "${merge_home}/im-config.calls")"
  if env "$failure=1" STUB_REVISION=two HOME="$merge_home" XDG_CONFIG_HOME="$merge_home/.config" PATH="$stub_bin:$PATH" bash "$script" install >/dev/null 2>&1; then
    fail "$failure unexpectedly succeeded"
  fi
  [[ "$before" == "$(find "${merge_home}/.config" "${merge_home}/.local/share" -type f -exec sha256sum {} + | sort)" ]] || fail "$failure changed live configuration"
  [[ "$im_before" == "$(cat "${merge_home}/im-config.calls")" ]] || fail "$failure switched input framework"
done

# Existing customizations and learned data survive an upstream update.
rime_dir="${merge_home}/.local/share/fcitx5/rime"
printf 'custom patch\n' >"$rime_dir/rime_ice.custom.yaml"
printf 'personal phrase\n' >"$rime_dir/custom_phrase.txt"
mkdir -p "$rime_dir/rime_ice.userdb"
printf 'learned fixture\n' >"$rime_dir/rime_ice.userdb/data"
STUB_LIVE_DATA="$rime_dir/rime_ice.userdb/data" STUB_REVISION=two STUB_REVISION_NUMBER=2 run_install "$merge_home" "$stub_bin"
assert_contains "$rime_dir/rime_ice.custom.yaml" 'custom patch'
assert_contains "$rime_dir/custom_phrase.txt" 'personal phrase'
assert_contains "$rime_dir/rime_ice.userdb/data" 'new learned fixture'
assert_contains "$rime_dir/rime_ice.dict.yaml" 'fixture: two'

# Editing a custom patch must rebuild even when upstream and old build files match.
assert_contains "$rime_dir/build/rime_ice.schema.yaml" 'custom patch'
printf 'edited custom patch\n' >"$rime_dir/rime_ice.custom.yaml"
deploy_count="$(wc -l <"${merge_home}/deploy.calls")"
STUB_REVISION=two STUB_REVISION_NUMBER=2 run_install "$merge_home" "$stub_bin"
[[ "$(wc -l <"${merge_home}/deploy.calls")" == "$((deploy_count + 1))" ]] || fail 'custom patch edit did not trigger deployment'
assert_contains "$rime_dir/build/rime_ice.schema.yaml" 'edited custom patch'
assert_contains "$rime_dir/rime_ice.custom.yaml" 'edited custom patch'

# Do not follow a user's linked configuration into another directory.
ln -s "$rime_dir/custom_phrase.txt" "$rime_dir/linked.txt"
if run_install "$merge_home" "$stub_bin" >/dev/null 2>&1; then
  fail 'symlink in user data was accepted'
fi
assert_contains "$rime_dir/custom_phrase.txt" 'personal phrase'

# Honor distinct XDG config and data directories outside HOME, including spaces.
xdg_dir="${tmp_dir}/custom config"
xdg_data_dir="${tmp_dir}/custom data"
HOME="$fresh_home" XDG_CONFIG_HOME="$xdg_dir" XDG_DATA_HOME="$xdg_data_dir" PATH="$stub_bin:$PATH" bash "$script" install
assert_contains "$xdg_dir/fcitx5/profile" 'DefaultIM=rime'
assert_contains "$xdg_data_dir/fcitx5/rime/user.yaml" 'previously_selected_schema: rime_ice'
[[ -s "$xdg_data_dir/fcitx5/rime/build/rime_ice.table.bin" ]] || fail 'missing XDG data dictionary'
[[ ! -e "$xdg_dir/fcitx5/rime" ]] || fail 'Rime data installed in config directory'
status="$(HOME="$fresh_home" XDG_CONFIG_HOME="$xdg_dir" XDG_DATA_HOME="$xdg_data_dir" PATH="$stub_bin:$PATH" bash "$script" status)"
[[ "$status" == *'Rime Ice build: present'* && "$status" == *'profile: rime present'* ]] || fail 'incorrect installed status'
[[ "$status" == *"Rime Ice revision: $(printf '%040d' 1)"* ]] || fail 'incorrect installed revision'
missing_status="$(HOME="$fresh_home" XDG_CONFIG_HOME="$xdg_dir" XDG_DATA_HOME="$tmp_dir/absent" PATH="$stub_bin:$PATH" bash "$script" status)"
[[ "$missing_status" == *'Rime Ice build: missing'* ]] || fail 'incorrect missing status'
[[ "$missing_status" == *'Rime Ice revision: not installed by this script'* ]] || fail 'incorrect missing revision'
bash "$script" help >/dev/null

if HOME="$fresh_home" PATH="$stub_bin:$PATH" bash "$script" invalid >/dev/null 2>&1; then
  fail 'invalid command unexpectedly succeeded'
fi
if STUB_UID=0 HOME="$fresh_home" PATH="$stub_bin:$PATH" bash "$script" status >/dev/null 2>&1; then
  fail 'root invocation unexpectedly succeeded'
fi

printf 'install_fcitx5_pinyin_test: PASS\n'
