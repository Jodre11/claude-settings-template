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
    expect_verdict ALLOW "an escaped ; is a literal argument" 'find . -name x -exec rm {} \;'
    expect_verdict ALLOW "a multi-line quoted argument is one argument" $'jq \'.a\n| .b\' f.json'
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

# The deny reason of <command>, empty when the hook does not deny.
deny_reason() {
    printf '%s' "$1" | jq -Rsc '{tool_input:{command:.}}' | "$HOOK" \
        | jq -r '.hookSpecificOutput | select(.permissionDecision == "deny") | .permissionDecisionReason'
}

# A command holding a here-document that is screened as commands names the heredoc form that works.
t_messages() {
    local got hd_note="one-stage cat > <file> or tee <file> here-document with a quoted delimiter"
    got=$(deny_reason $'cat <<EOF\nfor x in a; do\necho $x\ndone\nEOF')
    if [[ "$got" == *"here-document"* && "$got" == *"$hd_note"* ]]; then
        ok "an unquoted heredoc with a loop body names the one-stage heredoc"
    else
        bad "an unquoted heredoc with a loop body names no heredoc remedy: ${got:-none}"
    fi
    got=$(deny_reason $'cat <<< x ; ls')
    if [[ -n "$got" && "$got" != *"here-document"* ]]; then
        ok "a here-string carries no heredoc note"
    else
        bad "a here-string wrongly carries the heredoc note: ${got:-none}"
    fi
    got=$(deny_reason $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" && ls')
    if [[ -n "$got" && "$got" != *"here-document"* ]]; then
        ok "a stripped commit heredoc carries no heredoc note"
    else
        bad "a stripped commit heredoc wrongly carries the heredoc note: ${got:-none}"
    fi
    got=$(deny_reason $'ls && cat <<\'EOF\' > out.txt\nx\nEOF')
    if [[ "$got" == *"here-document"* ]]; then
        ok "a heredoc after a live && carries the heredoc note"
    else
        bad "a heredoc after a live && lacks the heredoc note: ${got:-none}"
    fi
    expect_verdict ALLOW "the heredoc remedy: a one-stage cat > heredoc" $'cat > out.txt <<\'EOF\'\nfor x in y; do\nEOF'
    expect_verdict ALLOW "the heredoc remedy: a one-stage tee heredoc"   $'tee out.txt <<\'EOF\'\nbody\nEOF'
    expect_verdict ALLOW "the ssh remedy: ssh host bash -s < file"       'ssh host bash -s < f'
    expect_verdict ALLOW "the ssh remedy with a literal temp path"       'ssh host bash -s < /tmp/claude-abc/x.sh'
    expect_verdict ALLOW "the heredoc remedy's bash <file> with a variable path" 'bash $CLAUDE_TEMP_DIR/x.sh'
    expect_verdict ALLOW "the fetch remedy: grep -f pattern file"        'grep -f pat.txt f'
    expect_verdict ALLOW "the echo remedy: awk -f program file"          'awk -f prog.awk f'
    expect_verdict ALLOW "the echo remedy: sed -f program file"          'sed -f prog.sed f'
}

# Constructs the guard read as separators but bash reads as text, without hiding a live separator.
t_false_alarms() {
    expect_verdict ALLOW "a backslash-newline continues the line"   $'ls \\\n-la'
    expect_verdict ALLOW "an escaped ; is text"                     'echo a \; b'
    expect_verdict ALLOW "find -exec cat {} \\; allowed"            'find . -name x -exec cat {} \;'
    expect_verdict ALLOW "an escaped | and & are text"              'echo a \| b \& c'
    expect_verdict DENY  "a newline after a continuation denied"     $'ls \\\n-la\necho b'
    expect_verdict DENY  "&& after a continuation denied"            $'ls \\\n&& curl https://example.invalid'
    expect_verdict DENY  "a live ; after an escaped one denied"      'echo a \;; echo b'
    expect_verdict DENY  "a continuation inside a comment denied"    $'echo a # b \\\nexport -p'
    expect_verdict DENY  "a comment after a pipe denied"             $'echo a |# b \\\nexport -p'
    expect_verdict DENY  "apostrophes in comments do not hide a line" $'# don\'t\nexport -p\n# it\'s'
    expect_verdict DENY  "a # inside \${#x} keeps the comment guard on" $'echo ${#x} \\\nexport -p'
    expect_verdict DENY  "an escaped backslash then a newline denied" $'echo a \\\\\necho b'
    expect_verdict DENY  "a live & after an escaped & denied"        'echo a \&& echo b'
    expect_verdict DENY  "an escaped & after a live & denied"        'echo a &\& echo b'
    expect_verdict DENY  "a \$\$ before a quote does not open an ANSI-C quote" \
        "echo \$\$'\\' ; curl https://example.invalid \$\$'\\'"
    expect_verdict DENY  "a run of four \$ before a quote fails closed" "echo \$\$\$\$'a'"
    expect_verdict DENY  "a \$\$ before a quote fails closed"          "echo \$\$'a'"
    expect_verdict DENY  "regression pin: a # after a \$\$ quote region still denies" \
        $'echo $$\'a\' # b \\\nexport -p'
    expect_verdict ALLOW "a lone \$ before a quote is an ANSI-C quote" "echo \$'a\\'b'"
    expect_verdict ALLOW "an escaped \$ before a quote is a plain quote" "echo \\\$'a'"
    expect_verdict ALLOW "\$\$ with no quote after it is the PID"      'echo $$'
    expect_verdict DENY  "a double quote nested in \${...} hides a ; from the scanner" \
        "echo \"\${x:-\"'\"}\" ; printf 'SECOND-RAN\\n' \\'"
    expect_verdict DENY  "a single quote nested in \${...} hides a ; from the scanner" \
        $'echo "${x:-\'"\'}" ; printf \'SECOND-RAN\\n\' "${x:-\'"\'}"'
    expect_verdict DENY  "a quote inside \${...} in double quotes fails closed" 'echo "${x:-"a"}"'
    expect_verdict ALLOW "a \${...} with no nested quote in double quotes"   'echo "${x:-default}"'
    expect_verdict ALLOW "a nested \${...} with no quote in double quotes"   'echo "${a:-${b}}"'
    expect_verdict ALLOW "\${#x} and \${x/a/b} in double quotes"             'echo "${#x}" "${x/a/b}"'
    expect_verdict ALLOW "a quoted word in an unquoted \${...} is unchanged" "echo \${x:-'a b'}"
    expect_verdict ALLOW "a ' after a closed \${...} in double quotes is text" "echo \"\${x} it's\""
    expect_verdict DENY  "a } inside \$[...] in \${...} does not close the nesting" \
        $'echo "${HOME:-$[}]"\'"}" ; printf \'SECOND-RAN\\n\' \\\''
    expect_verdict DENY  "a } inside \$[...] in a nested \${...} does not close the nesting" \
        $'echo "${HOME:-${y:-$[}]}"\'"}}" ; printf \'SECOND-RAN\\n\' \\\''
    expect_verdict DENY  "zsh reads ##' after \$[ in double quotes as a character, not a quote" \
        $'echo "$["##\'"]" ; printf \'SECOND-RAN\\n\' \\\''
    expect_verdict DENY  "zsh reads ##' after \$[ as a character, not a quote" \
        $'echo $[##\'] ; printf \'SECOND-RAN\\n\' \\\''
    expect_verdict DENY  "zsh reads ##' after \$[ in \${...} as a character, not a quote" \
        $'echo ${HOME:-$[##\']} ; printf \'SECOND-RAN\\n\' \\\''
    expect_verdict DENY  "a ##' after \$\$[ is denied" \
        $'echo $$[##\'] ; printf \'SECOND-RAN\\n\' \\\''
    expect_verdict DENY  "a \$\$[ is denied like a \$[" 'echo $$[1]'
    expect_verdict DENY  "a ##\" after \$\$[ is denied (zsh rejects this shape: fail-closed pin)" \
        $'echo $$[##"] ; printf \'SECOND-RAN\\n\' "'
    expect_verdict DENY  "a ##\" in \${...} is denied (zsh rejects this shape: fail-closed pin)" \
        $'echo ${HOME:##"} ; printf \'SECOND-RAN\\n\' "'
    expect_verdict DENY  "a backtick after ## is denied by the backtick check" $'echo ##`id`'
    expect_verdict DENY  "a backtick after ## in double quotes is denied" $'echo "##`id`"'
    expect_verdict ALLOW "a ## followed by a space or a letter is text" 'echo "## title" ##a'
    expect_verdict DENY  "zsh reads ##' in \$((...)) as a character, not a quote" \
        $'echo $((##\')) ; printf \'SECOND-RAN\\n\' \\\''
    expect_verdict ALLOW "a quoted or escaped \$[ is text"   'echo '"'"'$[1]'"'"' \$[1] "\$[1]"'
    expect_verdict ALLOW "a newline in single quotes is text"       $'echo \'a\nb\''
    expect_verdict ALLOW "a newline in double quotes is text"       $'jq "\n.a" f.json'
    expect_verdict ALLOW "a newline in \$'…' is text"               $'printf $\'a\nb\''
    expect_verdict ALLOW "a backslash-newline in double quotes is text" $'echo "a\\\nb"'
    expect_verdict ALLOW "a backslash-newline in \$'…' is text"     $'printf $\'a\\\nb\''
    expect_verdict DENY  "an unquoted newline after a quoted one denied" $'echo \'a\nb\'\necho c'
    expect_verdict DENY  "an unquoted newline after a multi-line double-quoted word denied" $'echo "a\nb"\necho c'
    expect_verdict DENY  "a quote opened in a comment does not hide a line" $'echo # \'\nexport -p\n\''
    expect_verdict DENY  "a double quote opened in a comment does not hide a line" $'echo # "\nexport -p\n"'
    expect_verdict DENY  "an ANSI-C quote opened in a comment does not hide a line" $'echo # $\'\nexport -p\n\''
    expect_verdict DENY  "a multi-line quoted word then a live ; denied" $'echo \'a\nb\' ; echo c'
    expect_verdict DENY  "a multi-line quoted word then a substitution denied" $'echo "a\nb $(id)"'
    expect_verdict ALLOW "a quoted /var/folders/ pattern is text"       "grep -c '/var/folders/' f"
    expect_verdict ALLOW "rg of a quoted /var/folders/ pattern allowed" "rg '/var/folders/' f"
    expect_verdict ALLOW "a /tmp/ string in a jq filter allowed"        "jq '.tmp = \"/tmp/x\"' f"
    expect_verdict DENY  "a jq redirect into /tmp/ denied"              'jq . f > /tmp/out'
    expect_verdict DENY  "a jq unquoted /tmp/ operand denied"           'jq . /tmp/x'
    expect_verdict DENY  "a jq double-quoted /tmp/ operand denied"      "jq '.a' \"/tmp/x\""
    expect_verdict DENY  "a jq redirect after a quoted /tmp/ filter denied" "jq '.t = \"/tmp/x\"' f > /tmp/out"
    expect_verdict ALLOW "a jq read of a session temp file allowed"     'jq . /tmp/claude-x/f'
    expect_verdict DENY  "a jq redirect into a quoted /tmp/ path denied" "jq . f > '/tmp/out'"
    expect_verdict DENY  "find on a quoted /var/folders/ path denied"   "find '/var/folders/x' -delete"
    expect_verdict DENY  "a redirect into a quoted /var/folders/ path denied" "cat f > '/var/folders/x'"
    expect_verdict DENY  "find -fprint to a quoted /var/folders/ path denied" "find . -fprint '/var/folders/x'"
    expect_verdict DENY  "grep with a redirect to a quoted /var/folders/ path denied" "grep x f > '/var/folders/y'"
    expect_verdict DENY  "grep with an append to a quoted /var/folders/ path denied" "grep x f >> '/var/folders/y'"
    expect_verdict DENY  "cat of a quoted /var/folders/ path denied"    "cat '/var/folders/x'"
    expect_verdict DENY  "grep piped into tee of a quoted /var/folders/ path denied" "grep x f | tee '/var/folders/x'"
    expect_verdict DENY  "jq piped into tee of a quoted /tmp/ path denied" "jq . f | tee '/tmp/x'"
    expect_verdict DENY  "jq piped into tee -a of a quoted /var/folders/ path denied" \
        "jq . f | tee -a '/var/folders/x'"
    expect_verdict DENY  "grep piped into awk writing to /var/folders/ denied" \
        "grep x f | awk '{print > \"/var/folders/x\"}'"
    expect_verdict DENY  "grep piped into dd of= a quoted /var/folders/ path denied" \
        "grep x f | dd of='/var/folders/x'"
    expect_verdict DENY  "rg --pre running a quoted program denied"     "rg --pre 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg --pre= running a quoted program denied"    "rg --pre='tee /var/folders/o' x f"
    expect_verdict DENY  "rg --pre split by quotes denied"              "rg -'-p're 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg --pre spelt in an ANSI-C quote denied"     "rg \$'\\x2d\\x2dpre' 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg --hostname-bin running a quoted program denied" \
        "rg --hostname-bin 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg with an expansion in its options denied"   "rg \$OPT '/var/folders/' f"
    expect_verdict DENY  "rg --pre behind a brace expansion denied"     "rg --{pre,x} 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg --pre in double quotes denied"             "rg \"--pre\" 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg --pr (a prefix of --pre) denied"           "rg --pr 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg with a single-quoted --pre denied"         "rg '--pre' 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg with a single-quoted --pre=value denied"   "rg '--pre=tee /var/folders/o' x f"
    expect_verdict DENY  "rg with a single-quoted --hostname-bin denied" "rg '--hostname-bin' 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg --pre-glob denied"                        "rg --pre-glob=x '/var/folders/' f"
    expect_verdict DENY  "rg --host (a prefix of --hostname-bin) denied" "rg --host 'tee /var/folders/o' x f"
    expect_verdict DENY  "rg --pre split by a backslash-newline denied" \
        $'rg --p\\\nre \'tee /var/folders/o\' x f'
    expect_verdict DENY  "rg with a double-quoted \$ in a word denied"  "rg \"-\$x\" '/var/folders/' f"
    expect_verdict DENY  "rg with a glob word denied"                   "rg '/var/folders/' *.txt"
    expect_verdict DENY  "rg with a word glued to a quote denied"       "rg '/var/folders/'x f"
    expect_verdict ALLOW "rg with short, valued and path words allowed" \
        "rg -n --max-count=3 --glob '*.txt' '/var/folders/' src/f.txt"
    expect_verdict ALLOW "rg with other long options and a quoted pattern allowed" \
        "rg --hidden --no-ignore '/var/folders/' f"
    expect_verdict DENY  "touch of a quoted /var/folders/ path denied"  "touch '/var/folders/x'"
    expect_verdict DENY  "a read of an unquoted /var/folders/ path denied" 'cat /var/folders/x'
    expect_verdict DENY  "a double-quoted /var/folders/ stays denied"   'grep -c "/var/folders/" f'
    expect_verdict DENY  "\$TMPDIR stays denied in a reader"            'grep x "$TMPDIR/f"'
    expect_verdict DENY  "echo into /tmp/ denied"                       'echo x > /tmp/f'
    expect_verdict DENY  "git clone into /tmp/ denied"                  'git clone u /tmp/x'
    expect_verdict DENY  "a quoted pattern then an unquoted /var/folders/ path denied" \
        "grep '/var/folders/' /var/folders/x"
    expect_verdict DENY  "a quoted pattern then a redirect into /var/folders/ denied" \
        "grep '/var/folders/' f > /var/folders/o"
    expect_verdict DENY  "a quoted pattern with an ANSI-C quote after a \$\$ fails closed" \
        "grep '/var/folders/' \$\$'x' f"
    # A quoted-delimiter cat or tee heredoc that writes a file has an inert body.
    local th_head=$'cat > out.txt <<\'EOF\'\n' th_body
    expect_verdict ALLOW "a single-quoted cat > heredoc writes a file" \
        $'cat > out.txt <<\'EOF\'\n#!/usr/bin/env python3\nfor x in y; do\nEOF'
    expect_verdict ALLOW "a double-quoted cat >> heredoc writes a file"  $'cat >> out.txt <<"EOF"\nline $(id)\nEOF'
    expect_verdict ALLOW "a backslash-quoted cat > heredoc writes a file" $'cat > out.txt <<\\EOF\n`a`\nEOF'
    expect_verdict ALLOW "a <<- cat > heredoc with a tab-indented closer"  $'cat > out.txt <<-\'EOF\'\n\tbody\n\tEOF'
    expect_verdict ALLOW "a cat <<'EOF' > file heredoc with a final newline" $'cat <<\'EOF\' > out.txt\nbody\nEOF\n'
    expect_verdict ALLOW "a tee heredoc writes a file"                     $'tee out.txt <<\'EOF\'\nbody\nEOF'
    expect_verdict ALLOW "a tee -a heredoc writes two files"               $'tee -a a.txt b.txt <<\'EOF\'\nbody\nEOF'
    expect_verdict DENY  "an unquoted-delimiter cat heredoc denied"        $'cat > out.txt <<EOF\n$(id)\nEOF'
    expect_verdict DENY  "an interpreter heredoc denied"                   $'python3 - <<\'EOF\'\nprint(1)\nEOF'
    expect_verdict DENY  "a cat heredoc piped to a shell denied"           $'cat <<\'EOF\' | sh\necho hi\nEOF'
    expect_verdict DENY  "a command after the closing line denied" \
        $'cat > out.txt <<\'EOF\'\nbody\nEOF\ncat .env'
    expect_verdict DENY  "a closing line with a trailing blank denied" \
        $'cat > out.txt <<\'EOF\'\nbody\nEOF \necho x'
    expect_verdict DENY  "a cat heredoc with a file operand denied"        $'cat notes.txt > out.txt <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a cat heredoc with an fd redirection denied"     $'cat 2>err.txt <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a kubectl apply heredoc denied"                  $'kubectl apply -f - <<\'EOF\'\nkind: x\nEOF'
    expect_verdict DENY  "a cat heredoc into /var/folders/ denied"         $'cat > /var/folders/x <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a cat heredoc into /tmp/ denied"                 $'cat > /tmp/x <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a cat heredoc to a quoted target holding a newline denied" \
        $'cat > \'a\nb\' <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a heredoc token after a bare redirection operator denied" $'cat > <<\'EOF\' a\nx\nEOF'
    expect_verdict ALLOW "a cat > \$CLAUDE_TEMP_DIR heredoc writes a file" \
        $'cat > $CLAUDE_TEMP_DIR/x.py <<\'EOF\'\nx\nEOF'
    expect_verdict ALLOW "a cat > \${CLAUDE_TEMP_DIR} heredoc writes a file" \
        $'cat >> ${CLAUDE_TEMP_DIR}/x.py <<\'EOF\'\nx\nEOF'
    expect_verdict ALLOW "a cat > \"\$CLAUDE_TEMP_DIR\" heredoc writes a file" \
        $'cat > "$CLAUDE_TEMP_DIR"/x.py <<\'EOF\'\nx\nEOF'
    expect_verdict ALLOW "a tee \"\$CLAUDE_TEMP_DIR\" heredoc writes a file" \
        $'tee -a "$CLAUDE_TEMP_DIR"/x.py <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a CLAUDE_TEMP_DIR heredoc target with a .. segment denied" \
        $'cat > $CLAUDE_TEMP_DIR/../x <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a CLAUDE_TEMP_DIR heredoc target with an expansion denied" \
        $'cat > $CLAUDE_TEMP_DIR/${X} <<\'EOF\'\nx\nEOF'
    expect_verdict DENY  "a CLAUDE_TEMP_DIR assignment before a heredoc denied" \
        $'CLAUDE_TEMP_DIR=/tmp cat > $CLAUDE_TEMP_DIR/x <<\'EOF\'\nx\nEOF'
    th_body=$(printf 'x%.0s' $(seq 1 $(( 32768 - ${#th_head} - 4 ))))
    expect_verdict ALLOW "a cat > heredoc at the size bound writes a file" "${th_head}${th_body}"$'\nEOF'
    expect_verdict DENY  "a cat > heredoc one character over the size bound denied" "${th_head}${th_body}x"$'\nEOF'
}

# A heredoc write whose first line holds many words is screened whole, and in time under any bash: the count of its
# CLAUDE_TEMP_DIR words was superlinear under bash 3.2 in a UTF-8 locale.
t_text_heredoc_token_bound() {
    local cmd b start out
    cmd="tee $(printf '$CLAUDE_TEMP_DIR/a %.0s' $(seq 1 60)) <<'EOF'"$'\nx\nEOF'
    expect_verdict ALLOW "a tee heredoc of 60 targets writes a file" "$cmd"
    cmd="tee $(printf '$CLAUDE_TEMP_DIR/a %.0s' $(seq 1 800)) <<'EOF'"$'\nx\nEOF'
    expect_verdict DENY  "a tee heredoc of 800 targets is screened whole and denied" "$cmd"
    for b in "$BASH" /bin/bash; do
        [[ -x "$b" ]] || continue
        start=$SECONDS
        out=$(printf '%s' "$cmd" | jq -Rsc '{tool_input:{command:.}}' | LC_ALL=C.UTF-8 "$b" "$HOOK")
        if (( SECONDS - start < 3 )) && [[ "$out" == *'"permissionDecision":"deny"'* ]]; then
            ok "a tee heredoc of 800 targets is denied within 3 s under $b"
        else
            bad "a tee heredoc of 800 targets took $((SECONDS - start)) s under $b, or was not denied"
        fi
    done
}

t1; t2; t3; t4; t5; t6; t7; t8; t9; t10; t11; t12; t13; t14; t15
t_heredoc; t_scanner; t_paren_messages; t_backstop; t_scan_fails_closed; t_scan_size_bound; t_heredoc_size_bound
t_text_heredoc_token_bound
t_false_alarms
t_messages
echo "-----"
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
