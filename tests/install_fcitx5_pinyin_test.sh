#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/install_fcitx5_pinyin.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fqx -- "$2" "$1" || fail "missing $2 in $1"; }

# Exercise the default data path independently of the caller's environment.
unset XDG_DATA_HOME DISPLAY WAYLAND_DISPLAY DBUS_SESSION_BUS_ADDRESS

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
if [[ "$*" == '-n fcitx5' ]]; then
  printf 'framework=fcitx5\n' >"$HOME/.xinputrc"
  [[ "${STUB_IM_CONFIG_FAIL:-0}" == 0 ]] || exit 1
fi
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
  if [[ "$*" == *fcitx5-mellow-themes* ]]; then
    [[ "${STUB_THEME_FAIL:-0}" == 0 ]] || exit 1
    mkdir -p "$target/mellow-vermilion"
    printf '[InputPanel/Background]\nImage=panel.svg\n' >"$target/mellow-vermilion/theme.conf"
    printf '<svg/>\n' >"$target/mellow-vermilion/panel.svg"
    printf '[InputPanel/Highlight]\nImage=highlight.svg\n[Menu/CheckBox]\nImage=ez-tools-menu-checkbox.png\n[Menu/SubMenu]\nImage=ez-tools-menu-submenu.png\n' >>"$target/mellow-vermilion/theme.conf"
    printf '<svg/>\n' >"$target/mellow-vermilion/highlight.svg"
    printf 'fixture checkbox\n' >"$target/mellow-vermilion/ez-tools-menu-checkbox.png"
    printf 'fixture submenu\n' >"$target/mellow-vermilion/ez-tools-menu-submenu.png"
    printf 'fixture license\n' >"$target/LICENSE"
    [[ "${STUB_THEME_MISSING:-0}" == 0 ]] || rm "$target/mellow-vermilion/panel.svg"
    exit 0
  fi
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
    if [[ -n "${STUB_CHANGED_PATCH:-}" ]]; then
      printf 'patch: {menu/page_size: 8}\n' >"$STUB_CHANGED_PATCH"
    fi
    [[ "${STUB_DEPLOY_FAIL:-0}" == 0 ]] || exit 1
    mkdir -p "$4"
    if [[ "${STUB_INCOMPLETE_BUILD:-0}" == 0 ]]; then
      for file in rime_ice.schema.yaml rime_ice.table.bin rime_ice.prism.bin; do
        printf 'compiled\n' >"$4/$file"
      done
      if [[ -f "$2/rime_ice.custom.yaml" ]]; then
        /usr/bin/python3 - "$2/rime_ice.custom.yaml" "$4/rime_ice.schema.yaml" <<'PYBUILD'
import pathlib, sys, yaml
custom = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
patch = custom["patch"]
bindings = patch.get("key_binder/bindings", patch.get("key_binder/bindings/+", []))
config = {"key_binder": {"bindings": bindings}, "custom": custom}
pathlib.Path(sys.argv[2]).write_text(yaml.safe_dump(config))
PYBUILD
      fi
    fi ;;
  *) exit 1 ;;
esac
EOF
  cat >"$bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "${STUB_PROCESS_FAIL:-0}" == 0 ]] || exit 2
if [[ "$*" == *'-f'* ]]; then [[ "${STUB_CONFIG_WINDOW:-0}" == 1 ]]; else [[ -f "$HOME/running" ]]; fi
EOF
  cat >"$bin/dbus-send" <<'EOF'
#!/usr/bin/env bash
[[ "${STUB_BUS_FAIL:-0}" == 0 ]] || exit 1
if [[ -f "$HOME/running" ]]; then printf 'boolean true\n'; else printf 'boolean false\n'; fi
EOF
  cat >"$bin/fcitx5-remote" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$HOME/remote.calls"
case "$1" in
  -e)
    if [[ -f "$HOME/exit-profile" ]]; then
      cp "$HOME/exit-profile" "$XDG_CONFIG_HOME/fcitx5/profile"
    fi
    [[ "${STUB_EXIT_TIMEOUT:-0}" == 0 ]] || exit 0
    rm -f "$HOME/running" ;;
  --check) [[ -f "$HOME/running" ]] ;;
  -g) printf '%s\n' "$2" >"$HOME/current-group" ;;
  -s)
    printf '%s\n' "$2" >"$HOME/current-im"
    if [[ "${STUB_DISK_MISMATCH:-0}" == 1 ]]; then
      sed -i 's/DefaultIM=rime/DefaultIM=pinyin/' "$XDG_CONFIG_HOME/fcitx5/profile"
    fi ;;
  -q) cat "$HOME/current-group" ;;
  -n)
    queries=$(cat "$HOME/context-queries" 2>/dev/null || echo 0)
    printf '%s\n' "$((queries + 1))" >"$HOME/context-queries"
    if [[ "${STUB_NO_CONTEXT:-0}" == 1 ]]; then exit 0; fi
    if (( queries < ${STUB_CONTEXT_DELAY:-0} )); then
      # The default selection succeeds, but a reconnecting client still needs
      # another selection after its context becomes available.
      printf 'keyboard-us\n' >"$HOME/current-im"
      exit 0
    fi
    if [[ "${STUB_LIVE_MISMATCH:-0}" == 1 ]]; then echo pinyin; else cat "$HOME/current-im"; fi ;;
  *) exit 1 ;;
esac
EOF
  cat >"$bin/fcitx5" <<'EOF'
#!/usr/bin/env bash
printf 'start\n' >>"$HOME/start.calls"
[[ "${STUB_START_FAIL:-0}" == 0 ]] || exit 1
[[ "${STUB_START_TIMEOUT:-0}" == 0 ]] || exit 0
[[ ! -e /proc/$$/fd/9 ]] || exit 1
touch "$HOME/running"
rm -f "$HOME/context-queries"
EOF
  chmod +x "$bin"/*
}

run_install() {
  HOME="$1" XDG_CONFIG_HOME="$1/.config" PATH="$2:$PATH" bash "$script" install
}

stub_bin="${tmp_dir}/bin"
make_stubs "$stub_bin"

# Test preparation against realistic upstream references, using isolated defaults.
SCRIPT_UNDER_TEST="$script" THEME_TEST_ROOT="$tmp_dir/theme-unit" /usr/bin/python3 - <<'PYTHEMETEST'
import os, pathlib, subprocess
root = pathlib.Path(os.environ["THEME_TEST_ROOT"])
root.mkdir()
defaults = root / "default"
defaults.mkdir()
for name in ("radio.png", "arrow.png"):
    (defaults / name).write_bytes(b"fixture png")
script = pathlib.Path(os.environ["SCRIPT_UNDER_TEST"]).read_text().rsplit('main "$@"', 1)[0]
base = ('# keep comment\n[InputPanel/Background]\nImage=panel.svg\n'
        '[InputPanel/Highlight]\nImage=highlight.svg\n'
        '[Menu/CheckBox]\nImage=radio.svg\n'
        '[Menu/SubMenu]\nImage=arrow.svg\n')
def fixture(name, config=base):
    directory = root / name
    directory.mkdir()
    (directory / "theme.conf").write_text(config)
    for image in ("panel.svg", "highlight.svg"):
        (directory / image).write_text("<svg/>")
    return directory

def call(function, directory):
    return subprocess.run(['bash', '-c', script + '\n' + function + ' "$1" "$2"',
                           'test', str(directory), str(defaults)], capture_output=True, text=True)

directory = fixture("missing-both")
assert call("theme_present", directory).returncode != 0
result = call("prepare_theme", directory)
assert result.returncode == 0, result.stderr
assert "radio.png" in result.stdout and "arrow.png" in result.stdout
expected = base.replace("Image=radio.svg", "Image=ez-tools-menu-checkbox.png").replace(
    "Image=arrow.svg", "Image=ez-tools-menu-submenu.png")
assert (directory / "theme.conf").read_text() == expected
assert call("theme_present", directory).returncode == 0
snapshot = {p.name: p.read_bytes() for p in directory.iterdir()}
assert call("prepare_theme", directory).returncode == 0
assert snapshot == {p.name: p.read_bytes() for p in directory.iterdir()}
directory = fixture("crlf")
crlf = base.replace("Image=radio.svg", "iMaGe = radio.svg").replace("\n", "\r\n")
(directory / "theme.conf").write_bytes(crlf.encode())
assert call("prepare_theme", directory).returncode == 0
assert (directory / "theme.conf").read_bytes() == crlf.replace(
    "radio.svg", "ez-tools-menu-checkbox.png").replace(
    "arrow.svg", "ez-tools-menu-submenu.png").encode()
for present in (1, 2):
    directory = fixture(f"present-{present}")
    (directory / "radio.svg").write_text("<svg/>")
    if present == 2:
        (directory / "arrow.svg").write_text("<svg/>")
    assert call("prepare_theme", directory).returncode == 0
    assert "Image=radio.svg" in (directory / "theme.conf").read_text()
    assert call("theme_present", directory).returncode == 0
directory = fixture("empty-reference", base.replace("Image=radio.svg", "Image=").replace("Image=arrow.svg", "Image="))
assert call("prepare_theme", directory).returncode == 0
assert len(list(directory.iterdir())) == 3
for name, config, broken, expected_error in (
    ("unsafe", base.replace("radio.svg", "../radio.svg"), None, "unsafe resource path"),
    ("absolute", base.replace("radio.svg", "/radio.svg"), None, "unsafe resource path"),
    ("syntax", "invalid config", None, "theme validation"),
    ("empty", base, "radio.svg", "empty or not a regular file"),
    ("body", base.replace("panel.svg", "missing.svg"), None, "missing.svg"),
    ("collision", base, "ez-tools-menu-checkbox.png", "already exists"),
):
    directory = fixture(name, config)
    if broken:
        (directory / broken).write_bytes(b"")
    before = {p.name: p.read_bytes() for p in directory.iterdir()}
    result = call("prepare_theme", directory)
    assert result.returncode != 0 and expected_error in result.stderr, result
    assert before == {p.name: p.read_bytes() for p in directory.iterdir()}
for name in ("empty-default", "missing-default"):
    if name == "empty-default":
        (defaults / "radio.png").write_bytes(b"")
    else:
        (defaults / "radio.png").unlink()
    result = call("prepare_theme", fixture(name))
    assert result.returncode != 0 and "default theme resource radio.png" in result.stderr
PYTHEMETEST

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
assert_contains "${fresh_home}/.config/fcitx5/conf/classicui.conf" 'Theme=mellow-vermilion'
[[ -s "$fresh_home/.local/share/fcitx5/themes/mellow-vermilion/LICENSE" ]] || fail 'theme license missing'
[[ ! -e "$fresh_home/.local/share/fcitx5/themes/mellow-vermilion/.git" ]] || fail 'theme Git metadata installed'
[[ "$(cat "$fresh_home/apt.calls")" != *fcitx5-material-color* ]] || fail 'still installs old default theme'

assert_contains "${fresh_home}/.config/fcitx5/conf/classicui.conf" 'Font=Sans 16'
assert_contains "$fresh_home/im-config.calls" '-n fcitx5'

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
for failure in STUB_DOWNLOAD_FAIL STUB_MISSING_RESOURCE STUB_DEPLOY_FAIL STUB_INCOMPLETE_BUILD STUB_THEME_FAIL STUB_THEME_MISSING; do
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
printf 'patch:\n  translator/comment_format: custom patch\n' >"$rime_dir/rime_ice.custom.yaml"
printf 'personal phrase\n' >"$rime_dir/custom_phrase.txt"
mkdir -p "$rime_dir/rime_ice.userdb"
printf 'learned fixture\n' >"$rime_dir/rime_ice.userdb/data"
STUB_LIVE_DATA="$rime_dir/rime_ice.userdb/data" STUB_REVISION=two STUB_REVISION_NUMBER=2 run_install "$merge_home" "$stub_bin"
assert_contains "$rime_dir/rime_ice.custom.yaml" '  translator/comment_format: custom patch'
assert_contains "$rime_dir/custom_phrase.txt" 'personal phrase'
assert_contains "$rime_dir/rime_ice.userdb/data" 'new learned fixture'
assert_contains "$rime_dir/rime_ice.dict.yaml" 'fixture: two'

# Editing a custom patch must rebuild even when upstream and old build files match.
grep -q 'translator/comment_format: custom patch' "$rime_dir/build/rime_ice.schema.yaml" || fail 'custom patch lost'
printf 'patch:\n  translator/comment_format: edited custom patch\n' >"$rime_dir/rime_ice.custom.yaml"
deploy_count="$(wc -l <"${merge_home}/deploy.calls")"
STUB_REVISION=two STUB_REVISION_NUMBER=2 run_install "$merge_home" "$stub_bin"
[[ "$(wc -l <"${merge_home}/deploy.calls")" == "$((deploy_count + 1))" ]] || fail 'custom patch edit did not trigger deployment'
grep -q 'translator/comment_format: edited custom patch' "$rime_dir/build/rime_ice.schema.yaml" || fail 'edited patch lost'
assert_contains "$rime_dir/rime_ice.custom.yaml" '  translator/comment_format: edited custom patch'

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
[[ -s "$xdg_data_dir/fcitx5/themes/mellow-vermilion/panel.svg" ]] || fail 'missing XDG theme'
[[ ! -e "$xdg_dir/fcitx5/rime" ]] || fail 'Rime data installed in config directory'
status="$(HOME="$fresh_home" XDG_CONFIG_HOME="$xdg_dir" XDG_DATA_HOME="$xdg_data_dir" PATH="$stub_bin:$PATH" bash "$script" status)"
[[ "$status" == *'Mellow Vermilion resources: present'* && "$status" == *'compiled comma/period paging: present'* ]] || fail 'incorrect theme/paging status'
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

# Session repair must read the profile saved by the exiting old process.
session_home="$tmp_dir/session"
mkdir -p "$session_home"
run_install "$session_home" "$stub_bin" >/dev/null
cat >"$session_home/exit-profile" <<'EOF'
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

[SavedDuringExit]
Keep=latest
EOF
session_config="$session_home/.config/fcitx5"
printf 'Theme=CustomTheme\nFont=Example 12\n' >"$session_config/conf/classicui.conf"
run_configure() {
  HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" DISPLAY=:99 \
    bash "$script" configure "$@"
}
touch "$session_home/running"
im_calls_before="$(wc -l <"$session_home/im-config.calls")"
apt_before="$(cat "$session_home/apt.calls")"
deploy_before="$(cat "$session_home/deploy.calls")"
run_configure --yes >/dev/null
assert_contains "$session_config/profile" 'DefaultIM=rime'
assert_contains "$session_config/profile" 'Keep=latest'
assert_contains "$session_config/conf/classicui.conf" 'Theme=mellow-vermilion'
assert_contains "$session_config/conf/classicui.conf" 'Font=Sans 16'
[[ "$(wc -l <"$session_home/im-config.calls")" == "$((im_calls_before + 1))" ]] || fail 'configure did not set default framework'
assert_contains "$session_home/.xinputrc" 'framework=fcitx5'
[[ "$(cat "$session_home/apt.calls")" == "$apt_before" ]] || fail 'configure used APT'
[[ "$(cat "$session_home/deploy.calls")" == "$deploy_before" ]] || fail 'configure compiled dictionaries'
[[ "$(cat "$session_home/current-im")" == rime ]] || fail 'Rime not activated'
found_exit_backup=0
for backup in "$session_config"/profile.bak.*; do
  if cmp -s "$backup" "$session_home/exit-profile"; then found_exit_backup=1; fi
done
[[ "$found_exit_backup" == 1 ]] || fail 'backup was not taken after exit save'

# A later restart reads the repaired profile rather than restoring the old list.
cp "$session_config/profile" "$session_home/exit-profile"
run_configure --yes >/dev/null
assert_contains "$session_config/profile" 'DefaultIM=rime'

# Install prepares resources before stopping a live session, then uses the same
# safe publication path as configure.
remote_before="$(cat "$session_home/remote.calls")"
if STUB_DEPLOY_FAIL=1 HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" DISPLAY=:99 bash "$script" install --yes >/dev/null 2>&1; then
  fail 'failed preparation succeeded in a live session'
fi
[[ "$remote_before" == "$(cat "$session_home/remote.calls")" ]] || fail 'preparation failure interrupted the session'
HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" DISPLAY=:99 bash "$script" install --yes >/dev/null
assert_contains "$session_config/profile" 'DefaultIM=rime'
assert_contains "$session_config/profile" 'Keep=latest'
assert_contains "$session_config/conf/classicui.conf" 'Theme=mellow-vermilion'
assert_contains "$session_config/conf/classicui.conf" 'Font=Sans 16'

# Refused/missing authorization and uncertain process state cannot change config.
for failure in no_confirmation STUB_CONFIG_WINDOW STUB_BUS_FAIL STUB_PROCESS_FAIL STUB_EXIT_TIMEOUT; do
  before="$(sha256sum "$session_config/profile" "$session_config/conf/classicui.conf")"
  if [[ "$failure" == no_confirmation ]]; then
    if run_configure </dev/null >"$tmp_dir/failure-output" 2>&1; then fail 'missing confirmation accepted'; fi
  else
    if (export "$failure=1"; run_configure --yes) >"$tmp_dir/failure-output" 2>&1; then fail "$failure succeeded"; fi
  fi
  [[ "$before" == "$(sha256sum "$session_config/profile" "$session_config/conf/classicui.conf")" ]] || fail "$failure changed config"
done

# A real terminal refusal must not stop the session or mutate the profile.
SESSION_TEST_HOME="$session_home" SESSION_TEST_BIN="$stub_bin" SESSION_TEST_SCRIPT="$script" python3 - <<'PYTEST'
import os, pathlib, pty, select, subprocess, time
home = pathlib.Path(os.environ['SESSION_TEST_HOME'])
profile = home / '.config/fcitx5/profile'
before = profile.read_bytes()
env = dict(os.environ, HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'),
           PATH=os.environ['SESSION_TEST_BIN'] + ':' + os.environ['PATH'], DISPLAY=':99')
master, slave = pty.openpty()
proc = subprocess.Popen(['bash', os.environ['SESSION_TEST_SCRIPT'], 'configure'],
                        stdin=slave, stdout=slave, stderr=slave, env=env)
os.close(slave)
output = b''
try:
    deadline = time.monotonic() + 10
    while b'[y/N]' not in output:
        assert time.monotonic() < deadline, output
        if select.select([master], [], [], 0.2)[0]:
            output += os.read(master, 4096)
    os.write(master, b'n\n')
    assert proc.wait(timeout=5) != 0
    assert profile.read_bytes() == before
    assert (home / 'running').exists()
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
    os.close(master)
PYTEST

# Client reconnection can lag behind D-Bus readiness and require reselection.
output="$(STUB_CONTEXT_DELAY=3 run_configure --yes)"
[[ "$output" == *'Rime is active'* ]] || fail 'delayed context was not activated'
[[ "$(cat "$session_home/context-queries")" == 4 ]] || fail 'context readiness was not retried'

# Failed activation is reported, with installed resources retained.
for failure in STUB_START_FAIL STUB_START_TIMEOUT STUB_NO_CONTEXT STUB_LIVE_MISMATCH STUB_DISK_MISMATCH; do
  if (export "$failure=1"; run_configure --yes) >"$tmp_dir/failure-output" 2>&1; then fail "$failure succeeded"; fi
  [[ "$(cat "$tmp_dir/failure-output")" == *'not confirmed active'* ]] || fail 'activation failure not identified'
  [[ -s "$session_home/.local/share/fcitx5/rime/build/rime_ice.table.bin" ]] || fail 'activation failure removed resources'
  case "$failure" in
    STUB_NO_CONTEXT) [[ "$(cat "$tmp_dir/failure-output")" == *'no input context reconnected'* ]] || fail 'missing context reported as mismatch' ;;
    STUB_LIVE_MISMATCH) [[ "$(cat "$tmp_dir/failure-output")" == *'live input method differs'* ]] || fail 'live mismatch not identified' ;;
  esac
done

# A write failure restores profile and starts the old session again.
cat >"$stub_bin/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${STUB_WRITE_FAIL:-0}" == 1 && "${@: -1}" == */profile ]]; then exit 1; fi
if [[ "${STUB_FONT_STATE_FAIL:-0}" == 1 && "${@: -1}" == */candidate-font.json ]]; then exit 1; fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$stub_bin/mv"
cp "$session_home/exit-profile" "$session_config/profile"
# Ensure the profile needs a real change after the daemon exits.
sed -i 's/DefaultIM=rime/DefaultIM=pinyin/' "$session_home/exit-profile"
touch "$session_home/running"
if (export STUB_WRITE_FAIL=1; run_configure --yes) >"$tmp_dir/failure-output" 2>&1; then fail 'write failure succeeded'; fi
cmp -s "$session_config/profile" "$session_home/exit-profile" || fail 'write failure did not restore exit snapshot'
[[ -f "$session_home/running" ]] || fail 'write failure did not restore session'

# An install write failure restores the theme and paging configuration too.
session_data="$session_home/.local/share/fcitx5"
printf 'old checkbox\n' >"$session_data/themes/mellow-vermilion/ez-tools-menu-checkbox.png"
rm "$session_data/themes/mellow-vermilion/ez-tools-menu-submenu.png"
printf '<svg>old theme</svg>\n' >"$session_data/themes/mellow-vermilion/panel.svg"
printf 'patch: {menu/page_size: 9}\n' >"$session_data/rime/rime_ice.custom.yaml"
restore_before="$(sha256sum "$session_data/themes/mellow-vermilion/panel.svg" "$session_data/themes/mellow-vermilion/theme.conf" "$session_data/themes/mellow-vermilion/ez-tools-menu-checkbox.png" "$session_data/rime/rime_ice.custom.yaml" "$session_data/rime/build/rime_ice.schema.yaml")"
if STUB_WRITE_FAIL=1 HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" DISPLAY=:99 bash "$script" install --yes >"$tmp_dir/failure-output" 2>&1; then
  fail 'install write failure succeeded'
fi
[[ "$restore_before" == "$(sha256sum "$session_data/themes/mellow-vermilion/panel.svg" "$session_data/themes/mellow-vermilion/theme.conf" "$session_data/themes/mellow-vermilion/ez-tools-menu-checkbox.png" "$session_data/rime/rime_ice.custom.yaml" "$session_data/rime/build/rime_ice.schema.yaml")" ]] || fail 'write failure did not restore theme/paging'
[[ -f "$session_home/running" ]] || fail 'install write failure did not restore session'
[[ ! -e "$session_data/themes/mellow-vermilion/ez-tools-menu-submenu.png" ]] || fail 'rollback retained new PNG'
# Restore the intentionally removed resource for subsequent configure tests.
printf 'fixture submenu\n' >"$session_data/themes/mellow-vermilion/ez-tools-menu-submenu.png"


# Offline configuration reports pending activation, and missing builds fail early.
rm -f "$session_home/running"
output="$(HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" bash "$script" configure)"
[[ "$output" == *'activation is pending login'* ]] || fail 'offline configure claimed activation'
[[ ! -f "$session_home/running" ]] || fail 'offline configure started a daemon'
if HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" XDG_DATA_HOME="$tmp_dir/missing-build" PATH="$stub_bin:$PATH" bash "$script" configure >/dev/null 2>&1; then
  fail 'configure accepted missing build'
fi
status="$(HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" bash "$script" status)"
[[ "$status" == *'live session: unavailable'* && "$status" == *'recorded Rime selection (not a live query)'* ]] || fail 'status conflates disk and live state'


# Merge existing shortcuts, replace conflicting punctuation, and remain idempotent.
paging_home="$tmp_dir/paging"
paging_dir="$paging_home/.local/share/fcitx5/rime"
mkdir -p "$paging_dir" "$paging_home/.config/fcitx5/conf"
printf 'Theme=Material-Color-black\nFont=Example 14\n' >"$paging_home/.config/fcitx5/conf/classicui.conf"
cat >"$paging_dir/rime_ice.custom.yaml" <<'EOF'
patch:
  menu/page_size: 7
  key_binder/bindings/+:
    - {when: always, accept: comma, send: Escape}
    - {when: paging, accept: period, send: Escape}
    - {when: composing, accept: Control+j, send: Down}
EOF
run_install "$paging_home" "$stub_bin" >/dev/null
assert_contains "$paging_home/.config/fcitx5/conf/classicui.conf" 'Theme=mellow-vermilion'
assert_contains "$paging_home/.config/fcitx5/conf/classicui.conf" 'Font=Example 22.4'
/usr/bin/python3 - "$paging_dir/rime_ice.custom.yaml" <<'PYCHECK'
import sys, yaml
with open(sys.argv[1]) as stream:
    patch = yaml.safe_load(stream)["patch"]
assert patch["menu/page_size"] == 7
assert patch["key_binder/bindings/+"] == [
    {"when": "composing", "accept": "Control+j", "send": "Down"},
    {"when": "has_menu", "accept": "comma", "send": "Page_Up"},
    {"when": "has_menu", "accept": "period", "send": "Page_Down"},
]
PYCHECK
before="$(find "$paging_home/.config" "$paging_home/.local/share" -type f -exec sha256sum {} + | sort)"
run_install "$paging_home" "$stub_bin" >/dev/null
[[ "$before" == "$(find "$paging_home/.config" "$paging_home/.local/share" -type f -exec sha256sum {} + | sort)" ]] || fail 'reinstall changed config or created extra backups'

# Concurrent custom edits must not be overwritten by a previously compiled stage.
profile_before="$(sha256sum "$paging_home/.config/fcitx5/profile")"
if STUB_CHANGED_PATCH="$paging_dir/rime_ice.custom.yaml" run_install "$paging_home" "$stub_bin" >"$tmp_dir/paging-error" 2>&1; then
  fail 'concurrent custom edit accepted'
fi
grep -q 'changed during preparation' "$tmp_dir/paging-error" || fail 'concurrent edit not diagnosed'
assert_contains "$paging_dir/rime_ice.custom.yaml" 'patch: {menu/page_size: 8}'
[[ "$profile_before" == "$(sha256sum "$paging_home/.config/fcitx5/profile")" ]] || fail 'concurrent edit changed profile'

# Reject invalid or ambiguous patches without publishing any data.
for invalid in 'patch: [' 'patch: {key_binder: {bindings: []}}' 'patch: {menu/page_size: 7, menu/page_size: 8}'; do
  printf '%s\n' "$invalid" >"$paging_dir/rime_ice.custom.yaml"
  before="$(find "$paging_home/.config" "$paging_home/.local/share" -type f -exec sha256sum {} + | sort)"
  if run_install "$paging_home" "$stub_bin" >"$tmp_dir/paging-error" 2>&1; then fail 'invalid custom patch accepted'; fi
  [[ "$before" == "$(find "$paging_home/.config" "$paging_home/.local/share" -type f -exec sha256sum {} + | sort)" ]] || fail 'invalid patch changed live files'
done

# Configure refuses missing resources/rules without compilation or downloads.
for missing in theme paging; do
  case "$missing" in
    theme) resource="$session_home/.local/share/fcitx5/themes/mellow-vermilion/panel.svg" ;;
    paging) resource="$session_home/.local/share/fcitx5/rime/build/rime_ice.schema.yaml" ;;
  esac
  cp "$resource" "$tmp_dir/saved-resource"
  printf 'invalid\n' >"$resource"
  if [[ "$missing" == theme ]]; then : >"$resource"; fi
  if run_configure --yes >"$tmp_dir/paging-error" 2>&1; then fail 'configure accepted missing prerequisite'; fi
  grep -q 'run install' "$tmp_dir/paging-error" || fail 'configure omitted migration advice'
  cp "$tmp_dir/saved-resource" "$resource"
done

# Font scaling preserves style and fractional/px sizes and records a stable target.
(
  source <(sed '$d' "$script")
  CONFIG_DIR="$tmp_dir/font-unit"
  mkdir -p "$CONFIG_DIR/conf" "$tmp_dir/font-output"
  for pair in 'Example Bold 12.5|Example Bold 20' 'Example 10.25px|Example 16.4px'; do
    original="${pair%|*}"
    expected="${pair#*|}"
    printf 'Font=%s\n' "$original" >"$CONFIG_DIR/conf/classicui.conf"
    prepare_candidate_font "$tmp_dir/font-output"
    [[ "$(cat "$tmp_dir/font-output/candidate-font.txt")" == "$expected" ]] || fail 'incorrect scaled font'
  done
  cp "$tmp_dir/font-output/candidate-font.json" "$CONFIG_DIR/candidate-font.json"
  printf 'Font=Example 99\n' >"$CONFIG_DIR/conf/classicui.conf"
  prepare_candidate_font "$tmp_dir/font-output"
  [[ "$(cat "$tmp_dir/font-output/candidate-font.txt")" == 'Example 16.4px' ]] || fail 'baseline was not reused'
  # Migrate the previous 2x baseline without scaling the already enlarged font again.
  printf '%s\n' '{"version":1,"original":"Example 12.5","target":"Example 25"}' >"$CONFIG_DIR/candidate-font.json"
  prepare_candidate_font "$tmp_dir/font-output"
  [[ "$(cat "$tmp_dir/font-output/candidate-font.txt")" == 'Example 20' ]] || fail 'old baseline migration failed'
  cp "$tmp_dir/font-output/candidate-font.json" "$CONFIG_DIR/candidate-font.json"
  prepare_candidate_font "$tmp_dir/font-output"
  [[ "$(cat "$tmp_dir/font-output/candidate-font.txt")" == 'Example 20' ]] || fail 'migrated font scaled again'
  printf '{}\n' >"$CONFIG_DIR/candidate-font.json"
  if prepare_candidate_font "$tmp_dir/font-output" >/dev/null 2>&1; then fail 'invalid baseline accepted'; fi
  rm "$CONFIG_DIR/candidate-font.json"
  for font in 'Example zero' 'Example 0' 'Example -12'; do
    printf 'Font=%s\n' "$font" >"$CONFIG_DIR/conf/classicui.conf"
    if prepare_candidate_font "$tmp_dir/font-output" >/dev/null 2>&1; then fail 'invalid font accepted'; fi
  done
)

# Framework write failure restores both existing configuration and absent baseline.
rm -f "$session_home/running" "$session_config/candidate-font.json"
printf 'Font=Example 12\n' >"$session_config/conf/classicui.conf"
printf 'framework=previous\n' >"$session_home/.xinputrc"
if STUB_IM_CONFIG_FAIL=1 HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" bash "$script" configure >"$tmp_dir/framework-error" 2>&1; then
  fail 'framework write failure accepted'
fi
assert_contains "$session_home/.xinputrc" 'framework=previous'
assert_contains "$session_config/conf/classicui.conf" 'Font=Example 12'
[[ ! -e "$session_config/candidate-font.json" ]] || fail 'failed write left a baseline'
if STUB_FONT_STATE_FAIL=1 HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" bash "$script" configure >"$tmp_dir/font-error" 2>&1; then
  fail 'font state write failure accepted'
fi
assert_contains "$session_home/.xinputrc" 'framework=previous'
assert_contains "$session_config/conf/classicui.conf" 'Font=Example 12'
[[ ! -e "$session_config/candidate-font.json" ]] || fail 'font failure left a baseline'
HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" bash "$script" configure >/dev/null
assert_contains "$session_config/conf/classicui.conf" 'Font=Example 19.2'
HOME="$session_home" XDG_CONFIG_HOME="$session_home/.config" PATH="$stub_bin:$PATH" bash "$script" configure >/dev/null
assert_contains "$session_config/conf/classicui.conf" 'Font=Example 19.2'

# Exercise the actual Rime compiler when available, with isolated minimal data.
if [[ -x /usr/bin/rime_deployer ]]; then
  (
    source <(sed '$d' "$script")
    real_root="$tmp_dir/real-rime"
    mkdir -p "$real_root/shared" "$real_root/build"
    cat >"$real_root/default.yaml" <<'EOF'
schema_list:
  - schema: rime_ice
key_binder:
  bindings:
    - {when: has_menu, accept: equal, send: Page_Down}
EOF
    cat >"$real_root/rime_ice.schema.yaml" <<'EOF'
schema:
  schema_id: rime_ice
  name: Test Pinyin
  version: '1'
engine:
  processors: [key_binder, speller, punctuator, selector, navigator, express_editor]
  segmentors: [abc_segmentor, fallback_segmentor]
  translators: [echo_translator]
key_binder:
  import_preset: default
EOF
    cat >"$real_root/rime_ice.custom.yaml" <<'EOF'
patch:
  menu/page_size: 7
  key_binder/bindings/+:
    - {when: composing, accept: Control+j, send: Down}
    - {when: has_menu, accept: comma, send: Escape}
EOF
    merge_paging "$real_root"
    /usr/bin/rime_deployer --build "$real_root" "$real_root/shared" "$real_root/build" >"$tmp_dir/real-rime.log" 2>&1 || { cat "$tmp_dir/real-rime.log"; fail 'real Rime compilation failed'; }
    paging_present "$real_root" || fail 'real compiled paging missing'
    /usr/bin/python3 - "$real_root/build/rime_ice.schema.yaml" <<'PYREAL'
import sys, yaml
with open(sys.argv[1]) as stream:
    config = yaml.safe_load(stream)
assert config["menu"]["page_size"] == 7
bindings = config["key_binder"]["bindings"]
assert {"when": "composing", "accept": "Control+j", "send": "Down"} in bindings
assert {"when": "has_menu", "accept": "equal", "send": "Page_Down"} in bindings
PYREAL
  )
else
  printf 'SKIP: real Rime compiler unavailable\n'
fi

printf 'install_fcitx5_pinyin_test: PASS\n'
