#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/install_fcitx5_pinyin.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains() { grep -Fqx -- "$2" "$1" || fail "missing $2 in $1"; }

make_stubs() {
  local bin="$1"
  mkdir -p "$bin"
  cat >"$bin/apt-get" <<'EOF'
#!/usr/bin/env bash
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
  chmod +x "$bin"/*
}

run_install() {
  HOME="$1" XDG_CONFIG_HOME="$1/.config" PATH="$2:$PATH" bash "$script" install
}

stub_bin="${tmp_dir}/bin"
make_stubs "$stub_bin"

# Fresh configuration creates a usable keyboard + Pinyin profile and requested settings.
fresh_home="${tmp_dir}/fresh"
mkdir -p "$fresh_home"
run_install "$fresh_home" "$stub_bin"
profile="${fresh_home}/.config/fcitx5/profile"
assert_contains "$profile" '[Groups/0/Items/0]'
assert_contains "$profile" 'Name=keyboard-us'
assert_contains "$profile" '[Groups/0/Items/1]'
assert_contains "$profile" 'Name=pinyin'
assert_contains "${fresh_home}/.config/fcitx5/conf/pinyin.conf" 'CloudPinyinEnabled=True'
assert_contains "${fresh_home}/.config/fcitx5/conf/pinyin.conf" 'CloudPinyinIndex=2'
assert_contains "${fresh_home}/.config/fcitx5/conf/pinyin.conf" 'Prediction=True'
assert_contains "${fresh_home}/.config/fcitx5/conf/pinyin.conf" 'KeepCurrentContext=True'
assert_contains "${fresh_home}/.config/fcitx5/conf/cloudpinyin.conf" 'Backend=Baidu'
assert_contains "${fresh_home}/.config/fcitx5/conf/classicui.conf" 'Theme=Material-Color-black'

# An existing multi-IM profile is retained, Pinyin is merged into its default group,
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

[Unrelated]
Keep=This

[GroupOrder]
0=Work
1=Default
EOF
cat >"${merge_home}/.config/fcitx5/conf/pinyin.conf" <<'EOF'
# preserve me
OtherSetting=keep
EOF
run_install "$merge_home" "$stub_bin"
merge_profile="${merge_home}/.config/fcitx5/profile"
assert_contains "$merge_profile" 'Name=mozc'
assert_contains "$merge_profile" 'Name=anthy'
assert_contains "$merge_profile" '[Groups/1/Items/2]'
[[ "$(grep -c '^Name=pinyin$' "$merge_profile")" == 1 ]] || fail 'Pinyin was not added exactly once'
assert_contains "$merge_profile" 'Keep=This'
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

if HOME="$fresh_home" PATH="$stub_bin:$PATH" bash "$script" invalid >/dev/null 2>&1; then
  fail 'invalid command unexpectedly succeeded'
fi
if STUB_UID=0 HOME="$fresh_home" PATH="$stub_bin:$PATH" bash "$script" status >/dev/null 2>&1; then
  fail 'root invocation unexpectedly succeeded'
fi

printf 'install_fcitx5_pinyin_test: PASS\n'
