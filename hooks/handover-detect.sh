#!/usr/bin/env bash
# handover-detect.sh — SessionStart hook for the phase-handover workflow.
#
# Sweeps the handovers directory: deletes any handover whose front-matter status
# is `consumed`, and any file older than HANDOVER_MAX_AGE_DAYS regardless of
# status (backstop reaper for handovers abandoned without an explicit retire),
# and any subdirectory with nothing in it newer than that age. A top-level
# `.keep` file in a subdirectory exempts it from reaping.
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

    # Directory sweep: reap a direct subdirectory once nothing in it (itself included) is newer than the threshold,
    # unless it holds a top-level `.keep`. `-type d` never matches a symlink, so a linked target is never reached.
    # It fails closed: a mis-set HANDOVER_DIR or age, or a find error, deletes nothing.
    if [[ "$(basename "$HANDOVER_DIR")" == handovers && "$HANDOVER_MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
        while IFS= read -r -d '' d; do
            [[ -e "$d/.keep" ]] && continue
            recent=$(find "$d" ! -mtime "+${HANDOVER_MAX_AGE_DAYS}" -print -quit 2>/dev/null) || continue
            [[ -z "$recent" ]] || continue
            rm -rf "$d" 2>/dev/null || true
        done < <(find "$HANDOVER_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi
fi
exit 0
