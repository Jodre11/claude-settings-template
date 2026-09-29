#!/usr/bin/env bash
# hydrate.sh — Generate config files from .tmpl templates using config.env values.
#
# settings.json.tmpl is merged into the existing settings.json (or into {} on a fresh clone):
#   - permissions.allow / ask / deny, enabledMcpjsonServers: union, existing entries first
#   - env: union, existing wins; null and empty-string values are dropped from both sides first, and an env left
#     empty is not written
#   - permissions' other keys and every other top-level key: existing wins, the template fills gaps. A null
#     top-level value in the existing file counts as a gap: delete a key through __remove__, not by nulling it
#   - hooks: template wins (infrastructure, edited only via the template)
#   - __remove__ (template only) is applied after the unions and never written out:
#       "keys":    jq paths to delete, e.g. ["sandbox"] or ["env", "X"]
#       "entries": dotted array path -> values to drop, e.g. "permissions.allow": ["Bash(x *)"]
#     Any other shape stops the run before anything is written.
# The output is key-sorted (jq -S), and the comparison with the existing file ignores key order.
#
# CLAUDE.md.tmpl, scripts/_aws-sso-common.sh.tmpl and skills/datadog-log-link/SKILL.md.tmpl are rendered: their
# placeholders are replaced and the output is overwritten.
#
# Every NEW or CHANGED report prints its diff. A write goes to a temp file beside the output and is then moved over
# it, so each output is mode 0600 and a failed write leaves it as it was: hydrate.sh then prints FAIL and exits 1. An
# output that exists but is not a regular file (a symlink or a directory) is refused the same way.
#
# Usage:
#   ./hydrate.sh           # interactive: preview diffs, confirm before writing
#   ./hydrate.sh --diff    # preview only, write nothing
#   ./hydrate.sh --force   # write without confirmation
set -euo pipefail
# bash >= 5.2 expands & in a ${var//pattern/replacement} replacement to the match; keep config.env values literal.
shopt -u patsub_replacement 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
MODE="interactive"
HY_TMP=""

# remove_temp: delete the temp file an interrupted or failed write_output left behind.
remove_temp() {
    if [[ -n "$HY_TMP" ]]; then
        rm -f -- "$HY_TMP"
    fi
}
trap remove_temp EXIT
trap 'exit 1' HUP INT TERM

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

# Replace __PLACEHOLDER__ tokens in a content string.
substitute_placeholders() {
    local content="$1"

    # settings.json
    content="${content//__AWS_SSO_REFRESH_PATH__/${AWS_SSO_REFRESH_PATH:-}}"
    content="${content//__AWS_PROFILE__/${AWS_PROFILE:-}}"
    content="${content//__SEARXNG_URL__/${SEARXNG_URL:-}}"

    # _aws-sso-common.sh
    content="${content//__SSO_START_URL__/${SSO_START_URL:-}}"

    # datadog-log-link SKILL.md
    content="${content//__DATADOG_SITE__/${DATADOG_SITE:-}}"
    content="${content//__DATADOG_EXAMPLE_SERVICE__/${DATADOG_EXAMPLE_SERVICE:-}}"

    # CLAUDE.md
    content="${content//__DOTFILES_REPO_URL__/${DOTFILES_REPO_URL:-}}"
    content="${content//__CLAUDE_SETTINGS_REPO_URL__/${CLAUDE_SETTINGS_REPO_URL:-}}"

    printf '%s\n' "$content"
}

# require_regular <output>: exit 1 with a FAIL line when <output> exists but is not a regular file (a symlink or a
# directory), which the write would replace or write into.
require_regular() {
    if [[ -L "$1" || ( -e "$1" && ! -f "$1" ) ]]; then
        echo "  FAIL $1 (not a regular file; hydrate.sh only replaces regular files)" >&2
        exit 1
    fi
}

# write_output <output> <content>: write <content> to a temp file in <output>'s directory, then move it over
# <output>. On any failure print FAIL and exit 1, leaving <output> as it was; the EXIT trap removes the temp.
write_output() {
    local output="$1" content="$2"
    if ! HY_TMP=$(mktemp "$(dirname -- "$output")/.$(basename -- "$output").hydrate.XXXXXX"); then
        HY_TMP=""
        echo "  FAIL $output (cannot create a temp file beside it)" >&2
        exit 1
    fi
    if ! printf '%s\n' "$content" >"$HY_TMP" || ! mv -f -- "$HY_TMP" "$output"; then
        echo "  FAIL $output (the write failed; the file is unchanged)" >&2
        exit 1
    fi
    HY_TMP=""
}

# preview_and_write <output> <new-content> [<current-content>]: print UNCHANGED, or CHANGED or NEW with a unified
# diff, then write <new-content> unless --diff or the user declines. <current-content>, when given, stands in for
# the file's bytes in the comparison. Returns 0 if the file was written, 1 if not.
preview_and_write() {
    local output="$1"
    local new_content="$2"

    require_regular "$output"
    if [[ -f "$output" ]]; then
        local existing
        if [[ $# -ge 3 ]]; then
            existing="$3"
        else
            existing=$(cat "$output")
        fi
        if [[ "$existing" == "$new_content" ]]; then
            echo "  UNCHANGED $output"
            return 1
        fi
        echo "  CHANGED $output"
        diff --color=auto -u --label "$output" --label "$output (hydrated)" \
            <(printf '%s\n' "$existing") <(printf '%s\n' "$new_content") || true
    else
        echo "  NEW $output"
        diff --color=auto -u --label /dev/null --label "$output (hydrated)" \
            /dev/null <(printf '%s\n' "$new_content") || true
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

    write_output "$output" "$new_content"
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

# Merge filter: input is [template, existing]. See the header for the per-key strategy.
# shellcheck disable=SC2016  # $tmpl, $existing, $p ... are jq variables, not shell expansions
MERGE_FILTER='
def non_empty_env: with_entries(select(.value != null and .value != ""));
def union_at($p; $t; $e):
    ($e | getpath($p)) as $ev | ($t | getpath($p)) as $tv
    | if $ev == null and $tv == null then .
      else setpath($p; ($ev // []) + (($tv // []) - ($ev // [])))
      end;
def checked_remove:
    if . == null then {}
    elif type != "object" then error("__remove__ must be an object, not \(type)")
    elif (keys - ["entries", "keys"]) != [] then
        error("__remove__ has unknown keys: \(keys - ["entries", "keys"] | join(", "))")
    elif ((.keys | if . == null then [] else . end) | type != "array"
          or any(.[]; type != "array" or length == 0 or any(.[]; type != "string" and type != "number"))) then
        error("__remove__.keys must be an array of non-empty jq paths")
    elif ((.entries | if . == null then {} else . end) | type != "object" or any(.[]; type != "array")) then
        error("__remove__.entries must map each dotted path to an array of values")
    else . end;

.[0] as $tmpl | (.[1] // {} | with_entries(select(.value != null))) as $existing
| ($tmpl.__remove__ | checked_remove) as $rm
| ($tmpl + $existing)
| .env = (($tmpl.env // {} | non_empty_env) + ($existing.env // {} | non_empty_env))
| if $tmpl.permissions == null and $existing.permissions == null then .
  else .permissions = (($tmpl.permissions // {}) + ($existing.permissions // {}))
  end
| union_at(["permissions", "allow"]; $tmpl; $existing)
| union_at(["permissions", "ask"]; $tmpl; $existing)
| union_at(["permissions", "deny"]; $tmpl; $existing)
| union_at(["enabledMcpjsonServers"]; $tmpl; $existing)
| .hooks = ($tmpl.hooks // $existing.hooks)
| delpaths($rm.keys // [])
| reduce (($rm.entries // {}) | to_entries[]) as $e (.;
    ($e.key | split(".")) as $p
    | if getpath($p) == null then . else setpath($p; getpath($p) - $e.value) end)
| del(.__remove__)
| if .env == {} then del(.env) else . end
| with_entries(select(.value != null))
'

# Hydrate settings.json: merge the placeholder-substituted template into the existing file (or {}), then
# preview and write the key-sorted result.
hydrate_settings_json() {
    local tmpl="$SCRIPT_DIR/settings.json.tmpl"
    local output="$SCRIPT_DIR/settings.json"

    if [[ ! -f "$tmpl" ]]; then
        echo "  SKIP $tmpl (not found)"
        return
    fi

    local tmpl_content
    tmpl_content=$(cat "$tmpl")
    tmpl_content=$(substitute_placeholders "$tmpl_content")

    local existing='{}'
    if [[ -f "$output" ]]; then
        existing=$(jq -S . "$output")
    fi

    local merged
    merged=$(jq -S -s "$MERGE_FILTER" <(printf '%s\n' "$tmpl_content") <(printf '%s\n' "$existing"))

    if [[ -f "$output" ]]; then
        preview_and_write "$output" "$merged" "$existing" || true
    else
        preview_and_write "$output" "$merged" || true
    fi
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
