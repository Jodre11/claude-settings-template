#!/usr/bin/env bash
# aws-sso-preflight.sh — Check SSO token validity before launching Claude Code.
# Reads the local SSO cache (no network call). If expired, runs aws sso login.
# Also detects stale ~/.aws/credentials that can confuse the SDK credential chain.
set -euo pipefail

PROFILE="claude-code"
SSO_START_URL="https://havenholidays.awsapps.com/start"
CACHE_DIR="$HOME/.aws/sso/cache"
GRACE_SECONDS=300  # Refresh if token expires within 5 minutes

# Guard: warn and remove stale credentials file that poisons the SDK resolution chain.
# All auth goes through SSO — temporary STS creds in this file are always stale leftovers.
# See anthropics/claude-code#12421 for the full story.
CREDS_FILE="$HOME/.aws/credentials"
if [[ -f "$CREDS_FILE" ]]; then
    echo "⚠ Found ~/.aws/credentials — this can interfere with SSO auth."
    echo "  Backing up to ~/.aws/credentials.bak and removing."
    cp "$CREDS_FILE" "${CREDS_FILE}.bak"
    rm "$CREDS_FILE"
fi

token_valid=$(python3 -c "
import json, glob, os, sys
from datetime import datetime, timezone, timedelta

cache_dir = os.path.expanduser('$CACHE_DIR')
start_url = '$SSO_START_URL'
grace = timedelta(seconds=$GRACE_SECONDS)
now = datetime.now(timezone.utc)

for path in glob.glob(os.path.join(cache_dir, '*.json')):
    try:
        with open(path) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        continue
    if data.get('startUrl') != start_url:
        continue
    if 'accessToken' not in data:
        continue
    expires_str = data.get('expiresAt', '')
    try:
        expires_str = expires_str.replace('Z', '+00:00')
        expires = datetime.fromisoformat(expires_str)
        if expires - grace > now:
            print('valid')
            sys.exit(0)
    except (ValueError, TypeError):
        continue

print('expired')
" 2>/dev/null || echo "expired")

if [[ "$token_valid" == "valid" ]]; then
    exit 0
fi

echo "AWS SSO token expired or missing. Logging in..."
aws sso login --profile "$PROFILE"
