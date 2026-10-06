#!/usr/bin/env bash
# Tests for hooks/_lib.sh: the shell_words tokeniser and its plain-word classifier, the crash backstop, the git walk
# and shell_scan's P flag. This suite holds no secret-shaped values, so it may run through the Bash tool.
#
# Usage: _lib.test.sh   Exit 0 iff every case passes.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/_lib.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

# words <cmd> [<names> <fragments>]: print shell_words' elements as [e1][e2]..., or NOT-OK when SW_OK is 0.
words() {
    local e out=""
    shell_words "$@"
    if (( ! SW_OK )); then
        printf 'NOT-OK'
        return 0
    fi
    for e in ${SW_WORDS[@]+"${SW_WORDS[@]}"}; do
        out+="[$e]"
    done
    printf '%s' "$out"
}

# expect_words <description> <cmd> <want> [<names> <fragments>]
expect_words() {
    local got
    got=$(words "$2" "${@:4}")
    if [[ "$got" == "$3" ]]; then ok "$1"; else bad "$1: want $3 got $got"; fi
}

# Quoting and escapes.
expect_words "plain words"                     'cat a b'                    '[wcat][wa][wb]'
expect_words "single quotes are literal"       "echo 'a \$b \\c'"           '[wecho][wa $b \c]'
expect_words "double quotes keep \$ text"      'echo "a $b"'                '[wecho][wa $b]'
expect_words "double-quote escapes"            'echo "x\$y\"z\\w\q"'        '[wecho][wx$y"z\w\q]'
expect_words "adjacent quotes join one word"   'c""at a'"'b'"               '[wcat][wab]'
expect_words "an unquoted backslash escapes"   '\cat x\ y'                  '[wcat][wx y]'
expect_words "a backslash-newline is removed"  $'ca\\\nt x'                 '[wcat][wx]'
expect_words "\$'…' keeps its content undecoded" "echo \$'a\\'b' c"         "[wecho][wa\\'b][wc]"
expect_words "\$\"…\" is read as \"…\""        'echo $"a b"'                '[wecho][wa b]'
expect_words "an escaped quote opens nothing"  "echo \\' | cat 'a|b' x"     "[wecho][w'][|][wcat][wa|b][wx]"
expect_words "an empty quoted word is a word"  "echo ''"                    '[wecho][w]'
expect_words "# is an ordinary word"           'echo a#b # c'               '[wecho][wa#b][w#][wc]'
expect_words "a quoted newline stays in a word" $'echo \'a\nb\''            $'[wecho][wa\nb]'
expect_words "an unterminated quote ends the word" "echo 'a b"              '[wecho][wa b]'
expect_words "globs, braces and parameters stay as written" 'ls *.md {a,b} ~/x $HOME' \
    '[wls][w*.md][w{a,b}][w~/x][w$HOME]'
expect_words "a commit heredoc is one inert word" $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)"' \
    $'[wgit][wcommit][w-m][w$(cat <<\'EOF\'\nmsg\nEOF\n)]'

# Redirections: the operator as written, fd prefix included, then one space and the target.
expect_words "input and output redirections"   '<a cat >b 2>>c'             '[r< a][wcat][r> b][r2>> c]'
expect_words "every operator form"             'x 10<f 1>>g &>h &>>i >|j <>k <<<"t x" <<EOF' \
    '[wx][r10< f][r1>> g][r&> h][r&>> i][r>| j][r<> k][r<<< t x][r<< EOF]'
expect_words "a heredoc dash form"             'cat <<-EOF'                 '[wcat][r<<- EOF]'
expect_words "fd duplications"                 'x 2>&1 >&2 <&3 1>&-'        '[wx][r2>& 1][r>& 2][r<& 3][r1>& -]'
expect_words "a quoted digit is no fd prefix"  "x '2'>f"                    '[wx][w2][r> f]'
expect_words "ten digits are no fd prefix"     'x 1234567890>f'             '[wx][w1234567890][r> f]'
expect_words "a word before > is no fd prefix" 'x a2>f'                     '[wx][wa2][r> f]'
expect_words "a dangling redirection"          'x >'                        '[wx][r> ]'
expect_words "a quoted target"                 'x > "$D/a b"'               '[wx][r> $D/a b]'

# Stages and separators.
expect_words "pipes and |&"                    'a|b|&c'                     '[wa][|][wb][|][wc]'
expect_words "every other separator is ;"      'a&&b||c;d&e'                '[wa][;][wb][;][wc][;][wd][;][we]'
expect_words "a newline separates"             $'a\nb'                      '[wa][;][wb]'
expect_words "parentheses separate"            '(a)'                        '[;][wa][;]'
expect_words "process substitution separates"  'diff <(a) >(b)'             '[wdiff][;][wa][;][;][wb][;]'

# Failure: \x1e or \x1f, the size bound, or awk failing.
expect_words "a \\x1f in the command is refused" $'a\x1fb'                  'NOT-OK'
expect_words "a \\x1e in the command is refused" $'a\x1eb'                  'NOT-OK'
long=$(printf 'a%.0s' $(seq 1 "$(( SHELL_SCAN_MAX_CHARS + 1 ))"))
expect_words "a command over the bound is refused" "$long"                  'NOT-OK'
expect_words "a command at the bound is tokenised" "${long:1}"              "[w${long:1}]"
bin=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/lib-test.XXXXXX")
ln -s "$(command -v printf)" "$bin/printf" 2>/dev/null || true
got=$(PATH="$bin" words 'cat x' 2>/dev/null)
rm -rf "$bin"
[[ "$got" == NOT-OK ]] && ok "an awk failure sets SW_OK=0" || bad "an awk failure was not refused: $got"

# The classifier: with names and fragments, plain words become p; anything a guard keys on stays w.
NAMES='cat env ! --debug'
FRAG='[.]env|/secrets'
expect_words "plain words are marked p"        'ls a b'                     '[pls][pa][pb]' "$NAMES" "$FRAG"
expect_words "a listed name stays w"           'cat a'                      '[wcat][pa]' "$NAMES" "$FRAG"
expect_words "a listed name's path stays w"    '/bin/cat a'                 '[w/bin/cat][pa]' "$NAMES" "$FRAG"
expect_words "! stays w"                       '! a'                        '[w!][pa]' "$NAMES" "$FRAG"
expect_words "a listed long option stays w"    'x --debug'                  '[px][w--debug]' "$NAMES" "$FRAG"
expect_words "a fragment match stays w"        'x .env.x a/secrets'         '[px][w.env.x][wa/secrets]' "$NAMES" "$FRAG"
expect_words "a bare fragment name stays w"    'x secrets'                  '[px][wsecrets]' "$NAMES" "$FRAG"
expect_words "\$ = : * ? [ stay w"             'x $a b=c d:e f* g? h['      '[px][w$a][wb=c][wd:e][wf*][wg?][wh[]' \
    "$NAMES" "$FRAG"
expect_words "single-dash options stay w"      'x -g -rn --long'            '[px][w-g][w-rn][p--long]' "$NAMES" "$FRAG"
expect_words "an empty word stays w"           "x ''"                       '[px][w]' "$NAMES" "$FRAG"
w257=$(printf 'a%.0s' $(seq 1 257))
expect_words "a word over 256 characters stays w" "x $w257"                 "[px][w$w257]" "$NAMES" "$FRAG"
expect_words "without names nothing is p"      'ls a'                       '[wls][wa]'

# Portability: every awk on PATH (BSD awk on macOS, mawk or gawk on Linux) gives the same elements, and so does the
# substr loop an awk takes when it cannot split a string into characters.
probe=$'FOO=1 cat <.env 2>&1 "a b"\'c\'$\'d\\\'e\' x\\ y | grep -E "a|b" >>out; ls *.md'
want=$(words "$probe" "$NAMES" "$FRAG")
for a in awk gawk mawk nawk; do
    p=$(command -v "$a") || continue
    d=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/lib-awk.XXXXXX")
    ln -s "$p" "$d/awk"
    got=$(PATH="$d:$PATH" words "$probe" "$NAMES" "$FRAG")
    rm -rf "$d"
    [[ "$got" == "$want" ]] && ok "$a tokenises as the reference does" || bad "$a differs: $got"
done
forced="${_SHELL_WORDS_AWK/'split(s, ch, "") != n'/1}"
if [[ "$forced" != "$_SHELL_WORDS_AWK" ]]; then
    a=$(printf '%s' "$probe" | LC_ALL=C awk -v q="'" -v names="$NAMES" -v frag="$FRAG" "$_SHELL_WORDS_AWK")
    b=$(printf '%s' "$probe" | LC_ALL=C awk -v q="'" -v names="$NAMES" -v frag="$FRAG" "$forced")
    [[ "$a" == "$b" ]] && ok "the substr fallback tokenises as split does" || bad "the substr fallback differs"
else
    bad "the split test was not found in the tokeniser, so the fallback was not exercised"
fi

# The backstop: a crash that skips the ERR trap (an empty array under set -u on bash 3.2, an unset variable in a
# function) or an exit that never settles still emits the fail-safe decision and exits 0; a decision or hook_pass
# suppresses it.
fixture=$(mktemp "${CLAUDE_TEMP_DIR:-/tmp}/lib-backstop.XXXXXX")
cat > "$fixture" <<'FIXTURE'
set -uo pipefail
source "$1"
hook_backstop deny "fixture crashed"
trap 'hook_ask "err trap"' ERR
case "$2" in
    empty-array) a=(); for x in "${a[@]}"; do :; done ;;
    unset-in-function) f() { printf '%s' "$unset_in_function"; }; f ;;
    unsettled) : ;;
    deny) hook_deny "denied" ;;
    pass) hook_pass ;;
esac
FIXTURE
for b in "$BASH" /bin/bash; do
    [[ -x "$b" ]] || continue
    modes="unset-in-function unsettled"
    # bash 4.4 and later expand an empty array under set -u; only bash 3 crashes on it.
    if [[ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"')" == 3 ]]; then
        modes+=" empty-array"
    fi
    for mode in $modes; do
        out=$("$b" "$fixture" "$DIR/_lib.sh" "$mode" 2>/dev/null)
        rc=$?
        if [[ $rc -eq 0 && "$(jq -r '.hookSpecificOutput.permissionDecision + ":" +
                .hookSpecificOutput.permissionDecisionReason' <<< "$out" 2>/dev/null)" == "deny:fixture crashed" ]]
        then
            ok "the backstop denies ($mode) under $b"
        else
            bad "the backstop missed ($mode) under $b (rc=$rc out=$out)"
        fi
    done
    out=$("$b" "$fixture" "$DIR/_lib.sh" deny 2>/dev/null)
    if [[ "$(jq -sc 'map(.hookSpecificOutput.permissionDecisionReason)' <<< "$out")" == '["denied"]' ]]; then
        ok "a decision under $b is printed once, with no backstop after it"
    else
        bad "a decision under $b printed: $out"
    fi
    out=$("$b" "$fixture" "$DIR/_lib.sh" pass 2>/dev/null)
    [[ -z "$out" ]] && ok "hook_pass under $b prints nothing" || bad "hook_pass under $b printed: $out"
done
rm -f "$fixture"

# The git walk skips global options, and their arguments, to the subcommand.
walk() {  # walk <word>...: print the subcommand the walk finds, or ACTIVE if none
    git_walk_start
    local w
    for w in "$@"; do
        if (( GW_ACTIVE )); then git_walk_word "$w"; fi
    done
    if (( GW_ACTIVE )); then printf 'ACTIVE'; else printf '%s' "$GW_SUB"; fi
}
[[ "$(walk -C /r -c a=b --git-dir /g --no-pager commit -m x)" == commit ]] && ok "the git walk skips global options" \
    || bad "the git walk did not find commit"
[[ "$(walk --git-dir=/g --work-tree=/w push)" == push ]] && ok "the git walk skips =forms" || bad "=forms walk"
[[ "$(walk --config-env x.y=HOME --attr-source HEAD commit -m x)" == commit ]] \
    && ok "the git walk skips --config-env and --attr-source values" \
    || bad "the git walk took a --config-env or --attr-source value for the subcommand"
[[ "$(walk -C)" == ACTIVE ]] && ok "the git walk stays active with no subcommand" || bad "an empty walk ended"
git_sub_mutating commit && ok "commit is mutating" || bad "commit not mutating"
git_sub_mutating worktree && ok "worktree is mutating in every form" || bad "worktree not mutating"
if git_sub_mutating status; then bad "status counted as mutating"; else ok "status is not mutating"; fi
git_sub_reader show && ok "show is a reader" || bad "show not a reader"
if git_sub_reader commit; then bad "commit counted as a reader"; else ok "commit is not a reader"; fi

# shell_scan's P flag: an unquoted, unescaped ( not after $, < or >.
flags() { shell_scan "$1"; printf '%s' "$SHELL_SCAN_FLAGS"; }
[[ "$(flags '(cat x)')" == *P* ]] && ok "P flags a subshell" || bad "P missed a subshell"
[[ "$(flags 'ls *(.)')" == *P* ]] && ok "P flags a zsh glob qualifier" || bad "P missed a glob qualifier"
[[ "$(flags 'find . \( -name a \)')" != *P* ]] && ok "P ignores an escaped (" || bad "P flagged an escaped ("
[[ "$(flags "echo '(x)' \"(y)\"")" != *P* ]] && ok "P ignores a quoted (" || bad "P flagged a quoted ("
[[ "$(flags 'echo $(x) <(y) >(z)')" != *P* ]] && ok "P leaves \$( <( >( to their own checks" || bad "P flagged \$("

# strip_commit_heredoc: the documented commit heredoc is replaced by -m ''; a prefix holding anything but plain
# command-word characters (a quote, #, ;, |, &, $ or a backtick) before the marker is left alone, as its span may not
# be an inert heredoc.
hd=$'-m "$(cat <<\'EOF\'\nmsg\nEOF\n)"'
[[ "$(strip_commit_heredoc "git commit $hd")" == "git commit -m ''" ]] \
    && ok "the documented commit heredoc is stripped" || bad "the documented commit heredoc was not stripped"
[[ "$(strip_commit_heredoc "git -C /repo commit --amend $hd")" == "git -C /repo commit --amend -m ''" ]] \
    && ok "a commit heredoc behind git -C and --amend is stripped" || bad "git -C ... --amend was not stripped"
for p in "git commit 'x " 'git commit "x ' 'git commit # ' 'git commit ; ' 'git commit | ' 'git commit & ' \
        'git commit $x ' 'git commit `x` '; do
    c="$p$hd"
    if [[ "$(strip_commit_heredoc "$c")" == "$c" ]]; then
        ok "a prefix '$p' is not stripped"
    else
        bad "a prefix '$p' was stripped"
    fi
done
[[ "$(strip_commit_heredoc "git -C ~/repo commit $hd")" == "git -C ~/repo commit -m ''" ]] \
    && ok "a commit heredoc behind git -C ~/repo is stripped" || bad "git -C ~/repo was not stripped"
# The body must also be inert under bash 3.2, which matches parentheses instead of reading the heredoc: the depth never
# drops below zero. A body that ends with an open quote (an apostrophe, an inch mark) or an unclosed ( is a parse error
# there, which runs nothing, so it still strips when nothing follows the closer; with text after it, it is left whole.
for body in 'fix (a) and (b)' 'nested ((x) y)' 'say "a ) b" and (ok)' \
        "it's a fix" 'a 12" pipe' 'open ( never closed'; do
    c=$'git commit -m "$(cat <<\'EOF\'\n'"$body"$'\nEOF\n)"'
    if [[ "$(strip_commit_heredoc "$c")" == "git commit -m ''" ]]; then
        ok "a message '$body' is stripped"
    else
        bad "a message '$body' was not stripped"
    fi
done
for body in "it's a fix" 'a 12" pipe' 'open ( never closed'; do
    c=$'git commit -m "$(cat <<\'EOF\'\n'"$body"$'\nEOF\n)" | true'
    if [[ "$(strip_commit_heredoc "$c")" == "$c" ]]; then
        ok "an open message '$body' with text after the closer is left whole"
    else
        bad "an open message '$body' with text after the closer was stripped"
    fi
done
for body in 'fix ) early' 'a 1) list marker' 'run `date` now' "price \$'5' now"; do
    c=$'git commit -m "$(cat <<\'EOF\'\n'"$body"$'\nEOF\n)"'
    if [[ "$(strip_commit_heredoc "$c")" == "$c" ]]; then
        ok "a message '$body' is left whole"
    else
        bad "a message '$body' was stripped"
    fi
done

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
