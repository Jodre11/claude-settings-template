#!/usr/bin/env bash
# setup-platform.sh — Configure platform-specific Claude Code settings.
#
# Writes platform-dependent values (e.g. awsAuthRefresh) into
# ~/.claude/settings.local.json, which is gitignored and per-machine.
#
# Idempotent: safe to re-run. Merges into existing settings.local.json
# without clobbering other keys.
#
# Usage:
#   bash ~/.claude/scripts/setup-platform.sh
#
# Prerequisites: jq
set -euo pipefail

SETTINGS_LOCAL="$HOME/.claude/settings.local.json"
SCRIPT_DIR="$HOME/.claude/scripts"

# Detect platform
detect_platform() {
    case "$(uname -s)" in
        Darwin)  echo "macos" ;;
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                echo "wsl"
            else
                echo "linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            echo "windows"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

PLATFORM=$(detect_platform)
echo "Detected platform: $PLATFORM"

# Resolve awsAuthRefresh — a command string that Claude Code passes to the
# system shell. On macOS/Linux/WSL the script path works directly. On Windows,
# Claude Code invokes awsAuthRefresh via CMD, which can't execute .sh files,
# so we need to convert the MSYS path to a native Windows path and wrap it
# with the Git Bash executable.
AWS_REFRESH_SCRIPT="$SCRIPT_DIR/aws-sso-refresh.sh"
if [[ ! -f "$AWS_REFRESH_SCRIPT" ]]; then
    echo "Warning: $AWS_REFRESH_SCRIPT not found — skipping awsAuthRefresh"
    AWS_AUTH_REFRESH=""
elif [[ "$PLATFORM" == "windows" ]]; then
    # Convert MSYS path (/c/Users/...) to Windows path (C:/Users/...)
    WIN_SCRIPT=$(cygpath -w "$AWS_REFRESH_SCRIPT" 2>/dev/null | sed 's|\\|/|g')
    # Git Bash location — MSYS root (/) maps to the Git install directory
    GIT_ROOT=$(cygpath -w / | sed 's|\\|/|g')
    GIT_BASH="${GIT_ROOT}bin/bash.exe"
    AWS_AUTH_REFRESH="\"$GIT_BASH\" \"$WIN_SCRIPT\""
else
    AWS_AUTH_REFRESH="$AWS_REFRESH_SCRIPT"
fi

# Ensure settings.local.json exists with valid JSON
if [[ ! -f "$SETTINGS_LOCAL" ]]; then
    echo "{}" > "$SETTINGS_LOCAL"
elif [[ ! -s "$SETTINGS_LOCAL" ]]; then
    echo "{}" > "$SETTINGS_LOCAL"
fi

# Merge awsAuthRefresh into settings.local.json
if [[ -n "$AWS_AUTH_REFRESH" ]]; then
    echo "Setting awsAuthRefresh: $AWS_AUTH_REFRESH"
    tmp=$(mktemp)
    jq --arg v "$AWS_AUTH_REFRESH" '.awsAuthRefresh = $v' "$SETTINGS_LOCAL" > "$tmp"
    mv "$tmp" "$SETTINGS_LOCAL"
fi

echo ""
echo "Platform setup complete."
echo "  Platform:            $PLATFORM"
echo "  settings.local.json: $SETTINGS_LOCAL"
if [[ -n "$AWS_AUTH_REFRESH" ]]; then
    echo "  awsAuthRefresh:      $AWS_AUTH_REFRESH"
fi
