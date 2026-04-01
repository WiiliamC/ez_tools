#!/bin/bash
# Usage: ./until_success.sh <command>
# Repeatedly executes the given command until it succeeds (exit code 0)

attempt=1
while true; do
    echo "Attempt $attempt: $@"
    eval "$@"
    exit_code=$?
    if [ $exit_code -eq 0 ]; then
        echo "Command succeeded"
        break
    fi
    echo "Command failed with exit code $exit_code, retrying..."
    attempt=$((attempt + 1))
    sleep 1
done
