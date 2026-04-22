#!/bin/bash

# Configuration
MODELS_FILE="$HOME/.ez_cc_models.json"
CLAUDE_CONFIG="$HOME/.claude.json"
OPENCIDE_CONFIG="$HOME/.config/opencode/opencode.json"
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
    echo "Usage: $0 {add|list|rm|edit|switch|sync-opencode} [args]"
    echo "  add <<<modelmodelmodelmodel> <<<urlurlurlurl>     Add or update a model configuration"
    echo "  list                        List all saved models"
    echo "  rm <<<modelmodelmodelmodel>                   Remove a model configuration"
    echo "  edit <<<modelmodelmodelmodel> <<<urlurlurlurl>    Edit a model's URL"
    echo "  switch <<<modelmodelmodelmodel>               Switch Claude Code to the specified model"
    echo "  sync-opencode                   Sync all models to OpenCode config (with backup)"
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

# Backup OpenCode config with rotation
backup_opencode_config() {
    mkdir -p "$BACKUP_DIR"
    local timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_file="$BACKUP_DIR/opencode.json.$timestamp"

    if [ -f "$OPENCIDE_CONFIG" ]; then
        cp "$OPENCIDE_CONFIG" "$backup_file"
    fi

    # Rotate backups: keep only the most recent MAX_BACKUPS
    ls -t "$BACKUP_DIR"/opencode.json.* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm
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

    sync-opencode)
        if [ "$#" -ne 1 ]; then
            echo "Usage: $0 sync-opencode"
            exit 1
        fi

        # Check if models file exists and has models
        model_count=$(jq '.models | length' "$MODELS_FILE")
        if [ "$model_count" -eq 0 ]; then
            echo "Error: No models found in library. Add models first with 'add' command."
            exit 1
        fi

        echo "Syncing $model_count model(s) to OpenCode config..."

        # 1. Backup current opencode config
        backup_opencode_config

        # 2. Group models by port
        # Extract unique ports from urls
        ports=$(jq -r '.models[].url' "$MODELS_FILE" | sed 's|http://||' | cut -d':' -f2 | sort -u)

        # Build provider JSON
        providers_json="{}"
        first_model=""
        first_provider=""

        for port in $ports; do
            provider_id="local-$port"
            base_url="http://$(jq -r '.models[].url' "$MODELS_FILE" | grep ":$port" | head -1 | sed 's|http://||')"

            # Get all models for this port
            models_json="{}"
            while IFS= read -r model_name; do
                model_url=$(jq -r ".models[\"$model_name\"].url" "$MODELS_FILE")
                url_port=$(echo "$model_url" | sed 's|http://||' | cut -d':' -f2)
                if [ "$url_port" = "$port" ]; then
                models_json=$(echo "$models_json" | jq --arg m "$model_name" --arg n "$model_name" \
                    '. + {$m: {"name": $n}}')
                fi
            done < <(jq -r '.models | keys[]' "$MODELS_FILE")

            # Build provider entry
            providers_json=$(echo "$providers_json" | jq --arg pid "$provider_id" --arg port "$port" --arg url "$base_url/v1" \
                --argjson m "$models_json" \
                '. + {$pid: {"npm": "@ai-sdk/openai-compatible", "name": ("Local " + $port), "options": {"baseURL": $url}, "models": $m}}')
        done

        # 3. Merge providers into existing config (preserve other settings)
        tmp=$(mktemp)
        jq --argjson providers "$providers_json" \
            '.provider = $providers' "$OPENCIDE_CONFIG" > "$tmp" && mv "$tmp" "$OPENCIDE_CONFIG"

        echo "Successfully synced to OpenCode config!"
        ;;

    *)
        usage
        ;;
esac
