#!/usr/bin/env bash
# Hermetic unit tests for bash-guard.sh — focused on the code-review worktree
# carve-out in the temp-directory enforcement block.
#
# The hook always exits 0; its verdict lives in the JSON it prints on stdout.
# A denial emits "permissionDecision":"deny"; an allow prints nothing. So each
# case pipes a crafted tool_input.command and inspects stdout for a deny marker.
#
# Usage: bash-guard.test.sh [path-to-hook]   (defaults to the sibling hook)
# Exit 0 iff every case passes.
set -u

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-guard.sh}"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# Run the hook with the given command string; echo "DENY" or "ALLOW".
run_guard() {
    local cmd="$1" out
    out=$(jq -nc --arg c "$cmd" '{tool_input:{command:$c}}' | "$HOOK")
    if [[ "$out" == *'"permissionDecision":"deny"'* ]]; then echo DENY; else echo ALLOW; fi
}

# Test 1: a git command against a /var/folders/…/review-worktrees/wt-… path is
# ALLOWED — the carve-out exempts legitimate ephemeral worktrees from the
# unconditional /var/folders/ block.
t1() {
    local v
    v=$(run_guard 'git -C /var/folders/qz/abc123/T/review-worktrees/wt-9f3a1b status')
    if [ "$v" = ALLOW ]; then ok "review-worktree under /var/folders/ allowed"
    else bad "review-worktree command wrongly denied"; fi
}

# Test 2: a bare /var/folders/ write with NO worktree segment is STILL DENIED —
# the carve-out must not weaken the general temp-write policy.
t2() {
    local v
    v=$(run_guard 'touch /var/folders/qz/abc123/T/tmpfile')
    if [ "$v" = DENY ]; then ok "bare /var/folders/ write still denied"
    else bad "bare /var/folders/ write wrongly allowed"; fi
}

# Test 3: fall-through preserved — a review-worktree path carrying a compound
# operator is still denied by the syntax checks (the carve-out only skips the
# temp-write block, not the rest of the guard).
t3() {
    local v
    v=$(run_guard 'git -C /var/folders/qz/T/review-worktrees/wt-9f3a1b status && rm -rf /')
    if [ "$v" = DENY ]; then ok "review-worktree path still subject to syntax checks"
    else bad "compound operator on worktree path wrongly allowed"; fi
}

# Test 4: $TMPDIR reference (no worktree segment) still denied.
t4() {
    local v
    v=$(run_guard 'cp foo $TMPDIR/bar')
    if [ "$v" = DENY ]; then ok "\$TMPDIR write still denied"
    else bad "\$TMPDIR write wrongly allowed"; fi
}

# Test 5: a $TMPDIR path that IS a review worktree is allowed (carve-out matches
# the worktree segment regardless of the temp root spelling).
t5() {
    local v
    v=$(run_guard 'git -C /var/folders/qz/T/review-worktrees/wt-deadbeef rev-parse HEAD')
    if [ "$v" = ALLOW ]; then ok "review-worktree rev-parse allowed"
    else bad "review-worktree rev-parse wrongly denied"; fi
}

t1; t2; t3; t4; t5
echo "-----"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
