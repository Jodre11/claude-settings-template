#!/usr/bin/env bash
# setup-platform.sh — Configure platform-specific Claude Code settings.
#
# Currently detects the platform and reports it. Platform-specific overrides
# can be added here as needed.
#
# NOTE: awsAuthRefresh lives in settings.json (tracked), NOT settings.local.json.
# Claude Code does not read user-level settings.local.json — only project-level.
# The awsAuthRefresh value uses ~ which Claude Code expands via its resolved bash
# (Git Bash on Windows, /bin/bash on Unix), so it works cross-platform without
# per-machine configuration.
#
# Idempotent: safe to re-run.
#
# Usage:
#   bash ~/.claude/scripts/setup-platform.sh
#
# Prerequisites: jq
set -euo pipefail

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

echo ""
echo "Platform setup complete."
echo "  Platform: $PLATFORM"
echo ""
echo "awsAuthRefresh is configured in settings.json (cross-platform)."
echo "If AWS SSO is not working, verify ~/.claude/scripts/aws-sso-refresh.sh exists."
