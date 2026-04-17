#!/usr/bin/env bash
# hydrate.sh — Generate config files from .tmpl templates using config.env values.
# Idempotent: safe to re-run. Overwrites generated files each time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config.env not found. Copy config.env.example to config.env and fill in your values."
    exit 1
fi

# Source config.env (provides all __PLACEHOLDER__ values)
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Replace __PLACEHOLDER__ tokens in a .tmpl file and write the output (without .tmpl extension).
# Usage: hydrate_template <template_file>
hydrate_template() {
    local tmpl="$1"
    local output="${tmpl%.tmpl}"

    if [[ ! -f "$tmpl" ]]; then
        echo "  SKIP $tmpl (not found)"
        return
    fi

    local content
    content=$(cat "$tmpl")

    # settings.json
    content="${content//__AWS_SSO_REFRESH_PATH__/${AWS_SSO_REFRESH_PATH:-}}"
    content="${content//__AWS_PROFILE__/${AWS_PROFILE:-}}"

    # _aws-sso-common.sh
    content="${content//__SSO_START_URL__/${SSO_START_URL:-}}"

    # datadog-log-link SKILL.md
    content="${content//__DATADOG_SITE__/${DATADOG_SITE:-}}"
    content="${content//__DATADOG_EXAMPLE_SERVICE__/${DATADOG_EXAMPLE_SERVICE:-}}"

    # CLAUDE.md
    content="${content//__DOTFILES_REPO_URL__/${DOTFILES_REPO_URL:-}}"
    content="${content//__CLAUDE_SETTINGS_REPO_URL__/${CLAUDE_SETTINGS_REPO_URL:-}}"

    printf '%s\n' "$content" > "$output"
    echo "  OK $tmpl → $output"
}

echo "Hydrating templates from config.env..."

hydrate_template "$SCRIPT_DIR/settings.json.tmpl"
hydrate_template "$SCRIPT_DIR/CLAUDE.md.tmpl"
hydrate_template "$SCRIPT_DIR/scripts/_aws-sso-common.sh.tmpl"
hydrate_template "$SCRIPT_DIR/skills/datadog-log-link/SKILL.md.tmpl"

echo ""
echo "Done. Generated files are .gitignore'd in the template repo."
echo "Run 'bash scripts/setup-platform.sh' next to configure platform-specific settings."
