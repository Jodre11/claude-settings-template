#!/usr/bin/env bash
# handover-detect.sh — SessionStart hook for the phase-handover workflow.
#
# Sweeps the handovers directory: deletes any handover whose front-matter status
# is `consumed`, and any file older than HANDOVER_MAX_AGE_DAYS regardless of
# status (backstop reaper for handovers abandoned without an explicit retire).
# This keeps the central store self-limiting.
#
# It injects nothing: resuming is the user's explicit /rehydrate. An injected
# "run /rehydrate first" also steered `claude -p` and background sessions. It
# must never block session startup: every failure path exits 0 and emits nothing.

set -uo pipefail

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
exit 0
