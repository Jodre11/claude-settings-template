#!/usr/bin/env bash
# aws-sso-preflight.sh — Check SSO token validity before launching Claude Code.
# Reads the local SSO cache (no network call). If expired, runs aws sso login.
# Also detects stale ~/.aws/credentials that can confuse the SDK credential chain.
set -euo pipefail

source "$(dirname "$0")/_aws-sso-common.sh"

GRACE_SECONDS=300  # Refresh if token expires within 5 minutes

remove_stale_credentials

token_valid=$(python3 "$SSO_CACHE_CHECK" \
    --cache-dir "$CACHE_DIR" \
    --start-url "$SSO_START_URL" \
    --mode expiry \
    --grace-seconds "$GRACE_SECONDS" 2>/dev/null || echo "expired")

if [[ "$token_valid" == "valid" ]]; then
    exit 0
fi

echo "AWS SSO token expired or missing. Logging in..."
aws sso login --profile "$PROFILE"
