#!/bin/bash

# Configuration
MODELS_FILE="$HOME/.ez_cc_models.json"
CLAUDE_CONFIG="$HOME/.claude.json"
BACKUP_DIR="$HOME/.ez_cc_switch"
MAX_BACKUPS=5

# Ensure jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Please install jq to use this script."
    exit 1
fi

# Initialize models file if it doesn't exist
if [ ! -f "$MODELS_FILE" ]; then
    echo '{"models": {}}' > "$MODELS_FILE"
fi

usage() {
    echo "Usage: $0 {add|list|rm|edit|switch} [args]"
    echo "  add <<<modelmodelmodelmodel> <<<urlurlurlurl>     Add or update a model configuration"
    echo "  list                        List all saved models"
    echo "  rm <<<modelmodelmodelmodel>                   Remove a model configuration"
    echo "  edit <<<modelmodelmodelmodel> <<<urlurlurlurl>    Edit a model's URL"
    echo "  switch <<<modelmodelmodelmodel>               Switch Claude Code to the specified model"
    exit 1
}

# Backup function with rotation
backup_config() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/.claude.json.$timestamp"

    cp "$CLAUDE_CONFIG" "$backup_file"

    # Rotate backups: keep only the most recent MAX_BACKUPS
    ls -t "$BACKUP_DIR"/.claude.json.* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm
}

case "$1" in
    add)
        if [ "$#" -ne 3 ]; then
            echo "Usage: $0 add <<<modelmodelmodelmodel> <<<urlurlurlurl>"
            exit 1
        fi
        model=$2
        url=$3

        tmp=$(mktemp)
        jq --arg model "$model" --arg url "$url" \
           '.models[$model] = {"url": $url}' "$MODELS_FILE" > "$tmp" && mv "$tmp" "$MODELS_FILE"
        echo "Added model '$model' successfully."
        ;;

    list)
        echo "Saved Local Models:"
        echo "--------------------------------------------------------------------------------"
        printf "%-40s %-40s\n" "MODEL" "URL"
        echo "--------------------------------------------------------------------------------"
        jq -r '.models | to_entries[] | "\(.key)\t\(.value.url)"' "$MODELS_FILE" | while IFS=$'\t' read -r model url; do
            printf "%-40s %-40s\n" "$model" "$url"
        done
        ;;

    rm)
        if [ "$#" -ne 2 ]; then
            echo "Usage: $0 rm <<<modelmodelmodelmodel>"
            exit 1
        fi
        model=$2

        # Check if model exists before removing
        if ! jq -e ".models[\"$model\"]" "$MODELS_FILE" > /dev/null; then
            echo "Error: Model '$model' not found in library."
            exit 1
        fi

        tmp=$(mktemp)
        jq --arg model "$model" 'del(.models[$model])' "$MODELS_FILE" > "$tmp" && mv "$tmp" "$MODELS_FILE"
        echo "Removed model '$model' successfully."
        ;;

    edit)
        if [ "$#" -ne 3 ]; then
            echo "Usage: $0 edit <<<modelmodelmodelmodel> <<<urlurlurlurl>"
            exit 1
        fi
        model=$2
        url=$3

        if ! jq -e ".models[\"$model\"]" "$MODELS_FILE" > /dev/null; then
            echo "Error: Model '$model' not found in library."
            exit 1
        fi

        tmp=$(mktemp)
        jq --arg model "$model" --arg url "$url" \
           '.models[$model] = {"url": $url}' "$MODELS_FILE" > "$tmp" && mv "$tmp" "$MODELS_FILE"
        echo "Updated URL for model '$model' successfully."
        ;;

    switch)
        if [ "$#" -ne 2 ]; then
            echo "Usage: $0 switch <<<modelmodelmodelmodel>"
            exit 1
        fi
        model=$2

        # Get model details
        model_data=$(jq -r ".models[\"$model\"]" "$MODELS_FILE")
        if [ "$model_data" == "null" ]; then
            echo "Error: Model '$model' not found in library."
            exit 1
        fi

        url=$(echo "$model_data" | jq -r '.url')
        api_base="${url%/}/v1"

        echo "Switching to model '$model'..."

        # 1. Backup current config
        backup_config

        # 2. Update .claude.json
        tmp=$(mktemp)
        jq --arg url "$url" --arg model "$model" --arg api_base "$api_base" \
           '.env.ANTHROPIC_BASE_URL = $url |
            .env.ANTHROPIC_MODEL = $model |
            .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $model |
            .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $model |
            .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $model |
            .apiBase = $api_base' "$CLAUDE_CONFIG" > "$tmp" && mv "$tmp" "$CLAUDE_CONFIG"

        echo "Successfully switched to '$model'!"
        echo "API Base: $api_base"
        echo "Model: $model"
        ;;

    *)
        usage
        ;;
esac
