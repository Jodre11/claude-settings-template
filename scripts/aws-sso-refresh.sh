#!/usr/bin/env bash
# aws-sso-refresh.sh — Smart AWS SSO login for Claude Code's awsAuthRefresh.
#
# Local:  opens browser automatically (zero interaction).
# Remote: uses --no-browser, strips box art, emits clean OSC 8 hyperlinks.
set -euo pipefail

PROFILE="claude-code"

if [[ -z "${SSH_CONNECTION:-}" ]]; then
    # Local session: browser opens automatically, no URL to copy
    exec aws sso login --profile "$PROFILE"
fi

# Remote (SSH): use --no-browser, reformat output for copyability.
# The pipe streams each line in real-time. Only URLs pass through,
# wrapped in OSC 8 escape sequences for clickable links in Termius/iTerm2.
# The pipe keeps the script alive until aws sso login exits.
aws sso login --profile "$PROFILE" --no-browser 2>&1 \
    | while IFS= read -r line; do
        if [[ "$line" =~ (https://[^[:space:]]+) ]]; then
            url="${BASH_REMATCH[1]}"
            printf '\e]8;;%s\e\\%s\e]8;;\e\\\n' "$url" "$url"
        fi
    done
