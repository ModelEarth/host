#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="$ROOT_DIR/host/net/net.yaml"
ENV_FILE="$ROOT_DIR/docker/.env"
PORTABLE_DOTNET_DIR="${HOME}/.dotnet"
SCREEN_SESSION_NAME="webroot-dotnet"
RUNNER_SCRIPT="$ROOT_DIR/host/net/run-host.sh"

if [[ -d "$PORTABLE_DOTNET_DIR" ]]; then
    export PATH="$PORTABLE_DOTNET_DIR:$PATH"
    export DOTNET_ROOT="$PORTABLE_DOTNET_DIR"
    export DOTNET_ROOT_X64="$PORTABLE_DOTNET_DIR"
fi

read_config_value() {
    local key="$1"
    python3 - "$CONFIG_FILE" "$key" <<'PY'
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
target_key = sys.argv[2]

for raw_line in config_path.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or ":" not in line:
        continue
    key, value = line.split(":", 1)
    if key.strip() == target_key:
        print(value.strip().strip("'\""))
        break
PY
}

load_env_file() {
    local env_path="$1"
    if [[ ! -f "$env_path" ]]; then
        return
    fi

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        [[ "$line" != *=* ]] && continue

        local key="${line%%=*}"
        local value="${line#*=}"

        key="$(printf '%s' "$key" | sed 's/[[:space:]]*$//')"
        value="${value%%#*}"
        value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

        export "$key=$value"
    done < "$env_path"
}

ensure_dotnet_cli() {
    if ! command -v dotnet >/dev/null 2>&1; then
        if [[ "${AUTO_INSTALL_SDK:-false}" == "true" ]]; then
            install_sdk
        fi
    fi

    if ! command -v dotnet >/dev/null 2>&1; then
        cat >&2 <<EOF
dotnet CLI not found.

You can install the .NET SDK using one of these commands:
  bash host/net/net.sh install-sdk
  bash host/net/net.sh start --install-sdk

Guidance:
  $ROOT_DIR/host/net/NET.md
EOF
        exit 1
    fi
}

PROJECT_DIR="$(read_config_value project_dir)"
PROJECT_FILE="$(read_config_value project_file)"
TARGET_FRAMEWORK="$(read_config_value target_framework)"
ASSEMBLY_NAME="$(read_config_value assembly_name)"
DEFAULT_HOST="$(read_config_value host)"
DEFAULT_PORT="$(read_config_value port)"
HEALTH_PATH="$(read_config_value health_path)"
SDK_CHANNEL="$(read_config_value sdk_channel)"
SITE_ROOT_VALUE="$(read_config_value site_root)"
STATS_ROOT_VALUE="$(read_config_value stats_root)"
FALLBACK_TO_ROOT_ON_MISSING="$(read_config_value fallback_to_root_on_missing)"
LOG_FILE_RELATIVE="$(read_config_value log_file)"

PROJECT_PATH="$ROOT_DIR/$PROJECT_FILE"
LOG_FILE="$ROOT_DIR/$LOG_FILE_RELATIVE"
SITE_ROOT_PATH="$ROOT_DIR/$SITE_ROOT_VALUE"
APP_DLL_PATH="$ROOT_DIR/$PROJECT_DIR/bin/Debug/$TARGET_FRAMEWORK/$ASSEMBLY_NAME.dll"
APP_HOST_PATH="$ROOT_DIR/$PROJECT_DIR/bin/Debug/$TARGET_FRAMEWORK/$ASSEMBLY_NAME"

load_env_file "$ENV_FILE"

DOTNET_HOST_VALUE="${DOTNET_HOST:-$DEFAULT_HOST}"
DOTNET_PORT_VALUE="${DOTNET_PORT:-$DEFAULT_PORT}"
DOTNET_ENVIRONMENT_VALUE="${DOTNET_ENVIRONMENT:-Development}"
DOTNET_SITE_ROOT_VALUE="${DOTNET_SITE_ROOT:-$SITE_ROOT_PATH}"
AUTO_INSTALL_SDK="false"

if [[ "$DOTNET_SITE_ROOT_VALUE" != /* ]]; then
    DOTNET_SITE_ROOT_VALUE="$ROOT_DIR/$DOTNET_SITE_ROOT_VALUE"
fi

install_sdk_with_brew() {
    brew install --cask dotnet-sdk
}

install_sdk_with_apt() {
    sudo apt-get update
    sudo apt-get install -y "dotnet-sdk-${SDK_CHANNEL}"
}

install_sdk_with_dnf() {
    sudo dnf install -y "dotnet-sdk-${SDK_CHANNEL}"
}

install_sdk_with_yum() {
    sudo yum install -y "dotnet-sdk-${SDK_CHANNEL}"
}

install_sdk_with_pacman() {
    sudo pacman -Sy --noconfirm dotnet-sdk
}

install_sdk_with_winget() {
    winget install --accept-package-agreements --accept-source-agreements Microsoft.DotNet.SDK.10
}

install_sdk_portable() {
    local install_dir="${HOME}/.dotnet"
    local install_script

    install_script="$(mktemp)"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$install_script"
    bash "$install_script" --channel "$SDK_CHANNEL" --install-dir "$install_dir"
    rm -f "$install_script"

    export PATH="$install_dir:$PATH"

    cat <<EOF
Portable .NET SDK installed to:
  $install_dir

Add this to your shell profile if needed:
  export PATH="$install_dir:\$PATH"
EOF
}

install_sdk() {
    if command -v dotnet >/dev/null 2>&1; then
        echo "dotnet CLI is already installed."
        return
    fi

    echo "Attempting to install .NET SDK channel $SDK_CHANNEL..."

    if [[ "$(uname -s)" == "Darwin" ]] && command -v brew >/dev/null 2>&1; then
        if install_sdk_with_brew; then
            return
        fi
        echo "Homebrew install did not complete. Falling back to the portable user-space installer."
        install_sdk_portable
        return
    fi

    if command -v winget >/dev/null 2>&1; then
        install_sdk_with_winget
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        install_sdk_with_apt
        return
    fi

    if command -v dnf >/dev/null 2>&1; then
        install_sdk_with_dnf
        return
    fi

    if command -v yum >/dev/null 2>&1; then
        install_sdk_with_yum
        return
    fi

    if command -v pacman >/dev/null 2>&1; then
        install_sdk_with_pacman
        return
    fi

    echo "No supported package manager detected for system-wide install."
    echo "Falling back to the portable user-space installer."
    install_sdk_portable
}

start_server() {
    ensure_dotnet_cli
    mkdir -p "$(dirname "$LOG_FILE")"

    if lsof -ti:"$DOTNET_PORT_VALUE" >/dev/null 2>&1; then
        echo ".NET host already appears to be running on port $DOTNET_PORT_VALUE"
        exit 0
    fi

    (
        cd "$ROOT_DIR"
        export DOTNET_HOST="$DOTNET_HOST_VALUE"
        export DOTNET_PORT="$DOTNET_PORT_VALUE"
        export DOTNET_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE"
        export DOTNET_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE"
        export DOTNET_STATS_ROOT="${DOTNET_STATS_ROOT:-$STATS_ROOT_VALUE}"
        export DOTNET_FALLBACK_TO_ROOT_ON_MISSING="${DOTNET_FALLBACK_TO_ROOT_ON_MISSING:-$FALLBACK_TO_ROOT_ON_MISSING}"
        export ASPNETCORE_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE"
        export ASPNETCORE_URLS="http://$DOTNET_HOST_VALUE:$DOTNET_PORT_VALUE"
        export WEBROOT_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE"
        export DOTNET_ROOT="${DOTNET_ROOT:-$PORTABLE_DOTNET_DIR}"
        export DOTNET_ROOT_X64="${DOTNET_ROOT_X64:-$PORTABLE_DOTNET_DIR}"
        chmod +x "$RUNNER_SCRIPT"
        dotnet build "$PROJECT_PATH" >/dev/null
        local app_path="$APP_DLL_PATH"
        if [[ -x "$APP_HOST_PATH" ]]; then
            app_path="$APP_HOST_PATH"
        fi
        if [[ "$(uname -s)" == "Darwin" ]] && command -v screen >/dev/null 2>&1; then
            screen -S "$SCREEN_SESSION_NAME" -X quit >/dev/null 2>&1 || true
            env PATH="$PATH" DOTNET_ROOT="$DOTNET_ROOT" DOTNET_ROOT_X64="$DOTNET_ROOT_X64" DOTNET_HOST="$DOTNET_HOST_VALUE" DOTNET_PORT="$DOTNET_PORT_VALUE" DOTNET_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE" DOTNET_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE" DOTNET_FALLBACK_TO_ROOT_ON_MISSING="$DOTNET_FALLBACK_TO_ROOT_ON_MISSING" ASPNETCORE_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE" ASPNETCORE_URLS="http://$DOTNET_HOST_VALUE:$DOTNET_PORT_VALUE" WEBROOT_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE" screen -dmS "$SCREEN_SESSION_NAME" "$RUNNER_SCRIPT" "$app_path" "$LOG_FILE"
        else
            env PATH="$PATH" DOTNET_ROOT="$DOTNET_ROOT" DOTNET_ROOT_X64="$DOTNET_ROOT_X64" DOTNET_HOST="$DOTNET_HOST_VALUE" DOTNET_PORT="$DOTNET_PORT_VALUE" DOTNET_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE" DOTNET_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE" DOTNET_FALLBACK_TO_ROOT_ON_MISSING="$DOTNET_FALLBACK_TO_ROOT_ON_MISSING" ASPNETCORE_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE" ASPNETCORE_URLS="http://$DOTNET_HOST_VALUE:$DOTNET_PORT_VALUE" WEBROOT_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE" "$RUNNER_SCRIPT" "$app_path" "$LOG_FILE" < /dev/null &>/dev/null &
        fi
    )

    echo "Started .NET host on http://$DOTNET_HOST_VALUE:$DOTNET_PORT_VALUE"
    echo "Health: http://$DOTNET_HOST_VALUE:$DOTNET_PORT_VALUE$HEALTH_PATH"
    echo "Log: $LOG_FILE"
}

install_server() {
    ensure_dotnet_cli

    if [[ ! -f "$ENV_FILE" && -f "$ROOT_DIR/docker/.env.example" ]]; then
        cp "$ROOT_DIR/docker/.env.example" "$ENV_FILE"
        echo "Created docker/.env from docker/.env.example"
    fi

    (
        cd "$ROOT_DIR"
        export DOTNET_HOST="$DOTNET_HOST_VALUE"
        export DOTNET_PORT="$DOTNET_PORT_VALUE"
        export DOTNET_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE"
        export DOTNET_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE"
        export DOTNET_STATS_ROOT="${DOTNET_STATS_ROOT:-$STATS_ROOT_VALUE}"
        export DOTNET_FALLBACK_TO_ROOT_ON_MISSING="${DOTNET_FALLBACK_TO_ROOT_ON_MISSING:-$FALLBACK_TO_ROOT_ON_MISSING}"
        export ASPNETCORE_ENVIRONMENT="$DOTNET_ENVIRONMENT_VALUE"
        export ASPNETCORE_URLS="http://$DOTNET_HOST_VALUE:$DOTNET_PORT_VALUE"
        export WEBROOT_SITE_ROOT="$DOTNET_SITE_ROOT_VALUE"
        dotnet restore "$PROJECT_PATH"
    )

    echo ".NET restore complete for $PROJECT_PATH"
}

show_status() {
    local health_url="http://$DOTNET_HOST_VALUE:$DOTNET_PORT_VALUE$HEALTH_PATH"
    if curl -fsS "$health_url" >/dev/null 2>&1; then
        echo ".NET host is running at $health_url"
    else
        echo ".NET host is not responding at $health_url"
        exit 1
    fi
}

stop_server() {
    screen -S "$SCREEN_SESSION_NAME" -X quit >/dev/null 2>&1 || true
    if lsof -ti:"$DOTNET_PORT_VALUE" >/dev/null 2>&1; then
        lsof -ti:"$DOTNET_PORT_VALUE" | xargs kill
        local attempts=0
        while lsof -ti:"$DOTNET_PORT_VALUE" >/dev/null 2>&1 && [[ "$attempts" -lt 20 ]]; do
            sleep 0.25
            attempts=$((attempts + 1))
        done
        echo "Stopped .NET host on port $DOTNET_PORT_VALUE"
    else
        echo "No process found on port $DOTNET_PORT_VALUE"
    fi
}

print_nginx_help() {
    echo "Generate nginx config from .backend manifests:"
    echo "python3 docker/nginx/generate-nginx-conf.py && nginx -s reload"
}

show_help() {
    cat <<EOF
Usage: bash host/net/net.sh <command>

Commands:
  install       Restore the modern .NET host project
  install-sdk   Install the .NET SDK (package manager first, portable fallback)
  start         Start the shared .NET host in the background
  status        Check the .NET health endpoint
  stop          Stop the .NET host port
  print-nginx   Print the nginx regeneration command
  help          Show this message

Start flags:
  --install-sdk  Attempt SDK install first when dotnet is missing

Config:
  $CONFIG_FILE

Environment:
  $ENV_FILE
EOF
}

COMMAND="${1:-help}"
if [[ "${2:-}" == "--install-sdk" ]]; then
    AUTO_INSTALL_SDK="true"
fi

case "$COMMAND" in
    install) install_server ;;
    install-sdk) install_sdk ;;
    start) start_server ;;
    status) show_status ;;
    stop) stop_server ;;
    print-nginx) print_nginx_help ;;
    help|--help|-h) show_help ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        show_help
        exit 1
        ;;
esac
