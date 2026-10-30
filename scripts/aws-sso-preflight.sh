#!/usr/bin/env bash
# aws-sso-preflight.sh — Check SSO token validity before launching Claude Code.
# Reads the local SSO cache (no network call). If expired, runs aws sso login.
# Also detects stale ~/.aws/credentials that can confuse the SDK credential chain.
# CLAUDE_SSO_MIN_HOURS (a whole number; the dotfiles claude wrapper sets 7 for CLAUDE_UNATTENDED=1) asks for a token
# that outlasts the run: one expiring sooner is refreshed now, while someone is there to complete the browser sign-in.
set -euo pipefail

source "$(dirname "$0")/_aws-sso-common.sh"

GRACE_SECONDS=300  # Refresh if token expires within 5 minutes
min_hours=${CLAUDE_SSO_MIN_HOURS:-}
if [[ "$min_hours" =~ ^[0-9]+$ ]] && (( min_hours * 3600 > GRACE_SECONDS )); then
    GRACE_SECONDS=$(( min_hours * 3600 ))
elif [[ -n "$min_hours" ]]; then
    echo "aws-sso-preflight: ignoring CLAUDE_SSO_MIN_HOURS='$min_hours' (not a whole number of hours)" >&2
fi

remove_stale_credentials

# token_check: print valid or expired for the cached token against GRACE_SECONDS.
token_check() {
    python3 "$SSO_CACHE_CHECK" \
        --cache-dir "$CACHE_DIR" \
        --start-url "$SSO_START_URL" \
        --mode expiry \
        --grace-seconds "$GRACE_SECONDS" 2>/dev/null || echo "expired"
}

if [[ "$(token_check)" == "valid" ]]; then
    exit 0
fi

if (( GRACE_SECONDS > 300 )); then
    echo "AWS SSO token expires within ${min_hours} h, too soon for an unattended run. Logging in..."
else
    echo "AWS SSO token expired or missing. Logging in..."
fi
aws sso login --profile "$PROFILE"

# A sign-in whose browser session is still open can return a token bounded by that session, not a fresh one.
if (( GRACE_SECONDS > 300 )) && [[ "$(token_check)" != "valid" ]]; then
    echo "aws-sso-preflight: the new token still expires within ${min_hours} h; the IAM Identity Center session may" \
        "end first. Sign out of the AWS access portal and run again for a full session." >&2
fi
