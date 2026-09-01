#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="${repo_root}/mp4_to_gif.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${tmp_dir}/bin"
ffmpeg_args="${tmp_dir}/ffmpeg-args.txt"

cat >"${tmp_dir}/bin/ffmpeg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${FAKE_FFMPEG_ARGS}"
EOF

chmod +x "${tmp_dir}/bin/ffmpeg"
export PATH="${tmp_dir}/bin:${PATH}"
export FAKE_FFMPEG_ARGS="${ffmpeg_args}"

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    printf 'Expected output to contain: %s\nActual output:\n%s\n' "${needle}" "${haystack}" >&2
    exit 1
  fi
}

assert_arg() {
  local expected="$1"

  if ! grep -Fxq -- "${expected}" "${ffmpeg_args}"; then
    printf 'Expected ffmpeg argument: %s\nActual arguments:\n' "${expected}" >&2
    cat "${ffmpeg_args}" >&2
    exit 1
  fi
}

assert_fails_with() {
  local expected="$1"
  shift
  local output
  local status

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ "${status}" -eq 0 ]]; then
    printf 'Expected command to fail: %s\n' "$*" >&2
    exit 1
  fi
  assert_contains "${output}" "${expected}"
}

input="${tmp_dir}/sample video.mp4"
touch "${input}"

output="$(${script} "${input}")"
assert_contains "${output}" "Created GIF: ${tmp_dir}/sample video.gif"
assert_arg "-n"
assert_arg "${input}"
assert_arg "fps=15,split[frames][palette_source];[palette_source]palettegen=stats_mode=diff[palette];[frames][palette]paletteuse=dither=sierra2_4a"
assert_arg "${tmp_dir}/sample video.gif"

custom_output="${tmp_dir}/custom output.gif"
"${script}" --resolution 640x360 --fps 12.5 --overwrite "${input}" "${custom_output}" >/dev/null
assert_arg "-y"
assert_arg "fps=12.5,scale=640:360:flags=lanczos,split[frames][palette_source];[palette_source]palettegen=stats_mode=diff[palette];[frames][palette]paletteuse=dither=sierra2_4a"
assert_arg "${custom_output}"

(cd "${tmp_dir}" && "${script}" -- "${input}" "-preview.gif" >/dev/null)
assert_arg "./-preview.gif"

help_output="$(${script} --help)"
assert_contains "${help_output}" "--resolution WIDTHxHEIGHT"
assert_contains "${help_output}" "--fps FPS"

assert_fails_with "input file does not exist" "${script}" "${tmp_dir}/missing.mp4"
assert_fails_with "FPS must be a positive number" "${script}" --fps 0 "${input}"
assert_fails_with "FPS must be a positive number" "${script}" --fps nope "${input}"
assert_fails_with "resolution must use WIDTHxHEIGHT" "${script}" --resolution 640 "${input}"
assert_fails_with "resolution must use WIDTHxHEIGHT" "${script}" --resolution 0x360 "${input}"
assert_fails_with "output file must have a .gif extension" "${script}" "${input}" "${tmp_dir}/output.mp4"

echo "mp4_to_gif tests passed"
