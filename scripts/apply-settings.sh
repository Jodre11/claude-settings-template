#!/usr/bin/env bash
# apply-settings.sh — Apply settings.json.tmpl changes to the generated settings.json.
#
# Runs hydrate --force, then setup-platform.sh to activate the git hooks and inject the
# platform-specific values. Preview first with: ~/.claude/hydrate.sh --diff
#
# Usage:
#   bash ~/.claude/scripts/apply-settings.sh
#
# Idempotent: safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "1/2  Hydrating settings from template..."
"$CLAUDE_DIR/hydrate.sh" --force

echo "2/2  Applying platform-specific settings..."
bash "$SCRIPT_DIR/setup-platform.sh"

echo ""
echo "Settings applied successfully."
