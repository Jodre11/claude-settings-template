#!/usr/bin/env bash
# Hermetic unit tests for session-topic-provisional.sh.
#
# Fakes `tmux` and `jq` (for show-options) on PATH so nothing touches the real
# tmux server. Tests run synchronously (the hook is synchronous, no backgrounding).
#
# Usage: session-topic-provisional.test.sh [path-to-hook]
# Exit 0 iff every case passes.
set -u

HOOK="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session-topic-provisional.sh}"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# Write a fake tmux. $1=dir, $2=session name, $3=existing @topic ("" = unset),
# $4=existing @topic_provisional ("" = unset).
# Records set-option writes to $dir/setopt as "KEY VALUE" lines.
# shellcheck disable=SC2016
make_tmux() {
    local dir="$1" sname="$2" topicval="$3" provval="${4:-}"
    {
        echo '#!/usr/bin/env bash'
        echo "if [ \"\$1\" = display-message ]; then echo \"$sname\"; fi"
        echo 'if [ "$1" = show-options ]; then'
        echo "  if [[ \"\$*\" == *@topic_provisional* ]]; then printf '%s' \"$provval\""
        echo "  elif [[ \"\$*\" == *@topic* ]]; then printf '%s' \"$topicval\""
        echo '  fi'
        echo 'fi'
        echo 'if [ "$1" = set-option ]; then'
        echo "  echo \"\${4} \${5}\" >> \"$dir/setopt\""
        echo 'fi'
    } > "$dir/tmux"
    chmod +x "$dir/tmux"
}

# Test 1: happy path — slug, no @topic, prompt with stopwords → heuristic set +
# @topic_provisional flag set.
t1() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t1.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    printf '{"session_id":"s1","transcript_path":"/x","cwd":"/a/b","prompt":"Can you please help me fix the broken auth token refresh"}' \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    local rc=$?
    if [ -f "$d/setopt" ]; then
        local got; got=$(cat "$d/setopt")
        local expected
        expected=$(printf '@topic fix broken auth token\n@topic_provisional 1')
        if [ "$got" = "$expected" ] && [ "$rc" -eq 0 ]; then ok "happy path: heuristic + flag, exit 0 (got: '$got')"
        elif [ "$rc" -ne 0 ]; then bad "happy path: non-zero exit ($rc)"
        else bad "happy path wrong output: '$got' (expected: '$expected')"; fi
    else bad "happy path: nothing written"; fi
    rm -rf "$d"
}

# Test 2: recursion guard — CLAUDE_TOPIC_GUESS set → exit immediately.
t2() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t2.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    printf '{"prompt":"hello"}' | CLAUDE_TOPIC_GUESS=1 TMUX=fake PATH="$d:$PATH" "$HOOK"
    if [ -f "$d/setopt" ]; then bad "recursion sentinel should exit"
    else ok "recursion sentinel → exit"; fi
    rm -rf "$d"
}

# Test 3: subagent — agent_type present → exit.
t3() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t3.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    printf '{"prompt":"hello","agent_type":"Explore"}' | TMUX=fake PATH="$d:$PATH" "$HOOK"
    if [ -f "$d/setopt" ]; then bad "subagent should skip"
    else ok "subagent → skipped"; fi
    rm -rf "$d"
}

# Test 4: not in tmux → skip.
t4() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t4.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    printf '{"prompt":"hello"}' | env -u TMUX PATH="$d:$PATH" "$HOOK"
    if [ -f "$d/setopt" ]; then bad "no-tmux should skip"
    else ok "no TMUX → skipped"; fi
    rm -rf "$d"
}

# Test 5: non-slug session name → skip.
t5() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t5.XXXX")
    make_tmux "$d" "my cool session" "" ""
    printf '{"prompt":"hello"}' | TMUX=fake PATH="$d:$PATH" "$HOOK"
    if [ -f "$d/setopt" ]; then bad "non-slug should skip"
    else ok "non-slug name → skipped"; fi
    rm -rf "$d"
}

# Test 6: @topic already set → skip.
t6() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t6.XXXX")
    make_tmux "$d" "c-cf-3a9f" "existing topic" ""
    printf '{"prompt":"hello"}' | TMUX=fake PATH="$d:$PATH" "$HOOK"
    if [ -f "$d/setopt" ]; then bad "@topic non-empty should skip"
    else ok "@topic already set → skipped"; fi
    rm -rf "$d"
}

# Test 7: all-stopword prompt → empty heuristic → write nothing.
t7() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t7.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    printf '{"prompt":"can you please help me"}' | TMUX=fake PATH="$d:$PATH" "$HOOK"
    local rc=$?
    if [ -f "$d/setopt" ]; then bad "all-stopword prompt should write nothing"
    elif [ "$rc" -ne 0 ]; then bad "all-stopword: non-zero exit ($rc)"
    else ok "empty heuristic → nothing written, exit 0"; fi
    rm -rf "$d"
}

# Test 8: prompt with special characters → normalised to lowercase alpha/digits/space.
t8() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t8.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    printf '{"prompt":"Fix the API-Gateway 500 errors in production!"}' | TMUX=fake PATH="$d:$PATH" "$HOOK"
    if [ -f "$d/setopt" ]; then
        local got; got=$(head -1 "$d/setopt")
        if [ "$got" = "@topic fix apigateway 500 errors" ]; then ok "normalisation strips punctuation (got: '$got')"
        else bad "normalisation wrong: '$got'"; fi
    else bad "normalisation: nothing written"; fi
    rm -rf "$d"
}

# Test 9: only takes first ~4 significant words.
t9() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t9.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    printf '{"prompt":"refactor database connection pooling timeout retry backoff logic"}' | TMUX=fake PATH="$d:$PATH" "$HOOK"
    if [ -f "$d/setopt" ]; then
        local got; got=$(head -1 "$d/setopt")
        # 4 words max
        local wc; wc=$(echo "$got" | sed 's/@topic //' | wc -w | tr -d ' ')
        if [ "$wc" -le 4 ]; then ok "word cap respected (got: '$got', words: $wc)"
        else bad "too many words: '$got' ($wc words)"; fi
    else bad "word-cap: nothing written"; fi
    rm -rf "$d"
}

# Write a fake gh. $1=dir, $2=title to emit for `gh pr view <n> --json title --jq .title`.
# Records that it ran (and the PR number) to $dir/gh-called.
make_gh() {
    local dir="$1" title="$2"
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"\$@\" >> \"$dir/gh-called\""
        echo "if [ \"\$1\" = pr ] && [ \"\$2\" = view ]; then printf '%s\\n' \"$title\"; fi"
    } > "$dir/gh"
    chmod +x "$dir/gh"
}

# Test 10: /review-gh-pr <n> → background gh fetch → @topic from PR title (no heuristic).
t10() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t10.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    make_gh "$d" "Add retry backoff to ingest worker"
    printf '{"session_id":"s10","transcript_path":"/x","cwd":"/a/b","prompt":"/review-gh-pr 4321"}' \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 2
    if [ ! -f "$d/gh-called" ]; then bad "/review-gh-pr: gh never called"; rm -rf "$d"; return; fi
    if [ -f "$d/setopt" ]; then
        local got; got=$(head -1 "$d/setopt")
        if printf '%s' "$got" | grep -qE '^@topic add retry backoff to ingest$'; then ok "/review-gh-pr → PR-title topic (got: '$got')"
        else bad "/review-gh-pr wrong topic: '$got'"; fi
    else bad "/review-gh-pr: @topic never set"; fi
    rm -rf "$d"
}

# Test 11: /review-gh-pr with a PR URL → number parsed from /pull/<n>.
t11() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t11.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    make_gh "$d" "Fix flaky timeout"
    printf '{"session_id":"s11","transcript_path":"/x","cwd":"/a/b","prompt":"/review-gh-pr https://github.com/o/r/pull/99"}' \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 2
    if grep -q ' 99 ' "$d/gh-called" 2>/dev/null || grep -qE '(^| )99( |$)' "$d/gh-called" 2>/dev/null; then ok "/review-gh-pr URL → PR number 99 parsed"
    else bad "/review-gh-pr URL: wrong/no PR number (gh-called: $(cat "$d/gh-called" 2>/dev/null))"; fi
    rm -rf "$d"
}

# Test 12: a non-PR slash command (/rehydrate) → no heuristic, no gh, nothing written.
t12() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t12.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    make_gh "$d" "should not run"
    printf '{"session_id":"s12","transcript_path":"/x","cwd":"/a/b","prompt":"/rehydrate"}' \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/setopt" ]; then bad "/rehydrate should not set a heuristic topic: $(cat "$d/setopt")"
    elif [ -f "$d/gh-called" ]; then bad "/rehydrate should not call gh"
    else ok "/rehydrate → nothing written (command sets its own topic)"; fi
    rm -rf "$d"
}

# Test 13: PR command with no PR arg → skip (no gh, nothing written).
t13() {
    local d; d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/prov-t13.XXXX")
    make_tmux "$d" "c-cf-3a9f" "" ""
    make_gh "$d" "should not run"
    printf '{"session_id":"s13","transcript_path":"/x","cwd":"/a/b","prompt":"/shakedown"}' \
        | TMUX=fake PATH="$d:$PATH" "$HOOK"
    sleep 1
    if [ -f "$d/gh-called" ]; then bad "/shakedown with no PR should not call gh"
    elif [ -f "$d/setopt" ]; then bad "/shakedown with no PR should write nothing"
    else ok "/shakedown no-arg → skipped"; fi
    rm -rf "$d"
}

t1; t2; t3; t4; t5; t6; t7; t8; t9; t10; t11; t12; t13
echo "-----"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
