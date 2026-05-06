#!/usr/bin/env bash
# apply-settings.sh — Apply settings template changes to settings.json.
#
# Lifts skip-worktree, runs hydrate --force, then re-runs setup-platform.sh
# to inject platform-specific values and re-apply skip-worktree.
#
# Usage:
#   bash ~/.claude/scripts/apply-settings.sh
#
# Idempotent: safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "1/3  Lifting skip-worktree on settings.json..."
git -C "$CLAUDE_DIR" update-index --no-skip-worktree settings.json

echo "2/3  Hydrating settings from template..."
"$CLAUDE_DIR/hydrate.sh" --force

echo "3/3  Applying platform-specific settings (re-enables skip-worktree)..."
bash "$SCRIPT_DIR/setup-platform.sh"

echo ""
echo "Settings applied successfully."
