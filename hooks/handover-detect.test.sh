#!/usr/bin/env bash
# Tests for handover-detect.sh: the SessionStart sweep deletes consumed handovers and any older than
# HANDOVER_MAX_AGE_DAYS, keeps an active one, and injects nothing, so no session (`claude -p` and background ones
# included) is steered into /rehydrate.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/handover-detect.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
store="$tmp/handovers"
work="$tmp/work"
mkdir -p "$store" "$work"

# handover <file> <status>: write a minimal handover whose front matter carries <status>.
handover() {
    printf -- '---\nstatus: %s\n---\n\n# Handover: test\n' "$2" > "$1"
}

active=$(cd "$work" && HANDOVER_DIR="$store" bash "$DIR/../scripts/handover-path.sh")
handover "$active" active
handover "$store/finished.md" consumed
handover "$store/abandoned.md" active
touch -t 202001010000 "$store/abandoned.md"

out=$(cd "$work" \
    && printf '{"hook_event_name":"SessionStart","source":"startup"}' \
    | HANDOVER_DIR="$store" HANDOVER_MAX_AGE_DAYS=30 "$HOOK" 2>&1)
rc=$?

if [[ "$rc" -eq 0 ]]; then ok "the hook exits 0"; else bad "the hook exited $rc"; fi
if [[ -z "$out" ]]; then ok "an active handover for the cwd injects nothing"; else bad "the hook printed: $out"; fi
if [[ -f "$active" ]]; then ok "the cwd's active handover is kept"; else bad "the cwd's active handover was deleted"; fi
if [[ ! -e "$store/finished.md" ]]; then ok "a consumed handover is deleted"; else bad "a consumed handover is kept"; fi
if [[ ! -e "$store/abandoned.md" ]]; then
    ok "a handover older than HANDOVER_MAX_AGE_DAYS is deleted, whatever its status"
else
    bad "a handover older than HANDOVER_MAX_AGE_DAYS is kept"
fi

if jq -e '.hooks.SessionStart[] | .hooks[] | select(.command == "~/.claude/hooks/handover-detect.sh")' \
        "$DIR/../settings.json.tmpl" >/dev/null 2>&1; then
    ok "settings.json.tmpl still registers handover-detect.sh on SessionStart"
else
    bad "settings.json.tmpl does not register handover-detect.sh on SessionStart"
fi

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
