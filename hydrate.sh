#!/usr/bin/env bash
# hydrate.sh — Generate config files from .tmpl templates using config.env values.
#
# For settings.json: merges template values into the existing file, preserving
# local additions (extra permissions, plugins, env vars, deny rules, etc.).
# For other files: replaces placeholders and overwrites (with diff preview).
#
# Usage:
#   ./hydrate.sh           # interactive: preview diffs, confirm before writing
#   ./hydrate.sh --diff    # preview only, write nothing
#   ./hydrate.sh --force   # write without confirmation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
MODE="interactive"

for arg in "$@"; do
    case "$arg" in
        --diff)  MODE="diff" ;;
        --force) MODE="force" ;;
        *)       echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config.env not found. Copy config.env.example to config.env and fill in your values."
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

CHANGED=0

# Replace __PLACEHOLDER__ tokens in content string.
substitute_placeholders() {
    local content="$1"

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

    printf '%s\n' "$content"
}

# Show diff and optionally write. Returns 0 if file was written, 1 if skipped.
preview_and_write() {
    local output="$1"
    local new_content="$2"

    if [[ -f "$output" ]]; then
        local existing
        existing=$(cat "$output")
        if [[ "$existing" == "$new_content" ]]; then
            echo "  UNCHANGED $output"
            return 1
        fi
        echo "  CHANGED $output"
        diff --color=auto -u "$output" <(printf '%s\n' "$new_content") || true
    else
        echo "  NEW $output"
    fi

    if [[ "$MODE" == "diff" ]]; then
        return 1
    fi

    if [[ "$MODE" == "interactive" ]]; then
        read -r -p "  Write changes to $output? [y/N] " confirm
        if [[ "$confirm" != [yY] ]]; then
            echo "  SKIP $output"
            return 1
        fi
    fi

    printf '%s\n' "$new_content" > "$output"
    echo "  OK $output"
    CHANGED=1
    return 0
}

# Hydrate a simple text template (Markdown, shell scripts).
hydrate_text_template() {
    local tmpl="$1"
    local output="${tmpl%.tmpl}"

    if [[ ! -f "$tmpl" ]]; then
        echo "  SKIP $tmpl (not found)"
        return
    fi

    local content
    content=$(cat "$tmpl")
    content=$(substitute_placeholders "$content")

    preview_and_write "$output" "$content" || true
}

# Hydrate settings.json by merging template base with existing local additions.
hydrate_settings_json() {
    local tmpl="$SCRIPT_DIR/settings.json.tmpl"
    local output="$SCRIPT_DIR/settings.json"

    if [[ ! -f "$tmpl" ]]; then
        echo "  SKIP $tmpl (not found)"
        return
    fi

    # Substitute placeholders in the template
    local tmpl_content
    tmpl_content=$(cat "$tmpl")
    tmpl_content=$(substitute_placeholders "$tmpl_content")

    if [[ ! -f "$output" ]]; then
        # No existing file — just write the template
        preview_and_write "$output" "$tmpl_content" || true
        return
    fi

    # Merge: template provides the base, existing file provides additions.
    # Strategy per key:
    #   - permissions.allow: union (template + existing, deduplicated)
    #   - permissions.deny: union (template + existing, deduplicated)
    #   - env: existing wins for shared keys, both sides contribute new keys
    #   - hooks: existing wins entirely (too complex to merge structurally)
    #   - enabledPlugins, extraKnownMarketplaces: existing wins (personal config)
    #   - scalar keys: existing wins if present, otherwise template
    local merged
    merged=$(jq -s '
        .[0] as $tmpl | .[1] as $existing |

        # Start with existing as the base (preserves all local additions)
        $existing

        # Merge env: template provides defaults, existing overrides
        | .env = ($tmpl.env // {} | to_entries) + ($existing.env // {} | to_entries)
            | .env |= (group_by(.key) | map(last) | from_entries)

        # Merge permissions.allow: existing first, then new entries from template
        | .permissions.allow = (
            ($existing.permissions.allow // []) + (
                ($tmpl.permissions.allow // []) - ($existing.permissions.allow // [])
            )
        )

        # Merge permissions.deny: existing first, then new entries from template
        | .permissions.deny = (
            ($existing.permissions.deny // []) + (
                ($tmpl.permissions.deny // []) - ($existing.permissions.deny // [])
            )
        )

        # Scalar keys: take existing if set, otherwise template
        | .model = ($existing.model // $tmpl.model)
        | .language = ($existing.language // $tmpl.language)
        | .showThinkingSummaries = ($existing.showThinkingSummaries // $tmpl.showThinkingSummaries)
        | .teammateMode = ($existing.teammateMode // $tmpl.teammateMode)

        # awsAuthRefresh: existing wins (set by setup-platform.sh)
        | .awsAuthRefresh = ($existing.awsAuthRefresh // $tmpl.awsAuthRefresh)

        # hooks: existing wins entirely
        | .hooks = ($existing.hooks // $tmpl.hooks)

        # statusLine: existing wins
        | .statusLine = ($existing.statusLine // $tmpl.statusLine)
    ' <(printf '%s\n' "$tmpl_content") "$output")

    preview_and_write "$output" "$merged" || true
}

echo "Hydrating templates from config.env..."
echo ""

hydrate_settings_json
hydrate_text_template "$SCRIPT_DIR/CLAUDE.md.tmpl"
hydrate_text_template "$SCRIPT_DIR/scripts/_aws-sso-common.sh.tmpl"
hydrate_text_template "$SCRIPT_DIR/skills/datadog-log-link/SKILL.md.tmpl"

echo ""
if [[ "$MODE" == "diff" ]]; then
    echo "Preview only — no files were written. Use --force to write without confirmation."
elif [[ "$CHANGED" -eq 1 ]]; then
    echo "Done. Run 'bash scripts/setup-platform.sh' next to configure platform-specific settings."
else
    echo "No changes needed."
fi
