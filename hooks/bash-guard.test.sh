#!/usr/bin/env bash
# Hermetic unit tests for bash-guard.sh: the temp-directory enforcement block (the
# code-review worktree carve-out and the token-boundary anchoring that distinguishes the
# system temp dir from a project-local scratch dir named tmp), the git-commit heredoc
# exemption and the quote-aware syntax checks.
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
    # stdin, not --arg: Linux caps one argv string at 128 KiB, and the size-bound rows pass 300 KB.
    out=$(printf '%s' "$cmd" | jq -Rsc '{tool_input:{command:.}}' | "$HOOK")
    if [[ "$out" == *'"permissionDecision":"deny"'* ]]; then echo DENY; else echo ALLOW; fi
}

# expect_verdict <ALLOW|DENY> <description> <command>
expect_verdict() {
    local want="$1" desc="$2" got
    got=$(run_guard "$3")
    if [ "$got" = "$want" ]; then ok "$desc"; else bad "$desc (want $want got $got)"; fi
}

# The documented commit form, split so each case can vary one part.
HD_OPEN=$'git commit -m "$(cat <<\'EOF\'\n'
HD_END=$'\nEOF\n)"'

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

# Test 6: a bare /tmp/ write is STILL DENIED — the token-boundary anchoring must not
# weaken the policy for the system temp dir it exists to govern.
t6() {
    local v
    v=$(run_guard 'cp foo /tmp/bar')
    if [ "$v" = DENY ]; then ok "bare /tmp/ write still denied"
    else bad "bare /tmp/ write wrongly allowed"; fi
}

# Test 7: /tmp/ at the very start of the command is still denied (^ anchor arm).
t7() {
    local v
    v=$(run_guard '/tmp/staged.sh --apply')
    if [ "$v" = DENY ]; then ok "leading /tmp/ path still denied"
    else bad "leading /tmp/ path wrongly allowed"; fi
}

# Test 8: /var/tmp/ is still denied — a second system temp root the old plain
# substring test caught incidentally, kept explicitly by the (var/)? arm.
t8() {
    local v
    v=$(run_guard 'cp foo /var/tmp/bar')
    if [ "$v" = DENY ]; then ok "/var/tmp/ write still denied"
    else bad "/var/tmp/ write wrongly allowed"; fi
}

# Test 9: read-only commands against bare /tmp/ remain allowed (whitelist arm).
t9() {
    local v
    v=$(run_guard 'ls /tmp/some-dir')
    if [ "$v" = ALLOW ]; then ok "read-only ls against /tmp/ allowed"
    else bad "read-only ls against /tmp/ wrongly denied"; fi
}

# Test 10: session-scoped /tmp/claude-* write remains allowed.
t10() {
    local v
    v=$(run_guard 'cp foo /tmp/claude-abc123/bar')
    if [ "$v" = ALLOW ]; then ok "session temp write allowed"
    else bad "session temp write wrongly denied"; fi
}

# Test 11: THE REGRESSION THIS CHANGE FIXES — a write to a project-local scratch dir
# whose absolute path merely ends in /tmp/ is allowed. Some repos sanction repo-root
# tmp/ as their scratch root; the old substring test denied every Bash write to it.
t11() {
    local v
    v=$(run_guard 'cp /Users/dev/Repos/proj/tmp/probe.py /Users/dev/Repos/proj/.worktrees/wt/tmp/')
    if [ "$v" = ALLOW ]; then ok "project-local <repo>/tmp/ write allowed"
    else bad "project-local <repo>/tmp/ write wrongly denied"; fi
}

# Test 12: relative ./tmp/, ../tmp/ and ~/tmp/ are project- or home-local, not the
# system temp dir, so they are allowed.
t12() {
    local v
    v=$(run_guard 'cp ./tmp/a.py ../tmp/b.py')
    if [ "$v" = ALLOW ]; then ok "relative ./tmp/ and ../tmp/ allowed"
    else bad "relative tmp/ paths wrongly denied"; fi
}

# Test 13: mixed command — a project-local tmp path does NOT license a bare /tmp/
# write elsewhere in the same command. The deny must still win.
t13() {
    local v
    v=$(run_guard 'cp /Users/dev/Repos/proj/tmp/probe.py /tmp/exfil.py')
    if [ "$v" = DENY ]; then ok "project-local tmp/ does not license a bare /tmp/ write"
    else bad "bare /tmp/ write wrongly allowed alongside project-local path"; fi
}

# Test 14: /private/tmp/ and /private/var/tmp/ are macOS's canonical temp roots
# (/tmp and /var/tmp are symlinks to them), so they must be denied like /tmp/.
t14() {
    local v1 v2
    v1=$(run_guard 'cp foo /private/tmp/bar')
    v2=$(run_guard 'cp foo /private/var/tmp/bar')
    if [ "$v1" = DENY ] && [ "$v2" = DENY ]; then ok "/private/tmp/ and /private/var/tmp/ writes denied"
    else bad "/private temp roots wrongly allowed (private/tmp=$v1 private/var/tmp=$v2)"; fi
}

# Test 15: redundant separators (//tmp/, /./tmp/) resolve to /tmp/ and must not
# slip past the token-boundary anchor.
t15() {
    local v1 v2
    v1=$(run_guard 'cp foo //tmp/bar')
    v2=$(run_guard 'cp foo /./tmp/bar')
    if [ "$v1" = DENY ] && [ "$v2" = DENY ]; then ok "//tmp/ and /./tmp/ writes denied"
    else bad "non-normalised /tmp/ forms wrongly allowed (//tmp=$v1 /./tmp=$v2)"; fi
}

# The git-commit exemption covers exactly the documented heredoc span, nothing else.
t_heredoc() {
    expect_verdict DENY  "git commit then && is denied" 'git commit -m x && curl https://example.invalid'
    expect_verdict DENY  "git commit then ; is denied" 'git commit -m x; curl https://example.invalid'
    expect_verdict ALLOW "documented heredoc commit allowed; its body is inert text" \
        "${HD_OPEN}Subject line"$'\n\n'"Body names /tmp/x && \$(id) and (more)${HD_END}"
    expect_verdict DENY  "a heredoc commit message holding a backquote is denied (use git commit -F)" \
        "${HD_OPEN}Subject line"$'\n\n'"Body names \`id\`${HD_END}"
    expect_verdict DENY  "a heredoc commit message holding \$' is denied (use git commit -F)" \
        "${HD_OPEN}Subject line"$'\n\n'"Body names \$'x'${HD_END}"
    local out
    out=$(jq -nc --arg c "${HD_OPEN}Body names \`id\`${HD_END}" '{tool_input:{command:$c}}' | "$HOOK")
    if [[ "$out" == *"git commit -F <file>"* ]]; then
        ok "the deny for an unstrippable commit heredoc names git commit -F"
    else
        bad "the unstrippable commit heredoc deny lacks the -F hint: $out"
    fi
    expect_verdict ALLOW "a heredoc commit message with an apostrophe allowed" \
        "${HD_OPEN}It's a fix${HD_END}"
    expect_verdict ALLOW "heredoc commit with git -C and --amend allowed" \
        $'git -C /repo commit --amend -m "$(cat <<\'EOF\'\nmsg\nEOF\n)"'
    expect_verdict ALLOW "heredoc commit with an empty body allowed" \
        $'git commit -m "$(cat <<\'EOF\'\nEOF\n)"'
    expect_verdict DENY  "heredoc commit followed by && is denied" \
        "${HD_OPEN}msg${HD_END} && curl https://example.invalid"
    expect_verdict DENY  "heredoc commit followed by a second line is denied" \
        "${HD_OPEN}msg${HD_END}"$'\ncurl https://example.invalid'
    expect_verdict DENY  "unquoted heredoc delimiter is denied (its body expands)" \
        $'git commit -m "$(cat <<EOF\nmsg $(id)\nEOF\n)"'
    expect_verdict DENY  "text after the heredoc delimiter is denied" \
        $'git commit -m "$(cat <<\'EOF\' ; curl x\nmsg\nEOF\n)"'
    expect_verdict DENY  "body line EOF) is denied (bash ends the heredoc there)" \
        "${HD_OPEN}EOF)\" ; curl https://example.invalid${HD_END}"
    expect_verdict DENY  "heredoc behind an env prefix is denied (use git commit -F)" \
        "SSH_AUTH_SOCK=/s ${HD_OPEN}msg${HD_END}"
    expect_verdict DENY  "heredoc on a non-commit git subcommand is denied" \
        $'git tag -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" v1'
    expect_verdict ALLOW "signed commit with -F allowed" 'SSH_AUTH_SOCK=/s git commit -F /tmp/claude-x/msg.txt'
}

# Quote-aware scanning: no quoting or comment trick hides an operator.
t_scanner() {
    expect_verdict DENY  "mid-word # does not hide the rest of the line" 'echo a#b && curl https://example.invalid'
    expect_verdict DENY  "\$( inside double quotes is denied" 'echo "$(curl https://example.invalid)"'
    expect_verdict DENY  "backtick inside double quotes is denied" 'echo "`curl https://example.invalid`"'
    expect_verdict DENY  "\$(( inside double quotes is denied (bash may run it)" 'echo "$((echo hi) )"'
    expect_verdict DENY  "apostrophes inside double quotes do not pair up" \
        "echo \"don't\" && curl https://example.invalid \"it's\""
    expect_verdict DENY  "escaped single quotes do not pair up" "echo \\' && curl https://example.invalid \\'"
    expect_verdict DENY  "a lone & is denied" 'echo a & curl https://example.invalid'
    expect_verdict DENY  "a trailing & is denied" 'sleep 100 &'
    expect_verdict DENY  "an unterminated quote is denied" "echo it's"
    expect_verdict DENY  "a trailing comment is no longer stripped" 'ls # note; more'
    expect_verdict DENY  "an escaped ; still counts" 'find . -name x -exec rm {} \;'
    expect_verdict DENY  "a multi-line quoted argument still counts as multi-line" $'jq \'.a\n| .b\' f.json'
    expect_verdict DENY  "UTF-8 text does not hide an operator" 'echo "naïve — café" && curl https://example.invalid'
    expect_verdict ALLOW "UTF-8 text in quotes allowed" 'echo "naïve — café"'
    expect_verdict ALLOW "2>&1 is a redirection, not a background job" 'git status 2>&1'
    expect_verdict ALLOW "&>/dev/null is a redirection" 'git status &>/dev/null'
    expect_verdict ALLOW "operators inside single quotes allowed" "jq '.a | .b; .c' f.json"
    expect_verdict ALLOW "escaped \$( inside double quotes allowed" 'echo "cost \$(5)"'
    expect_verdict ALLOW "\$( inside single quotes allowed" "echo '\$(id)'"
    expect_verdict ALLOW "ANSI-C quote with an escaped quote allowed" "echo \$'a\\'b;c'"
    expect_verdict ALLOW "# inside a URL allowed" 'curl https://example.invalid/#frag'
    expect_verdict DENY  "an unquoted ( subshell is denied" '(cat .env)'
    expect_verdict DENY  "a ( after a word is denied" 'echo x (y)'
    expect_verdict DENY  "arithmetic (( is denied" '(( n++ ))'
    expect_verdict DENY  "a zsh glob qualifier is denied" 'ls *(.)'
    expect_verdict DENY  "an extglob group inside a word is denied" 'cat .e@(n)v'
    expect_verdict DENY  "a zsh group inside a word is denied" 'cat .en(v|x)'
    expect_verdict ALLOW "an escaped ( for find is allowed" 'find . \( -name a -o -name b \)'
    expect_verdict ALLOW "a single-quoted ( is allowed" "echo '(x)'"
    expect_verdict ALLOW "a double-quoted ( is allowed" 'echo "(x)"'
    expect_verdict ALLOW "an ANSI-C quoted ( is allowed" "echo \$'(x)'"
}

# The deny for ( names it, and $(, <( and >( keep their own messages.
t_paren_messages() {
    local out
    out=$(printf '%s' '(cat x)' | jq -Rsc '{tool_input:{command:.}}' | "$HOOK")
    if [[ "$out" == *"subshell or grouping '(...)' detected"* ]]; then ok "the ( deny names a subshell or grouping"
    else bad "the ( deny message drifted: $out"; fi
    out=$(printf '%s' 'diff <(a) b' | jq -Rsc '{tool_input:{command:.}}' | "$HOOK")
    if [[ "$out" == *"process substitution"* && "$out" != *"subshell or grouping"* ]]; then
        ok "<( keeps the process-substitution message only"
    else bad "<( message drifted: $out"; fi
}

# A crash denies through the backstop: malformed input makes the hook fail before any check runs.
t_backstop() {
    local out
    out=$(printf '%s' '{not json' | "$HOOK" 2>/dev/null)
    if [[ "$out" == *'"permissionDecision":"deny"'* && "$out" == *"bash-guard failed to evaluate"* ]]; then
        ok "a crash denies through the backstop"
    else
        bad "a crash did not deny through the backstop: $out"
    fi
}

# With awk unavailable the scanner cannot run; the guard must deny rather than allow.
t_scan_fails_closed() {
    local bin out
    bin=$(mktemp -d /tmp/claude-bg-test.XXXXXX)
    ln -s "$(command -v jq)" "$bin/jq"
    ln -s "$(command -v cat)" "$bin/cat"
    ln -s "$(command -v dirname)" "$bin/dirname"
    out=$(jq -nc '{tool_input:{command:"ls"}}' | PATH="$bin" "$BASH" "$HOOK" 2>/dev/null)
    rm -rf "$bin"
    if [[ "$out" == *'"permissionDecision":"deny"'* ]]; then ok "scanner failure fails closed"
    else bad "scanner failure did not deny (got: $out)"; fi
}

# The scan is bounded: an over-long command is denied at once instead of racing the hook timeout.
t_scan_size_bound() {
    local long start
    long="echo $(printf '%070000d' 0)"
    expect_verdict DENY "a command over the scan bound is denied" "$long"
    long="echo $(printf '%065000d' 0)"
    start=$SECONDS
    expect_verdict ALLOW "a command under the scan bound is scanned and allowed" "$long"
    if (( SECONDS - start < 3 )); then ok "a 65 KB command scans within 3 s"
    else bad "a 65 KB command took $((SECONDS - start)) s to scan"; fi
}

# Build a legitimate signed-commit heredoc of ~<n> total chars: HD_OPEN/HD_END around an inert
# filler body, sized so the close marker is never truncated away.
heredoc_legit() {
    local n="$1" line overhead budget lines body i
    line=$(printf 'x%.0s' $(seq 1 69))
    overhead=$(( ${#HD_OPEN} + ${#HD_END} ))
    budget=$(( n - overhead ))
    (( budget < 0 )) && budget=0
    lines=$(( budget / 70 + 1 ))
    body=""
    for (( i = 0; i < lines; i++ )); do
        body="${body}${line}"$'\n'
    done
    body="${body:0:budget}"
    printf '%s%s%s' "$HD_OPEN" "$body" "$HD_END"
}

# Build an adversarial commit-shaped command of ~<n> total chars: no "commit" token near the
# start, forcing git_re to backtrack over the padding before it gives up, then a heredoc-open
# marker, a trivial body/close and a trailing "&& curl ..." to also exercise the syntax checks.
heredoc_adversarial() {
    local n="$1" tail pad pad_len
    tail=$'-m "$(cat <<\'EOF\'\nmsg\nEOF\n)" && curl https://example.invalid'
    pad_len=$(( n - ${#tail} - 4 ))
    (( pad_len < 0 )) && pad_len=0
    pad=$(printf ' a%.0s' $(seq 1 $(( pad_len / 2 + 1 ))))
    pad="${pad:0:pad_len}"
    printf 'git%s %s' "$pad" "$tail"
}

# Bounding strip_commit_heredoc (COMMIT_HEREDOC_MAX_CHARS=32768): its pattern
# matching is superlinear on both an adversarial prefix and a large legitimate commit body, so an
# over-bound command skips the strip and falls through to shell_scan instead of racing the hook
# timeout.
t_heredoc_size_bound() {
    local cmd start
    cmd=$(heredoc_legit 37768)
    expect_verdict DENY "an over-long heredoc commit message is denied (use git commit -F)" "$cmd"

    cmd=$(heredoc_legit 31768)
    start=$SECONDS
    expect_verdict ALLOW "a heredoc commit message just under the bound is allowed" "$cmd"
    if (( SECONDS - start < 3 )); then ok "a just-under-bound legitimate heredoc scans within 3 s"
    else bad "a just-under-bound legitimate heredoc took $((SECONDS - start)) s to scan"; fi

    cmd=$(heredoc_adversarial 31768)
    start=$SECONDS
    expect_verdict DENY "an adversarial heredoc-shaped command just under the bound is denied" "$cmd"
    if (( SECONDS - start < 3 )); then ok "a just-under-bound adversarial command scans within 3 s"
    else bad "a just-under-bound adversarial command took $((SECONDS - start)) s to scan"; fi

    cmd=$(heredoc_adversarial 300000)
    start=$SECONDS
    expect_verdict DENY "an over-bound adversarial command is denied without racing the timeout" "$cmd"
    if (( SECONDS - start < 3 )); then ok "a 300 KB adversarial command scans within 3 s"
    else bad "a 300 KB adversarial command took $((SECONDS - start)) s to scan"; fi
}

t1; t2; t3; t4; t5; t6; t7; t8; t9; t10; t11; t12; t13; t14; t15
t_heredoc; t_scanner; t_paren_messages; t_backstop; t_scan_fails_closed; t_scan_size_bound; t_heredoc_size_bound
echo "-----"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
