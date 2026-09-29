#!/usr/bin/env bash
# setup-platform.sh — Configure platform-specific Claude Code settings.
#
# Activates the repo's git hooks, then writes awsAuthRefresh into settings.json with the correct
# platform-specific value. settings.json is generated per machine by hydrate.sh from the tracked
# settings.json.tmpl and is gitignored, so run hydrate.sh first.
#
# WHY settings.json and not settings.local.json?
# Claude Code only reads settings.local.json at the PROJECT level
# (<project>/.claude/settings.local.json), NOT the user level
# (~/.claude/settings.local.json). User-level settings.local.json is silently
# ignored. So per-machine values go in the generated settings.json.
#
# WHY can't we use ~ or $HOME in awsAuthRefresh?
# On macOS/Linux/WSL, awsAuthRefresh is run through bash — ~ and $HOME work.
# On Windows, awsAuthRefresh is run through CMD — neither ~ nor $HOME expand.
# Hooks, statusLine, and permissions DO go through bash on all platforms, so
# they CAN use ~. awsAuthRefresh is the exception, so each machine needs its
# own absolute path.
#
# Idempotent: safe to re-run.
#
# Usage:
#   bash ~/.claude/hydrate.sh --force
#   bash ~/.claude/scripts/setup-platform.sh
#
# Prerequisites: git, jq
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$CLAUDE_DIR/scripts"

# Activate the in-repo git hooks first, so a fresh clone is guarded even if the steps below fail. Only when
# $CLAUDE_DIR is its own repository's top level: otherwise git -C would retarget an enclosing repository's hooks.
# --show-prefix is empty exactly there, and it compares no paths, so Git Bash's C:/ and /c/ spellings cannot differ.
if git_prefix=$(git -C "$CLAUDE_DIR" rev-parse --show-prefix 2>/dev/null) && [[ -z "$git_prefix" ]]; then
    echo "Activating git hooks (core.hooksPath .githooks)..."
    git -C "$CLAUDE_DIR" config core.hooksPath .githooks
else
    echo "Warning: $CLAUDE_DIR is not the top level of its own git repository; not activating git hooks." >&2
fi

if [[ ! -f "$SETTINGS" ]]; then
    echo "Error: $SETTINGS not found. Run $CLAUDE_DIR/hydrate.sh first." >&2
    exit 1
fi

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

echo ""
echo "Platform setup complete."
echo "  Platform:       $PLATFORM"
echo "  settings.json:  $SETTINGS"
echo "  git hooks:      $CLAUDE_DIR/.githooks"
if [[ -n "$AWS_AUTH_REFRESH" ]]; then
    echo "  awsAuthRefresh: $AWS_AUTH_REFRESH"
fi
