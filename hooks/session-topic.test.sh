#!/usr/bin/env bash
# Hermetic unit tests for session-topic.sh.
#
# Fakes `tmux` and `claude` on PATH so nothing touches the real CLI, the real
# tmux server, or the network. The fake tmux reports a chosen session name +
# @topic and records set-option writes; the fake claude records whether it ran.
#
# Usage: session-topic.test.sh [path-to-hook]   (defaults to the sibling hook)
# Exit 0 iff every case passes.
set -u

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session-topic.sh}"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# Build a multi-line transcript >32 KiB so `head -c 32768` cuts the final JSON
# line mid-object — the real-world case behind the pipefail-abort bug. The first
# real prompt follows two harness tag-wrapper lines (which must be skipped). Any
# extra args are appended verbatim as trailing JSONL (e.g. custom-title records),
# so a test can simulate /rename and session-init slug writes.
make_transcript() {
    local t="$1"; shift
    : > "$t"
    # shellcheck disable=SC2129
    printf '%s\n' '{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}' >> "$t"
    printf '%s\n' '{"type":"user","message":{"content":"</local-command-caveat>"}}' >> "$t"
    printf '%s\n' '{"type":"user","message":{"content":"Please help me fix the broken auth token refresh in the login flow"}}' >> "$t"
    local filler; filler=$(printf 'word%.0s ' $(seq 1 100))
    local i=0
    while [ "$i" -lt 120 ]; do
        printf '{"type":"user","message":{"content":"%s"}}\n' "$filler" >> "$t"
        i=$((i + 1))
    done
    local extra
    for extra in "$@"; do printf '%s\n' "$extra" >> "$t"; done
}

# Emit a custom-title JSONL record for the given title.
ctitle() { printf '{"type":"custom-title","customTitle":"%s","sessionId":"x"}' "$1"; }

# Write a fake tmux. $1=dir, $2=session name to report, $3=existing @topic ("" =
# unset). Records set-option writes to $dir/setopt as "TOPIC <value>".
# The single-quoted echo lines below are LITERAL shell written into the fake's
# body — they are meant not to expand here.
# shellcheck disable=SC2016
make_tmux() {
    local dir="$1" sname="$2" topicval="$3"
    {
        echo '#!/usr/bin/env bash'
        echo "if [ \"\$1\" = display-message ]; then echo \"$sname\"; fi"
        # show-options -t <s> -qv @topic → emit the existing topic (may be empty).
        # @topic_provisional is always unset for t1-t9 (none exercise it) — answer
        # that query with nothing, matching real tmux for an unset option.
        echo 'if [ "$1" = show-options ]; then'
        echo "  if [[ \"\$*\" == *@topic_provisional* ]]; then :"
        echo "  elif [[ \"\$*\" == *@topic* ]]; then printf '%s' \"$topicval\""
        echo '  fi'
        echo 'fi'
        # set-option -t <s> @topic <value> → record (arg 5 is the value). The
        # @topic_provisional flag clear (`set-option -u ... @topic_provisional`)
        # is not a topic write — skip it so these tests assert on @topic alone.
        echo 'if [ "$1" = set-option ]; then'
        echo "  if [[ \"\$*\" != *@topic_provisional* ]]; then echo \"TOPIC \${5}\" >> \"$dir/setopt\"; fi"
        echo 'fi'
    } > "$dir/tmux"
    chmod +x "$dir/tmux"
}

# Write a fake claude. $1=dir, remaining args = stdout lines. Drains stdin (so
# the upstream printf does not SIGPIPE) and records that it ran.
make_claude() {
    local dir="$1"; shift
    {
        echo '#!/usr/bin/env bash'
        echo 'cat > /dev/null'
        echo "echo CLAUDE_CALLED >> \"$dir/called\""
        local line
        for line in "$@"; do printf 'echo %q\n' "$line"; done
    } > "$dir/claude"
    chmod +x "$dir/claude"
}

# Test 1: happy path — slug name, no existing @topic → @topic set + normalised.
# Claude emits a messy multi-line label to prove normalisation and the head -1
# pipe-close survives pipefail.
t1() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t1.XXXX")
    make_tmux "$d" "c-cf-3a9f" ""
    make_claude "$d" "Fix Auth Bug!" "second line ignored"
    make_transcript "$d/transcript.jsonl"
    printf '{"session_id":"s1","transcript_path":"%s","cwd":"/Users/me/Repos/claude-fleet"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 2
    if [ -f "$d/setopt" ]; then
        local got; got=$(cat "$d/setopt")
        if [ "$got" = "TOPIC fix auth bug" ]; then ok "happy path sets normalised @topic (got: '$got')"
        else bad "happy path @topic wrong: '$got'"; fi
    else bad "happy path: @topic never set (subshell aborted?)"; fi
    rm -rf "$d"
}

# Test 2: non-slug (manually renamed) session name → no @topic, no claude.
t2() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t2.XXXX")
    make_tmux "$d" "fix auth bug" ""
    make_claude "$d" "whatever"
    make_transcript "$d/transcript.jsonl"
    printf '{"session_id":"s2","transcript_path":"%s","cwd":"/x/y"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/setopt" ] || [ -f "$d/called" ]; then bad "non-slug name should skip"
    else ok "non-slug name skipped — no @topic, no claude"; fi
    rm -rf "$d"
}

# Test 3: recursion guard — CLAUDE_TOPIC_GUESS set → immediate exit before tmux.
t3() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t3.XXXX")
    make_tmux "$d" "c-cf-3a9f" ""
    printf '{}' | CLAUDE_TOPIC_GUESS=1 TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/setopt" ]; then bad "sentinel should exit before any work"
    else ok "recursion sentinel forced immediate exit"; fi
    rm -rf "$d"
}

# Test 4: subagent turn — agent_type present → no work.
t4() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t4.XXXX")
    make_tmux "$d" "c-cf-3a9f" ""
    printf '{"agent_type":"Explore","session_id":"s4","transcript_path":"/x","cwd":"/y"}' \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/setopt" ]; then bad "subagent turn should skip"; else ok "subagent turn skipped"; fi
    rm -rf "$d"
}

# Test 5: idempotency — @topic already set, no real rename → skip, no re-set.
t5() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t5.XXXX")
    make_tmux "$d" "c-cf-3a9f" "original topic"
    make_claude "$d" "new guess"
    make_transcript "$d/transcript.jsonl"
    printf '{"session_id":"s5","transcript_path":"%s","cwd":"/a/b"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/called" ]; then bad "idempotency: claude called despite existing @topic"
    elif [ -f "$d/setopt" ]; then bad "idempotency: @topic re-set despite existing"
    else ok "existing @topic → skipped, no re-set, no claude"; fi
    rm -rf "$d"
}

# Test 6: not in tmux — $TMUX unset → skip.
t6() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t6.XXXX")
    make_tmux "$d" "c-cf-3a9f" ""
    make_claude "$d" "x"
    make_transcript "$d/transcript.jsonl"
    printf '{"session_id":"s6","transcript_path":"%s","cwd":"/a/b"}' "$d/transcript.jsonl" \
        | env -u TMUX PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/setopt" ] || [ -f "$d/called" ]; then bad "no-tmux should skip"
    else ok "not in tmux → skipped"; fi
    rm -rf "$d"
}

# Test 7: manual /rename mirrors into @topic over an existing guess, no claude.
t7() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t7.XXXX")
    make_tmux "$d" "c-cf-3a9f" "fix auth bug"
    make_claude "$d" "should not run"
    make_transcript "$d/transcript.jsonl" "$(ctitle c-cf-3a9f)" "$(ctitle carrots)"
    printf '{"session_id":"s7","transcript_path":"%s","cwd":"/a/b"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/called" ]; then bad "rename-sync should not call claude"
    elif [ ! -f "$d/setopt" ]; then bad "rename-sync: @topic not updated"
    else
        local got; got=$(cat "$d/setopt")
        if [ "$got" = "TOPIC carrots" ]; then ok "manual /rename mirrored into @topic (got: '$got')"
        else bad "rename-sync wrong value: '$got'"; fi
    fi
    rm -rf "$d"
}

# Test 8: slug-only custom-titles ignored — a resume's sessionTitle=<slug> writes
# must NOT be treated as a rename (else resume clobbers the user's name).
t8() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t8.XXXX")
    make_tmux "$d" "c-cf-3a9f" "fix auth bug"
    make_claude "$d" "should not run"
    make_transcript "$d/transcript.jsonl" "$(ctitle c-cf-3a9f)" "$(ctitle c-cf-3a9f)"
    printf '{"session_id":"s8","transcript_path":"%s","cwd":"/a/b"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/setopt" ]; then bad "slug custom-title wrongly treated as rename: $(cat "$d/setopt")"
    elif [ -f "$d/called" ]; then bad "slug-only: claude wrongly called"
    else ok "slug-only custom-title ignored — @topic untouched, no claude"; fi
    rm -rf "$d"
}

# Test 9: rename equal to existing @topic → no redundant re-set, no claude.
t9() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t9.XXXX")
    make_tmux "$d" "c-cf-3a9f" "carrots"
    make_claude "$d" "should not run"
    make_transcript "$d/transcript.jsonl" "$(ctitle carrots)"
    printf '{"session_id":"s9","transcript_path":"%s","cwd":"/a/b"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/setopt" ]; then bad "redundant re-set when rename == @topic: $(cat "$d/setopt")"
    elif [ -f "$d/called" ]; then bad "claude wrongly called"
    else ok "rename equal to @topic → no re-set, no claude"; fi
    rm -rf "$d"
}

# Test 10: @topic set BUT @topic_provisional=1 → Stop falls through, writes
# Haiku guess, clears the flag.
t10() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t10.XXXX")
    # The fake tmux must report @topic="fix broken auth token" and
    # @topic_provisional="1" from show-options.
    {
        echo '#!/usr/bin/env bash'
        echo "if [ \"\$1\" = display-message ]; then echo \"c-cf-3a9f\"; fi"
        echo 'if [ "$1" = show-options ]; then'
        echo "  if [[ \"\$*\" == *@topic_provisional* ]]; then printf '1'"
        echo "  elif [[ \"\$*\" == *@topic* ]]; then printf 'fix broken auth token'"
        echo '  fi'
        echo 'fi'
        echo 'if [ "$1" = set-option ]; then'
        echo "  echo \"\$3 \$4 \$5\" >> \"$d/setopt\""
        echo 'fi'
    } > "$d/tmux"
    chmod +x "$d/tmux"
    make_claude "$d" "Refactor Auth Flow"
    make_transcript "$d/transcript.jsonl"
    printf '{"session_id":"s10","transcript_path":"%s","cwd":"/Users/me/Repos/claude-fleet"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 2
    if [ ! -f "$d/setopt" ]; then bad "provisional @topic should fall through to Haiku guess"; return; fi
    local got; got=$(cat "$d/setopt")
    # Expect: @topic set to the normalised Haiku guess + flag unset (-u)
    if echo "$got" | grep -q '@topic refactor auth flow' && echo "$got" | grep -q '@topic_provisional'; then
        ok "provisional @topic upgraded + flag cleared"
    else bad "provisional upgrade wrong: '$got'"; fi
    rm -rf "$d"
}

# Test 11: manual /rename with provisional flag → mirror rename + clear flag.
t11() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/st-t11.XXXX")
    {
        echo '#!/usr/bin/env bash'
        echo "if [ \"\$1\" = display-message ]; then echo \"c-cf-3a9f\"; fi"
        echo 'if [ "$1" = show-options ]; then'
        echo "  if [[ \"\$*\" == *@topic_provisional* ]]; then printf '1'"
        echo "  elif [[ \"\$*\" == *@topic* ]]; then printf 'fix broken auth token'"
        echo '  fi'
        echo 'fi'
        echo 'if [ "$1" = set-option ]; then'
        echo "  echo \"\$1 \$2 \$3 \$4 \$5\" >> \"$d/setopt\""
        echo 'fi'
    } > "$d/tmux"
    chmod +x "$d/tmux"
    make_claude "$d" "should not run"
    make_transcript "$d/transcript.jsonl" "$(ctitle c-cf-3a9f)" "$(ctitle "my auth work")"
    printf '{"session_id":"s11","transcript_path":"%s","cwd":"/a/b"}' "$d/transcript.jsonl" \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/called" ]; then bad "rename+provisional: claude should not run"; return; fi
    if [ ! -f "$d/setopt" ]; then bad "rename+provisional: nothing written"; return; fi
    local got; got=$(cat "$d/setopt")
    if echo "$got" | grep -q 'my auth work' && echo "$got" | grep -q '@topic_provisional'; then
        ok "manual rename mirrored + provisional flag cleared"
    else bad "rename+provisional wrong: '$got'"; fi
    rm -rf "$d"
}

t1; t2; t3; t4; t5; t6; t7; t8; t9; t10; t11
echo "-----"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
