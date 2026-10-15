#!/usr/bin/env bash
# Tests for handover-detect.sh: the SessionStart sweep deletes consumed handovers and any older than
# HANDOVER_MAX_AGE_DAYS, keeps an active one, and injects nothing, so no session (`claude -p` and background ones
# included) is steered into /rehydrate. It also reaps a wholly-stale subdirectory unless a top-level `.keep` marks it,
# and never follows a symlink out of the store.
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

# Subdirectory fixtures. Contents are written before the directory's own mtime is set, since writing a file bumps it.
old=202001010000
mkdir -p "$store/stale/nested" "$store/kept" "$store/mixed" "$store/recent" "$tmp/outside/target"
touch -t "$old" "$store/stale/ledger.md" "$store/stale/nested/x.md" "$store/stale/nested" "$store/stale"
touch -t "$old" "$store/kept/.keep" "$store/kept/notes.md" "$store/kept"
touch -t "$old" "$store/mixed/old.md"
touch "$store/mixed/new.md"
touch -t "$old" "$store/mixed"
touch -t "$old" "$store/recent/old.md"
touch -t "$old" "$tmp/outside/target/x.md" "$tmp/outside/target"
ln -s "$tmp/outside/target" "$store/link"
touch -h -t "$old" "$store/link"

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
if [[ ! -e "$store/stale" ]]; then ok "an old subdirectory is reaped"; else bad "an old subdirectory is kept"; fi
if [[ -f "$store/kept/notes.md" ]]; then
    ok "an old subdirectory with a top-level .keep is kept"
else
    bad "an old subdirectory with a top-level .keep is reaped"
fi
if [[ -f "$store/mixed/old.md" ]]; then
    ok "an old subdirectory holding one recent file is kept"
else
    bad "an old subdirectory holding one recent file is reaped"
fi
if [[ -f "$store/recent/old.md" ]]; then ok "a recent subdirectory is kept"; else bad "a recent subdirectory is reaped"; fi
if [[ -L "$store/link" && -f "$tmp/outside/target/x.md" ]]; then
    ok "a symlink to an old directory outside the store is left alone, and so is its target"
else
    bad "a symlinked directory or its target was touched"
fi

# Fail-closed: a sweep that cannot prove a directory stale must not delete it.
store2="$tmp/s2/handovers"
mkdir -p "$store2/recent"
touch "$store2/recent/new.md"
(cd "$work" && HANDOVER_DIR="$store2" HANDOVER_MAX_AGE_DAYS=abc "$HOOK" </dev/null >/dev/null 2>&1)
if [[ -f "$store2/recent/new.md" ]]; then
    ok "a non-numeric HANDOVER_MAX_AGE_DAYS reaps nothing"
else
    bad "a non-numeric HANDOVER_MAX_AGE_DAYS reaped a recent subdirectory"
fi

store3="$tmp/s3/handovers"
mkdir -p "$store3/locked/sealed"
touch "$store3/locked/sealed/new.md"
touch -t "$old" "$store3/locked/old.md" "$store3/locked/sealed" "$store3/locked"
chmod 000 "$store3/locked/sealed"
(cd "$work" && HANDOVER_DIR="$store3" HANDOVER_MAX_AGE_DAYS=30 "$HOOK" </dev/null >/dev/null 2>&1)
chmod 755 "$store3/locked/sealed"
if [[ -f "$store3/locked/old.md" ]]; then
    ok "a subdirectory the sweep cannot fully read is kept"
else
    bad "a subdirectory the sweep cannot fully read was reaped"
fi

# A HANDOVER_DIR override that is not a handovers store must never be swept recursively.
notstore="$tmp/home"
mkdir -p "$notstore/project"
touch -t "$old" "$notstore/project/file.txt" "$notstore/project"
(cd "$work" && HANDOVER_DIR="$notstore" HANDOVER_MAX_AGE_DAYS=30 "$HOOK" </dev/null >/dev/null 2>&1)
if [[ -f "$notstore/project/file.txt" ]]; then
    ok "a HANDOVER_DIR not named handovers gets no directory sweep"
else
    bad "a HANDOVER_DIR not named handovers had its subdirectories reaped"
fi

if jq -e '.hooks.SessionStart[] | .hooks[] | select(.command == "~/.claude/hooks/handover-detect.sh")' \
        "$DIR/../settings.json.tmpl" >/dev/null 2>&1; then
    ok "settings.json.tmpl still registers handover-detect.sh on SessionStart"
else
    bad "settings.json.tmpl does not register handover-detect.sh on SessionStart"
fi

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
