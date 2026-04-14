#!/usr/bin/env bash
# _aws-sso-common.sh — Shared constants for AWS SSO scripts.
# Source this at the top of aws-sso-preflight.sh and aws-sso-refresh.sh.

PROFILE="claude-code"
SSO_START_URL="https://havenholidays.awsapps.com/start"
CACHE_DIR="$HOME/.aws/sso/cache"
CREDS_FILE="$HOME/.aws/credentials"
SSO_CACHE_CHECK="$(dirname "$0")/sso-cache-check.py"

# Guard: warn and remove stale credentials file that poisons the SDK resolution chain.
# All auth goes through SSO — temporary STS creds in this file are always stale leftovers.
# See anthropics/claude-code#12421 for the full story.
remove_stale_credentials() {
    if [[ -f "$CREDS_FILE" ]]; then
        echo "⚠ Found ~/.aws/credentials — this can interfere with SSO auth."
        echo "  Backing up to ~/.aws/credentials.bak and removing."
        mv "$CREDS_FILE" "${CREDS_FILE}.bak"
    fi
}
