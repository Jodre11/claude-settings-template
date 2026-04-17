#!/usr/bin/env bash
# setup-platform.sh — Configure platform-specific Claude Code settings.
#
# Writes awsAuthRefresh into settings.json with the correct platform-specific
# value, then hides the local change from git via skip-worktree.
#
# WHY settings.json and not settings.local.json?
# Claude Code only reads settings.local.json at the PROJECT level
# (<project>/.claude/settings.local.json), NOT the user level
# (~/.claude/settings.local.json). User-level settings.local.json is silently
# ignored. So per-machine overrides must go in settings.json with skip-worktree.
#
# WHY skip-worktree?
# awsAuthRefresh must use an absolute path because Claude Code passes it to the
# system shell — CMD on Windows, which does not expand ~ or $HOME. Each machine
# therefore needs a different value. skip-worktree lets us modify the tracked
# settings.json locally without the change showing in git status.
#
# WHY can't we use ~ or $HOME in awsAuthRefresh?
# On macOS/Linux/WSL, awsAuthRefresh is run through bash — ~ and $HOME work.
# On Windows, awsAuthRefresh is run through CMD — neither ~ nor $HOME expand.
# Hooks, statusLine, and permissions DO go through bash on all platforms, so
# they CAN use ~. awsAuthRefresh is the exception.
#
# TO COMMIT OTHER settings.json CHANGES:
#   git -C ~/.claude update-index --no-skip-worktree settings.json
#   git -C ~/.claude stash
#   # ... make changes, commit, push ...
#   git -C ~/.claude stash pop
#   bash ~/.claude/scripts/setup-platform.sh   # re-applies skip-worktree
#
# Idempotent: safe to re-run.
#
# Usage:
#   bash ~/.claude/scripts/setup-platform.sh
#
# Prerequisites: jq
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$CLAUDE_DIR/scripts"

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

# Resolve awsAuthRefresh command
AWS_REFRESH_SCRIPT="$SCRIPT_DIR/aws-sso-refresh.sh"
if [[ ! -f "$AWS_REFRESH_SCRIPT" ]]; then
    echo "Warning: $AWS_REFRESH_SCRIPT not found — skipping awsAuthRefresh"
    AWS_AUTH_REFRESH=""
elif [[ "$PLATFORM" == "windows" ]]; then
    # Windows: Claude Code passes awsAuthRefresh to CMD, which cannot expand ~
    # or $HOME and cannot execute .sh files. Wrap with Git Bash using absolute
    # Windows paths. cygpath -w converts MSYS paths to native Windows paths.
    WIN_SCRIPT=$(cygpath -w "$AWS_REFRESH_SCRIPT" 2>/dev/null | sed 's|\\|/|g')
    GIT_ROOT=$(cygpath -w / | sed 's|\\|/|g')
    GIT_BASH="${GIT_ROOT}bin/bash.exe"
    AWS_AUTH_REFRESH="\"$GIT_BASH\" \"$WIN_SCRIPT\""
else
    # macOS/Linux/WSL: awsAuthRefresh is run through bash, so absolute paths work.
    # We use the resolved $HOME (not ~) for robustness.
    AWS_AUTH_REFRESH="$AWS_REFRESH_SCRIPT"
fi

# Write awsAuthRefresh into settings.json
if [[ -n "$AWS_AUTH_REFRESH" ]]; then
    echo "Setting awsAuthRefresh: $AWS_AUTH_REFRESH"
    tmp=$(mktemp)
    jq --arg v "$AWS_AUTH_REFRESH" '.awsAuthRefresh = $v' "$SETTINGS" > "$tmp"
    mv "$tmp" "$SETTINGS"
fi

# Hide the local modification from git
echo "Applying skip-worktree to settings.json..."
git -C "$CLAUDE_DIR" update-index --skip-worktree settings.json

echo ""
echo "Platform setup complete."
echo "  Platform:       $PLATFORM"
echo "  settings.json:  $SETTINGS (skip-worktree applied)"
if [[ -n "$AWS_AUTH_REFRESH" ]]; then
    echo "  awsAuthRefresh: $AWS_AUTH_REFRESH"
fi
