#!/bin/bash
# Usage: ./hf_mirror_download.sh [options] <repo_id>
# Downloads a Hugging Face model or dataset through a mirror endpoint.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./hf_mirror_download.sh [options] <repo_id>

Options:
  -o, --output DIR          Download target directory. Default: ./hf_downloads/<repo_id>
  -e, --endpoint URL        Hugging Face mirror endpoint. Default: https://hf-mirror.com
  -r, --revision REV        Branch, tag, or commit to download.
  -t, --token TOKEN         Hugging Face token for private or gated repos.
  --repo-type TYPE          Repo type: model, dataset, or space. Default: model
  --include PATTERN         Include file pattern. Can be used multiple times.
  --exclude PATTERN         Exclude file pattern. Can be used multiple times.
  --resume                  Resume incomplete downloads.
  --no-symlinks             Store real files instead of symlinks in local dir.
  -h, --help                Show this help.

Examples:
  ./hf_mirror_download.sh Qwen/Qwen2.5-7B-Instruct
  ./hf_mirror_download.sh -o ./models/qwen -r main Qwen/Qwen2.5-7B-Instruct
  ./hf_mirror_download.sh --include '*.safetensors' --include '*.json' meta-llama/Llama-3.1-8B

Install dependency if needed:
  python3 -m pip install -U huggingface_hub
EOF
}

endpoint="https://hf-mirror.com"
output_dir=""
revision=""
token=""
repo_type="model"
resume=false
local_dir_use_symlinks=true
include_patterns=()
exclude_patterns=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        -o|--output)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            output_dir="$2"
            shift 2
            ;;
        -e|--endpoint)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            endpoint="$2"
            shift 2
            ;;
        -r|--revision)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            revision="$2"
            shift 2
            ;;
        -t|--token)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            token="$2"
            shift 2
            ;;
        --repo-type)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            repo_type="$2"
            shift 2
            ;;
        --include)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            include_patterns+=("$2")
            shift 2
            ;;
        --exclude)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            exclude_patterns+=("$2")
            shift 2
            ;;
        --resume)
            resume=true
            shift
            ;;
        --no-symlinks)
            local_dir_use_symlinks=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 1
fi

repo_id="$1"

case "$repo_type" in
    model|dataset|space) ;;
    *)
        echo "Invalid --repo-type: $repo_type. Expected model, dataset, or space." >&2
        exit 1
        ;;
esac

if ! command -v huggingface-cli >/dev/null 2>&1; then
    echo "huggingface-cli not found." >&2
    echo "Install it with: python3 -m pip install -U huggingface_hub" >&2
    exit 127
fi

if [ -z "$output_dir" ]; then
    output_dir="./hf_downloads/$repo_id"
fi

mkdir -p -- "$output_dir"

cmd=(huggingface-cli download "$repo_id" --repo-type "$repo_type" --local-dir "$output_dir")

if [ -n "$revision" ]; then
    cmd+=(--revision "$revision")
fi

if [ -n "$token" ]; then
    cmd+=(--token "$token")
fi

if [ "$resume" = true ]; then
    cmd+=(--resume-download)
fi

if [ "$local_dir_use_symlinks" = false ]; then
    cmd+=(--local-dir-use-symlinks False)
fi

for pattern in "${include_patterns[@]}"; do
    cmd+=(--include "$pattern")
done

for pattern in "${exclude_patterns[@]}"; do
    cmd+=(--exclude "$pattern")
done

echo "HF_ENDPOINT=$endpoint"
echo "Downloading $repo_id to $output_dir"
HF_ENDPOINT="$endpoint" "${cmd[@]}"
