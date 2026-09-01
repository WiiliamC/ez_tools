#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./mp4_to_gif.sh [options] <input.mp4> [output.gif]

Options:
  -r, --resolution WIDTHxHEIGHT  Set the output resolution (for example, 640x360).
  -f, --fps FPS                  Set the output frame rate (default: 15).
  -y, --overwrite                Overwrite the output file if it exists.
  -h, --help                     Show this help message.

Examples:
  ./mp4_to_gif.sh video.mp4
  ./mp4_to_gif.sh --resolution 640x360 --fps 12 video.mp4 preview.gif
EOF
}

resolution=""
fps="15"
overwrite="-n"
declare -a positional=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -r|--resolution)
      if [[ "$#" -lt 2 ]]; then
        echo "Error: $1 requires WIDTHxHEIGHT." >&2
        usage >&2
        exit 1
      fi
      resolution="$2"
      shift 2
      ;;
    -f|--fps)
      if [[ "$#" -lt 2 ]]; then
        echo "Error: $1 requires a frame rate." >&2
        usage >&2
        exit 1
      fi
      fps="$2"
      shift 2
      ;;
    -y|--overwrite)
      overwrite="-y"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      positional+=("$@")
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

if [[ "${#positional[@]}" -lt 1 || "${#positional[@]}" -gt 2 ]]; then
  usage >&2
  exit 1
fi

input="${positional[0]}"
if [[ "${#positional[@]}" -eq 2 ]]; then
  output="${positional[1]}"
else
  if [[ "${input}" == *.* ]]; then
    output="${input%.*}.gif"
  else
    output="${input}.gif"
  fi
fi

if [[ ! -f "${input}" ]]; then
  echo "Error: input file does not exist or is not a regular file: ${input}" >&2
  exit 1
fi

if [[ ! "${fps}" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
   ! awk -v value="${fps}" 'BEGIN { exit !(value > 0) }'; then
  echo "Error: FPS must be a positive number: ${fps}" >&2
  exit 1
fi

if [[ -n "${resolution}" && ! "${resolution}" =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]]; then
  echo "Error: resolution must use WIDTHxHEIGHT with positive integers: ${resolution}" >&2
  exit 1
fi

if [[ "${output,,}" != *.gif ]]; then
  echo "Error: output file must have a .gif extension: ${output}" >&2
  exit 1
fi

if [[ "${output}" == -* ]]; then
  output="./${output}"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: requires ffmpeg." >&2
  exit 2
fi

filter="fps=${fps}"
if [[ -n "${resolution}" ]]; then
  width="${resolution%x*}"
  height="${resolution#*x}"
  filter+=",scale=${width}:${height}:flags=lanczos"
fi
filter+=",split[frames][palette_source];[palette_source]palettegen=stats_mode=diff[palette];[frames][palette]paletteuse=dither=sierra2_4a"

ffmpeg "${overwrite}" -i "${input}" -filter_complex "${filter}" -loop 0 "${output}"

echo "Created GIF: ${output}"
