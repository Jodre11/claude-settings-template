#!/usr/bin/env bash
# handover-detect.sh — SessionStart hook for the phase-handover workflow.
#
# Two jobs, in order:
#   1. Sweep the handovers directory: delete any handover whose front-matter
#      status is `consumed`, and any file older than HANDOVER_MAX_AGE_DAYS
#      regardless of status (backstop reaper for handovers abandoned without an
#      explicit retire). This keeps the central store self-limiting.
#   2. If an *active* handover exists for the current working directory, inject
#      additionalContext telling the model to read it and reconcile against the
#      working tree before resuming (clean match → resume; contradiction → ask).
#
# The hook never decides staleness itself — a shell script can't reason about
# whether repo state contradicts a handover. It only detects presence + status
# and hands the judgement to the model via /rehydrate. It must never block
# session startup: every failure path exits 0 and emits nothing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HANDOVER_DIR="${HANDOVER_DIR:-$HOME/.claude/handovers}"
HANDOVER_MAX_AGE_DAYS="${HANDOVER_MAX_AGE_DAYS:-30}"

# Read the `status:` value from a handover's YAML-ish front matter. Front matter
# is the first block delimited by `---` lines; we scan only to the closing
# delimiter so a `status:` mention later in prose can't be misread.
handover_status() {
    local file="$1" line in_fm=0 status=""
    [[ -f "$file" ]] || { printf 'missing'; return; }
    while IFS= read -r line; do
        if [[ "$line" == '---' ]]; then
            if [[ $in_fm -eq 0 ]]; then in_fm=1; continue; else break; fi
        fi
        if [[ $in_fm -eq 1 && "$line" == status:* ]]; then
            status="${line#status:}"
            status="${status//[[:space:]]/}"
            break
        fi
    done < "$file"
    printf '%s' "${status:-unknown}"
}

# --- Job 1: sweep -----------------------------------------------------------
if [[ -d "$HANDOVER_DIR" ]]; then
    # Age backstop: delete files older than the threshold, any status.
    find "$HANDOVER_DIR" -maxdepth 1 -type f -name '*.md' \
        -mtime "+${HANDOVER_MAX_AGE_DAYS}" -delete 2>/dev/null || true

    # Status sweep: delete consumed handovers.
    for f in "$HANDOVER_DIR"/*.md; do
        [[ -e "$f" ]] || continue
        if [[ "$(handover_status "$f")" == "consumed" ]]; then
            rm -f "$f" 2>/dev/null || true
        fi
    done
fi

# --- Job 2: detect active handover for this cwd -----------------------------
handover_path=$(bash "$SCRIPT_DIR/../scripts/handover-path.sh" 2>/dev/null) || exit 0
[[ -n "$handover_path" && -f "$handover_path" ]] || exit 0

status=$(handover_status "$handover_path")
[[ "$status" == "active" ]] || exit 0

ctx="A handover artifact is present for this directory at ${handover_path} (status: active). \
Before doing anything else, run the /rehydrate workflow: read the handover, recompute the \
working-tree fingerprint and reconcile it against what the handover recorded, disclose which \
reconciliation mode applies (repo working-tree check, or trust-the-file outside a repo), then \
resume on a clean match or stop and ask the user on any contradiction. Do not resume blindly \
on the handover's say-so."

jq -n --arg ctx "$ctx" \
    '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}' 2>/dev/null \
    || exit 0
