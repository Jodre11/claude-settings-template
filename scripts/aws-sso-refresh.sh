#!/usr/bin/env bash
# aws-sso-refresh.sh — Smart AWS SSO login for Claude Code's awsAuthRefresh.
#
# Guards against the auth refresh loop (anthropics/claude-code#12421):
# 1. Skip if SSO token was refreshed recently (propagation delay)
# 2. After login, poll until credentials are confirmed working
#
# Local:  opens browser automatically (zero interaction).
# Remote: uses --no-browser, strips box art, emits clean OSC 8 hyperlinks.
set -euo pipefail

PROFILE="claude-code"
SSO_START_URL="https://havenholidays.awsapps.com/start"
CACHE_DIR="$HOME/.aws/sso/cache"
SKIP_IF_NEWER_THAN=120  # seconds
POLL_TIMEOUT=30          # seconds

# Guard: remove stale credentials file if it reappears
CREDS_FILE="$HOME/.aws/credentials"
if [[ -f "$CREDS_FILE" ]]; then
    cp "$CREDS_FILE" "${CREDS_FILE}.bak"
    rm "$CREDS_FILE"
fi

# Skip if SSO token was written recently (avoids re-trigger during propagation)
newest_age=$(python3 -c "
import json, glob, os, sys, time

cache_dir = os.path.expanduser('$CACHE_DIR')
start_url = '$SSO_START_URL'
newest = None

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
    mtime = os.path.getmtime(path)
    if newest is None or mtime > newest:
        newest = mtime

if newest is not None:
    print(int(time.time() - newest))
else:
    print(999999)
" 2>/dev/null || echo "999999")

if [[ "$newest_age" -lt "$SKIP_IF_NEWER_THAN" ]]; then
    echo "SSO token refreshed ${newest_age}s ago, skipping re-login"
    exit 0
fi

# Retry wrapper: try normal auth code flow first; if the localhost redirect
# doesn't complete (cold browser session loses the callback URL), the browser
# SSO session is still warmed as a side effect. Retry succeeds immediately.
_sso_login_with_retry() {
    local profile="$1"
    local wait_secs="${2:-45}"

    # Disable errexit locally: if the timeout kills the process, wait returns
    # non-zero and we need to continue to the retry, not abort the script.
    local login_pid timer_pid login_status
    set +e

    echo "Attempting SSO login (will retry automatically if redirect fails)..."
    aws sso login --profile "$profile" &
    login_pid=$!

    # Timer subshell: kill login after timeout, then exit.
    # Backgrounded with & so it shares a process group — kill propagates to sleep.
    # && is intentional: if sleep is killed (login succeeded), skip the kill to
    # avoid signalling a recycled PID. Do not change to ;
    (sleep "$wait_secs" && kill "$login_pid" 2>/dev/null) &
    timer_pid=$!

    wait "$login_pid" 2>/dev/null
    login_status=$?

    # Clean up timer (subshell + sleep) to avoid orphans
    kill "$timer_pid" 2>/dev/null
    wait "$timer_pid" 2>/dev/null

    set -e

    if [[ "$login_status" -eq 0 ]]; then
        return 0
    fi

    # First attempt failed — browser session should now be warm.
    # No timeout on retry: if the browser session didn't warm (different problem),
    # hanging here is no worse than the pre-fix behaviour.
    echo "SSO redirect did not complete. Retrying with warm browser session..."
    aws sso login --profile "$profile"
}

# Perform the login
if [[ -z "${SSH_CONNECTION:-}" ]]; then
    _sso_login_with_retry "$PROFILE" 45
else
    # Remote (SSH): use --no-browser, emit OSC 8 clickable links
    aws sso login --profile "$PROFILE" --no-browser 2>&1 \
        | while IFS= read -r line; do
            if [[ "$line" =~ (https://[^[:space:]]+) ]]; then
                url="${BASH_REMATCH[1]}"
                printf '\e]8;;%s\e\\%s\e]8;;\e\\\n' "$url" "$url"
            fi
        done
fi

# Poll until credentials are confirmed working (avoids Claude retrying before propagation)
elapsed=0
while [[ "$elapsed" -lt "$POLL_TIMEOUT" ]]; do
    if aws sts get-caller-identity --profile "$PROFILE" &>/dev/null; then
        exit 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

echo "Warning: credentials not yet valid after ${POLL_TIMEOUT}s polling"
exit 0
