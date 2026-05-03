#!/usr/bin/env bash
set -euo pipefail

APP_PATH="$1"
LOG_FILE="$2"

if [[ -x "$APP_PATH" ]]; then
    exec "$APP_PATH" >> "$LOG_FILE" 2>&1
fi

exec dotnet "$APP_PATH" >> "$LOG_FILE" 2>&1
