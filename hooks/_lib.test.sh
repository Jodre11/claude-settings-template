#!/usr/bin/env bash
# Tests for hooks/_lib.sh: the shell_words tokeniser and its plain-word classifier, the crash backstop, the hook
# deadline, the git walk and shell_scan's P flag. This suite holds no secret-shaped values, so it may run through the Bash tool.
#
# Usage: _lib.test.sh   Exit 0 iff every case passes.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
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
expect_words "single quotes are literal"       "echo 'a \$b \\c'"           '[wecho][md][wa $b \c]'
expect_words "double quotes keep \$ text"      'echo "a $b"'                '[wecho][wa $b]'
expect_words "double-quote escapes"            'echo "x\$y\"z\\w\q"'        '[wecho][md][wx$y"z\w\q]'
expect_words "adjacent quotes join one word"   'c""at a'"'b'"               '[wcat][wab]'
expect_words "an unquoted backslash escapes"   '\cat x\ y'                  '[wcat][wx y]'
expect_words "a backslash-newline is removed"  $'ca\\\nt x'                 '[wcat][wx]'
expect_words "\$'…' keeps its content undecoded" "echo \$'a\\'b' c"         "[wecho][ma][wa\\'b][wc]"
expect_words "a \$'…' without a backslash is not marked" "echo \$'ab' c"     '[wecho][wab][wc]'
expect_words "a backslash in \$'…' marks a, after the other marks" "echo \$'a\\n'\$X" '[wecho][ma][wa\n$X]'
expect_words "a backslash in \"…\" or '…' is not marked a" "echo 'a\\n' \"b\\\\n\"" '[wecho][wa\n][wb\n]'
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
expect_words "a quoted glob is marked"           "cat '*.md'"        '[wcat][mg][w*.md]'
expect_words "an escaped glob is marked"         'cat \*'            '[wcat][mg][w*]'
expect_words "a double-quoted glob is marked"    'cat "a?"'          '[wcat][mg][wa?]'
expect_words "a quoted brace is marked"          "echo '{a,b}'"      '[wecho][mg][w{a,b}]'
expect_words "a single-quoted \$ is marked"      "echo '\$X'"        '[wecho][md][w$X]'
expect_words "an escaped \$ is marked"           'echo \$X'          '[wecho][md][w$X]'
expect_words "an escaped \$ in \"…\" is marked"  'echo "\$X"'        '[wecho][md][w$X]'
expect_words "a live \$ in \"…\" is not marked"  'echo "$X"'         '[wecho][w$X]'
expect_words "a \$ closing the double quotes is a literal, marked"  'echo "a$"'         '[wecho][md][wa$]'
expect_words "a lone \$ in double quotes is a literal, marked"   'echo "$"'           '[wecho][md][w$]'
expect_words "a \$ before the closing \$ in \"…\" is live"        'echo "$$"'          '[wecho][mq][w$$]'
expect_words "a quoted and a live \$ are marked q"               "echo '\$'\$X"       '[wecho][mq][w$$X]'
expect_words "a closing-quote \$ and a live \$ are marked q"     'echo "$"$X'         '[wecho][mq][w$$X]'
expect_words "a glob quoted and a \$ quoted and live: g, q"      "echo '*\$'\$X"      '[wecho][mgq][w*$$X]'
expect_words "both marks, glob first"          "echo '*\$X'"       '[wecho][mgd][w*$X]'
expect_words "a live glob voids g only"          "echo '\$X'*"       '[wecho][md][w$X*]'
expect_words "a live \$ voids d only"            "echo '*'\$X"       '[wecho][mg][w*$X]'
expect_words "a redirection target is not marked" "x > '*.txt'"      '[wx][r> *.txt]'
expect_words "a long word is not marked"         "x '${w257}*'"      "[wx][w${w257}*]"
expect_words "a long word holding a quoted brace is marked" "x '${w257}{a,b}'" "[wx][mg][w${w257}{a,b}]"
expect_words "a long word holding a live brace is not marked" "x ${w257}{a,b}" "[wx][w${w257}{a,b}]"
expect_words "a backslash in a long \$'…' word still marks a" "x \$'${w257}\\n'" "[wx][ma][w${w257}\\n]"
expect_words "a long word holding a live brace and a quoted one is marked x" "x '{a,b}'${w257}{c,d}" \
    "[wx][mx][w{a,b}${w257}{c,d}]"
expect_words "quoted text before the live braces leaves no x"    'x "a b"{c,d}'      '[wx][wa b{c,d}]'
expect_words "a quoted variable before the live braces leaves no x" 'x "$f"{,.bak}'  '[wx][w$f{,.bak}]'
expect_words "a quoted braced name before the live braces leaves no x" 'x "${f}"{a,b}' '[wx][w${f}{a,b}]'
expect_words "quoted text after the live braces leaves no x"     'x {a,b}"c d"'      '[wx][w{a,b}c d]'
expect_words "quoted text between the live braces is marked x"   'x {a,"b c"}'       '[wx][mx][w{a,b c}]'
expect_words "a quoted brace beside a live one is marked x"      'x "{"{a,b}'        '[wx][mx][w{{a,b}]'
expect_words "an escaped brace beside a live one is marked x"    'x \{a,b}{c,d}'     '[wx][mx][w{a,b}{c,d}]'
expect_words "a quoted brace in a parameter expansion of the name is marked x" 'x "${f:-{}"{a,b}' \
    '[wx][mx][w${f:-{}{a,b}]'
expect_words "x follows the other marks"                         "x '\$'\$X\"{\"{a,b}" '[wx][mqx][w$$X{{a,b}]'
expect_words "a long word holding a live brace and a quoted \$ is marked d" "x ${w257}{a,b}'\$'" \
    "[wx][md][w${w257}{a,b}\$]"
expect_words "a long word keeps its text over the chunk bound" "x '{'$(printf 'b%.0s' $(seq 1 1300))'}'" \
    "[wx][mg][w{$(printf 'b%.0s' $(seq 1 1300))}]"
expect_words "a marked word is never p"          "x '{a}'"           '[px][mg][w{a}]' "$NAMES" "$FRAG"
expect_words "a versioned listed name stays w" 'cat2 a'                     '[wcat2][pa]' "$NAMES" "$FRAG"
expect_words "a dotted version stays w"         'cat3.12 a'                  '[wcat3.12][pa]' "$NAMES" "$FRAG"
expect_words "a versioned path in upper case stays w" '/bin/CAT3 a'          '[w/bin/CAT3][pa]' "$NAMES" "$FRAG"
expect_words "an unlisted versioned name is p"  'ls2 a'                      '[pls2][pa]' "$NAMES" "$FRAG"
expect_words "letters after a version are no version" 'cat2x a'              '[pcat2x][pa]' "$NAMES" "$FRAG"

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
    held-pass) hook_hold_deny "held"; hook_hold_deny "second"; hook_pass ;;
    held-deny) hook_hold_deny "held"; hook_deny "denied" ;;
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
    out=$("$b" "$fixture" "$DIR/_lib.sh" held-pass 2>/dev/null)
    if [[ "$(jq -sc 'map(.hookSpecificOutput.permissionDecision + ":" + .hookSpecificOutput.permissionDecisionReason)' \
            <<< "$out")" == "[\"deny:held$HELD_DENY_NOTE\"]" ]]; then
        ok "a held deny is emitted once by hook_pass under $b, with its first reason and the retry route"
    else
        bad "a held deny under $b printed: $out"
    fi
    out=$("$b" "$fixture" "$DIR/_lib.sh" held-deny 2>/dev/null)
    if [[ "$(jq -sc 'map(.hookSpecificOutput.permissionDecisionReason)' <<< "$out")" == '["denied"]' ]]; then
        ok "a deny after a held deny is the one reported under $b"
    else
        bad "a deny after a held deny under $b printed: $out"
    fi
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
for s in init clone bisect read-tree checkout-index maintenance bundle reflog stage; do
    git_sub_mutating "$s" && ok "$s is mutating" || bad "$s not mutating"
done
for s in pack-refs commit-graph multi-pack-index rerere mktree mktag unpack-objects update-server-info merge-file \
        prune-packed index-pack; do
    git_sub_mutating "$s" && ok "$s is mutating" || bad "$s not mutating"
done
if git_sub_mutating remote; then bad "remote counted as mutating"; else ok "remote is not mutating"; fi
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
[[ "$(flags "echo \$\$'a'")" == *U* ]] \
    && ok "U flags a run of \$ before a quote" || bad "U missed a run of \$ before a quote"
[[ "$(flags "echo \$'a' \$x'b' \\\$'c' \$\$")" != *U* ]] \
    && ok "U ignores a lone, a variable-adjacent, an escaped and a quote-less \$" || bad "U flagged a harmless \$"
shell_scan $'echo $$\'\\\'# a\\;'
[[ "$SHELL_SKELETON" == $'echo $$# a\\;' ]] \
    && ok "both scan passes read the quote after \$\$ as plain" || bad "the scan passes disagree after \$\$"
[[ "$(flags 'echo "${x:-"a"}"')" == *U* ]] \
    && ok "U flags a quote nested in \${...} in double quotes" || bad "U missed a quote nested in \${...}"
[[ "$(flags "echo \"\${x:-'a'}\"")" == *U* ]] \
    && ok "U flags a single quote nested in \${...} in double quotes" || bad "U missed a ' nested in \${...}"
[[ "$(flags 'echo "${x:-d}" "${a:-${b}}" "${#x}" "${x/a/b}" "${x}"')" != *U* \
    && "$(flags "echo \"\${x} it's\" \${y:-'a'}")" != *U* ]] \
    && ok "U ignores \${...} with no nested quote, a ' after it closes and an unquoted \${...}" \
    || bad "U flagged a harmless \${...}"
[[ "$(flags 'echo "$[1]"')" == *U* && "$(flags 'echo $[1]')" == *U* ]] \
    && ok "U flags a \$[ in and out of double quotes" || bad "U missed a \$["
[[ "$(flags $'echo $$[##\'] ; printf \'x\' \\\'')" == *U* && "$(flags 'echo "## t" ##a')" != *U* ]] \
    && ok "U flags ##' and ignores ## with no quote after it" || bad "U wrong for ##'"
[[ "$(flags $'echo ${HOME:##"} ; printf x "')" == *U* && "$(flags 'echo ${x:##\\}')" == *U* ]] \
    && ok "U flags ##\" and ##\\" || bad "U missed ##\" or ##\\"
[[ "$(flags 'echo $$[1]')" == *U* && "$(flags 'echo $$ [1] $$x[1]')" != *U* ]] \
    && ok "U flags a \$\$[" || bad "U missed a \$\$["
[[ "$(flags 'echo '"'"'$[1]'"'"' \$[1] "\$[1]"')" != *U* ]] \
    && ok "U ignores a quoted or escaped \$[" || bad "U flagged a quoted or escaped \$["
shell_scan $'echo "${x:-"#"}" \\;'
[[ "$SHELL_SKELETON" == 'echo  _' ]] \
    && ok "both scan passes keep a quote nested in \${...} inside the double quotes" \
    || bad "the scan passes disagree on a quote nested in \${...}"

# sq_strip: the command with '…' and $'…' removed, "…" and escapes kept; unchanged over the bound.
sq_expect() {
    sq_strip "$2"
    if [[ "$SQ_STRIPPED" == "$3" ]]; then ok "$1"; else bad "$1: want [$3] got [$SQ_STRIPPED]"; fi
}
sq_expect "sq_strip removes '…' and keeps \"…\""   "grep 'a/var/folders/b' \"c d\" e"  'grep  "c d" e'
sq_expect "sq_strip removes \$'…' with an escaped quote" "echo \$'x\\'y' z"            'echo  z'
sq_expect "sq_strip keeps a quote inside \"…\""     "echo \"it's '/x/'\" 'y'"             "echo \"it's '/x/'\" "
sq_expect "sq_strip keeps an escaped quote outside" "echo \\'/x/ 'y'"                    "echo \\'/x/ "
sq_expect "sq_strip keeps a \${…} with a nested quote in \"…\"" "echo \"\${x:-'a'}\" 'b'" "echo \"\${x:-'a'}\" "
sq_expect "sq_strip reads \$\$' as a plain quote"   "echo \$\$'a' b"                     'echo $$ b'
sq_expect "sq_strip keeps a \$\"…\" whole"          'echo $"a b" '"'c'"                  'echo $"a b" '
sq_expect "sq_strip drops an unterminated quote's tail" "echo 'a b"                      'echo '
sq_expect "sq_strip keeps a newline between words"  $'echo \'a\'\nb'                      $'echo \nb'
sq_expect "sq_strip leaves a quote-free command alone" 'cat /var/folders/x'              'cat /var/folders/x'

# rg_plain_shape: rg with only plain options, single-quoted literals and plain paths; fails closed.
rg_expect() {
    local want="$3" got=1
    if rg_plain_shape "$2"; then got=0; fi
    if [[ "$got" == "$want" ]]; then ok "$1"; else bad "$1: want $want got $got"; fi
}
rg_expect "rg_plain_shape takes options, a quoted literal and paths" "rg -n --max-count=3 --hidden 'a b' d/f.txt" 0
rg_expect "rg_plain_shape takes a lone rg and trailing spaces"        "rg  "                                    0
rg_expect "rg_plain_shape refuses --pre"                              "rg --pre x f"                            1
rg_expect "rg_plain_shape refuses --pre="                             "rg --pre=x f"                            1
rg_expect "rg_plain_shape refuses --pre-glob"                         "rg --pre-glob=x f"                       1
rg_expect "rg_plain_shape refuses --hostname-bin"                     "rg --hostname-bin x f"                   1
rg_expect "rg_plain_shape refuses a prefix of --pre"                  "rg --pr x f"                             1
rg_expect "rg_plain_shape refuses a prefix of --hostname-bin"         "rg --hostn x f"                          1
rg_expect "rg_plain_shape allows --hidden and --passthru"             "rg --hidden --passthru x f"              0
rg_expect "rg_plain_shape refuses a quoted --pre"                     "rg '--pre' x f"                          1
rg_expect "rg_plain_shape refuses a quoted --pre=value"               "rg '--pre=tee x' x f"                    1
rg_expect "rg_plain_shape refuses a quoted word starting with -"      "rg '-n' x f"                             1
rg_expect "rg_plain_shape allows a quoted word with a - inside"       "rg 'a-b' x f"                            0
rg_expect "rg_plain_shape refuses a bare - word"                      "rg - x f"                                1
rg_expect "rg_plain_shape refuses -- and -- followed by a path"       "rg -- --pre"                             1
rg_expect "rg_plain_shape refuses a - word the option forms miss"     "rg -/x f"                                1
rg_expect "rg_plain_shape refuses braces"                            "rg --{pre,x} x f"                        1
rg_expect "rg_plain_shape refuses a double-quoted word"               'rg "x" f'                                1
rg_expect "rg_plain_shape refuses an expansion"                       'rg $x f'                                 1
rg_expect "rg_plain_shape refuses a glob"                             "rg x *.txt"                              1
rg_expect "rg_plain_shape refuses a word glued to a quote"            "rg 'a'b f"                               1
rg_expect "rg_plain_shape refuses an ANSI-C quote"                    "rg \$'a' f"                              1
rg_expect "rg_plain_shape refuses a backslash"                        'rg --p\re x f'                           1
rg_expect "rg_plain_shape refuses a newline between words"            $'rg x\nf'                                1
rg_expect "rg_plain_shape refuses a command over its bound"          "rg $(printf 'a%.0s' $(seq 1 5000))"      1
sq_strip "$long"
[[ "$SQ_STRIPPED" == "$long" ]] \
    && ok "sq_strip returns a command over the bound unchanged" || bad "sq_strip changed a command over the bound"
sq_strip "'${long:1}'"
[[ "$SQ_STRIPPED" == "'${long:1}'" ]] \
    && ok "sq_strip returns a quoted command over the bound unchanged" || bad "sq_strip scanned past the bound"
sq_strip "'${long:3}'"
[[ -z "$SQ_STRIPPED" ]] \
    && ok "sq_strip strips a command at the bound" || bad "sq_strip left a command at the bound"

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

# strip_text_heredoc: a quoted-delimiter cat or tee heredoc that writes a file is reduced to its first line; any other
# shape comes back unchanged.
tx() {  # tx <description> <want: first|whole> <cmd>
    local got first="${3%%$'\n'*}"
    got=$(strip_text_heredoc "$3")
    if [[ "$2" == first && "$got" == "$first" ]] || [[ "$2" == whole && "$got" == "$3" ]]; then
        ok "$1"
    else
        bad "$1"
    fi
}
tx "a single-quoted cat > heredoc is reduced to its first line" first \
    $'cat > out.txt <<\'EOF\'\n#!/usr/bin/env python3\nfor x in y; do\nEOF'
tx "a double-quoted cat >> heredoc is reduced" first $'cat >> out.txt <<"EOF"\nline $(id)\nEOF'
tx "a backslash-quoted delimiter is reduced" first $'cat > out.txt <<\\EOF\n`a`\nEOF'
tx "a <<- heredoc with a tab-indented closer is reduced" first $'cat > out.txt <<-\'EOF\'\n\tbody\n\tEOF'
tx "a cat <<'EOF' > file heredoc with a final newline is reduced" first $'cat <<\'EOF\' > out.txt\nbody\nEOF\n'
tx "a tee heredoc is reduced" first $'tee out.txt <<\'EOF\'\nbody\nEOF'
tx "a tee -a heredoc with two files is reduced" first $'tee -a a.txt b.txt <<\'EOF\'\nbody\nEOF'
tx "an unquoted delimiter is left whole" whole $'cat > out.txt <<EOF\n$(id)\nEOF'
tx "an interpreter heredoc is left whole" whole $'python3 - <<\'EOF\'\nprint(1)\nEOF'
tx "a cat heredoc piped on is left whole" whole $'cat <<\'EOF\' | sh\necho hi\nEOF'
tx "text after the closing line is left whole" whole $'cat > out.txt <<\'EOF\'\nbody\nEOF\ncat .env'
tx "a closing line with a trailing blank is left whole" whole $'cat > out.txt <<\'EOF\'\nbody\nEOF \necho x'
tx "a cat file operand is left whole" whole $'cat notes.txt > out.txt <<\'EOF\'\nx\nEOF'
tx "a cat with an fd redirection is left whole" whole $'cat 2>err.txt <<\'EOF\'\nx\nEOF'
tx "a heredoc with no closing line is left whole" whole $'cat > out.txt <<\'EOF\'\nbody'
tx "a second closing line after the first is left whole" whole $'cat > out.txt <<\'EOF\'\nEOF\nrm -rf x\nEOF'
tx "a cat with no redirection is left whole" whole $'cat <<\'EOF\'\nbody\nEOF'
tx "a tee with no file is left whole" whole $'tee -a <<\'EOF\'\nbody\nEOF'
tx "a quoted redirect target is left whole" whole $'cat > \'a b\' <<\'EOF\'\nx\nEOF'
tx "a quoted newline in the first line is left whole" whole $'cat > \'a\nb\' <<\'EOF\'\nx\nEOF'
tx "a command with no newline is unchanged" whole 'cat > out.txt'
tx "a heredoc token after a bare redirection operator is left whole" whole $'cat > <<\'EOF\' a\nx\nEOF'
tx "a cat > \$CLAUDE_TEMP_DIR target is reduced" first $'cat > $CLAUDE_TEMP_DIR/x.py <<\'EOF\'\nx\nEOF'
tx "a cat > \${CLAUDE_TEMP_DIR} target is reduced" first $'cat > ${CLAUDE_TEMP_DIR}/x.py <<\'EOF\'\nx\nEOF'
tx "a cat > \"\$CLAUDE_TEMP_DIR\" target is reduced" first $'cat > "$CLAUDE_TEMP_DIR"/x.py <<\'EOF\'\nx\nEOF'
tx "an attached >\$CLAUDE_TEMP_DIR target is reduced" first $'cat >>$CLAUDE_TEMP_DIR/x.py <<\'EOF\'\nx\nEOF'
tx "a tee of two CLAUDE_TEMP_DIR targets is reduced" first \
    $'tee -a "$CLAUDE_TEMP_DIR"/a ${CLAUDE_TEMP_DIR}/b <<\'EOF\'\nx\nEOF'
tx "a CLAUDE_TEMP_DIR target with a .. segment is left whole" whole $'cat > $CLAUDE_TEMP_DIR/../x <<\'EOF\'\nx\nEOF'
tx "a CLAUDE_TEMP_DIR target ending in .. is left whole" whole $'cat > $CLAUDE_TEMP_DIR/a/.. <<\'EOF\'\nx\nEOF'
tx "a CLAUDE_TEMP_DIR target with an expansion is left whole" whole $'cat > $CLAUDE_TEMP_DIR/${X} <<\'EOF\'\nx\nEOF'
tx "a bare CLAUDE_TEMP_DIR target is left whole" whole $'cat > $CLAUDE_TEMP_DIR <<\'EOF\'\nx\nEOF'
tx "a CLAUDE_TEMP_DIR assignment prefix is left whole" whole \
    $'CLAUDE_TEMP_DIR=/tmp cat > $CLAUDE_TEMP_DIR/x <<\'EOF\'\nx\nEOF'
tx "a CLAUDE_TEMP_DIR assignment as a word is left whole" whole \
    $'cat > $CLAUDE_TEMP_DIR/x CLAUDE_TEMP_DIR=/tmp <<\'EOF\'\nx\nEOF'
tx "a plain target holding CLAUDE_TEMP_DIR is left whole" whole $'cat > a/CLAUDE_TEMP_DIR/x <<\'EOF\'\nx\nEOF'
tx "a CLAUDE_TEMP_DIR target in a double-quoted tail is left whole" whole \
    $'cat > "$CLAUDE_TEMP_DIR/x" <<\'EOF\'\nx\nEOF'
tx "a cat heredoc as a list's last part is reduced" first $'ls; cat > out.txt <<\'EOF\'\n(x)\nEOF'
tx "a tee heredoc after && is reduced" first $'git status && tee out.txt <<\'EOF\'\nx\nEOF'
tx "a heredoc operator before the last part is left whole" whole $'cat <<\'X\'; cat > f <<\'EOF\'\nx\nEOF'
tx "a heredoc in a part before the last is left whole" whole $'cat > f <<\'EOF\'; ls\nx\nEOF'
tx "a heredoc line holding a comment is left whole" whole $'ls # x; cat > f <<\'EOF\'\nx\nEOF'
tx "a heredoc line that cannot be scanned is left whole" whole $'echo \'a; cat > f <<\'EOF\'\nx\nEOF'

# _heredoc_last_part: the last list part of a heredoc's first line, the text before it, and the scan state kept.
shell_scan 'keep me'
_heredoc_last_part "ls; cat > f <<'EOF'"
[[ "$HEREDOC_PREFIX" == 'ls; ' && "$HEREDOC_PART" == "cat > f <<'EOF'" && "$SHELL_SKELETON" == 'keep me' ]] \
    && ok "_heredoc_last_part splits off the last part and keeps the caller's scan" \
    || bad "_heredoc_last_part: prefix [$HEREDOC_PREFIX] part [$HEREDOC_PART] skeleton [$SHELL_SKELETON]"
_heredoc_last_part "cat > f <<'EOF' 2>&1 | tee x"
[[ -z "$HEREDOC_PREFIX" && "$HEREDOC_PART" == "cat > f <<'EOF' 2>&1 | tee x" ]] \
    && ok "_heredoc_last_part keeps a pipeline whole" || bad "_heredoc_last_part split a pipeline: [$HEREDOC_PART]"
if _heredoc_last_part "ls # x; cat > f <<'EOF'"; then bad "_heredoc_last_part accepted a comment"
else ok "_heredoc_last_part refuses a comment"; fi

# script_heredoc_parse: a quoted-delimiter heredoc fed to Python is reduced to its first line, its body kept apart.
sh_expect() {  # sh_expect <description> <want: strip|whole> <cmd> [<want body>]
    script_heredoc_parse "$3"
    local first="${3%%$'\n'*}"
    if [[ "$2" == strip && "$SCRIPT_HEREDOC_OUT" == "$first" && "$SCRIPT_HEREDOC_BODY" == "${4-x}" ]] \
            || [[ "$2" == whole && "$SCRIPT_HEREDOC_OUT" == "$3" && -z "$SCRIPT_HEREDOC_BODY" ]]; then
        ok "$1"
    else
        bad "$1: out [$SCRIPT_HEREDOC_OUT] body [$SCRIPT_HEREDOC_BODY]"
    fi
}
sh_expect "python3 - <<'EOF' is reduced"            strip $'python3 - <<\'EOF\'\nx\nEOF'
sh_expect "python <<\"EOF\" is reduced"             strip $'python <<"EOF"\nx\nEOF'
sh_expect "an absolute python3.12 <<\\EOF is reduced" strip $'/usr/bin/python3.12 - <<\\EOF\nx\nEOF'
sh_expect "a <<- body loses its leading tabs"       strip $'python3 - <<-\'EOF\'\n\tx\n\tEOF'
sh_expect "redirections and a pipe after the heredoc" strip $'python3 - <<\'EOF\' 2>&1 | tail -20\nx\nEOF'
sh_expect "a redirection to a file after the heredoc" strip $'python3 - <<\'EOF\' > out.json\nx\nEOF'
sh_expect "a Python heredoc as a list's last part"  strip $'ls x; python3 - <<\'EOF\'\nx\nEOF'
sh_expect "a body of two lines is kept whole"       strip $'python3 - <<\'EOF\'\na = (1)\nprint(a)\nEOF' \
    $'a = (1)\nprint(a)'
sh_expect "an empty body"                           strip $'python3 - <<\'EOF\'\nEOF' ''
sh_expect "a final newline after the closer"        strip $'python3 - <<\'EOF\'\nx\nEOF\n'
sh_expect "an unquoted delimiter is left whole"     whole $'python3 - <<EOF\n$(id)\nEOF'
sh_expect "another option is left whole"            whole $'python3 -u - <<\'EOF\'\nx\nEOF'
sh_expect "a script operand is left whole"          whole $'python3 x.py <<\'EOF\'\nx\nEOF'
sh_expect "env before python is left whole"         whole $'env python3 - <<\'EOF\'\nx\nEOF'
sh_expect "an assignment before python is left whole" whole $'X=1 python3 - <<\'EOF\'\nx\nEOF'
sh_expect "sudo before python is left whole"        whole $'sudo python3 - <<\'EOF\'\nx\nEOF'
sh_expect "a shell heredoc is left whole"           whole $'bash <<\'EOF\'\nx\nEOF'
sh_expect "a node heredoc is left whole"            whole $'node - <<\'EOF\'\nx\nEOF'
sh_expect "a relative python path is left whole"    whole $'bin/python3 - <<\'EOF\'\nx\nEOF'
sh_expect "a closer that is not the last line is left whole" whole $'python3 - <<\'EOF\'\nx\nEOF\nls'
sh_expect "an input redirection is left whole"      whole $'python3 - <<\'EOF\' < f\nx\nEOF'
sh_expect "a quoted redirection target is left whole" whole $'python3 - <<\'EOF\' > "$x"\nx\nEOF'
sh_expect "a second heredoc is left whole"          whole $'python3 - <<\'EOF\' | cat <<\'X\'\nx\nEOF'
sh_expect "a heredoc in an earlier part is left whole" whole $'cat <<\'X\'; python3 - <<\'EOF\'\nx\nEOF'
sh_body=$(printf 'x%.0s' $(seq 1 $(( SHELL_SCAN_MAX_CHARS - 22 ))))
sh_expect "a command at the scan bound is reduced"  strip $'python3 - <<\'EOF\'\n'"$sh_body"$'\nEOF' "$sh_body"
sh_expect "a command over the scan bound is left whole" whole $'python3 - <<\'EOF\'\n'"${sh_body}x"$'\nEOF'

# shell_scan's list parts: the raw text of each part and the separators, as the skeleton cuts them.
parts() {  # parts <cmd>: "<part>|<sep>|<part>…" or NONE
    local k out=""
    shell_scan "$1"
    if (( ${#SHELL_SCAN_PARTS[@]} == 0 )); then printf NONE; return 0; fi
    for (( k = 0; k < ${#SHELL_SCAN_PARTS[@]}; k++ )); do
        out+="${SHELL_SCAN_PARTS[k]}"
        if (( k < ${#SHELL_SCAN_SEPS[@]} )); then out+="|${SHELL_SCAN_SEPS[k]}|"; fi
    done
    printf '%s' "$out"
}
expect_parts() {
    local got
    got=$(parts "$2")
    if [[ "$got" == "$3" ]]; then ok "$1"; else bad "$1: want [$3] got [$got]"; fi
}
expect_parts "a command with no separator has no parts"  "echo 'a; b'"            NONE
expect_parts "parts keep their quotes"            "ls 'a;b' && cat \"x y\""        "ls 'a;b'|&&|cat \"x y\""
expect_parts "each separator is recorded"         $'a; b || c\nd'                  $'a|;|b||||c|\n|d'
expect_parts "a trailing ; leaves an empty part"  'ls;'                            'ls|;|'
expect_parts "a backslash-newline is no separator" $'ls \\\n-la; ls'               $'ls \\\n-la|;|ls'
expect_parts "an escaped ; is no separator"       'find . -exec rm {} \; ; ls'     'find . -exec rm {} \;|;|ls'
expect_parts "a UTF-8 part keeps its bytes"       'echo "naïve — café"; ls'        'echo "naïve — café"|;|ls'
expect_parts "a | and a lone & are no separators" 'a | b & c; d'                   'a | b & c|;|d'
expect_parts "a quoted newline is cut in comment mode" $'echo \'a\nb\' # c'        $'echo \'a|\n|b\' # c'
expect_parts "a command holding \\x1f has no parts" $'a\x1fb; c'                    NONE
shell_scan "$(printf 'a;%.0s' $(seq 1 300))"
(( SHELL_SCAN_OVER == 1 && ${#SHELL_SCAN_SEPS[@]} == 256 )) \
    && ok "past 256 separators the scan stops cutting and reports it" \
    || bad "the separator bound: over=$SHELL_SCAN_OVER seps=${#SHELL_SCAN_SEPS[@]}"
shell_scan 'echo a#b'
(( SHELL_SCAN_COMMENT == 1 )) && ok "SHELL_SCAN_COMMENT marks a mid-word #" || bad "SHELL_SCAN_COMMENT missed a#b"
shell_scan "echo 'a#b' \\#"
(( SHELL_SCAN_COMMENT == 0 )) && ok "SHELL_SCAN_COMMENT ignores a quoted or escaped #" \
    || bad "SHELL_SCAN_COMMENT flagged a quoted #"

# list_check: the list contract.
FS=$'\x1c'
lc() {  # lc <cmd>: "<parts>\x1c<part text joined by \x1d>\x1c<ok or the reason>"
    shell_scan "$1"
    list_check "$1"
    local IFS=$'\x1d'
    printf '%s%s%s%s%s' "$LIST_PARTS" "$FS" "${LIST_PART_TEXT[*]}" "$FS" "${LIST_REASON:-ok}"
}
expect_list() {  # expect_list <description> <ALLOW|DENY> <cmd> [<parts> [<part text joined by \x1d>]]
    local got n t r
    got=$(lc "$3")
    n="${got%%"$FS"*}"
    r="${got##*"$FS"}"
    t="${got#*"$FS"}"
    t="${t%"$FS"*}"
    if [[ "$2" == ALLOW && "$r" != ok ]] || [[ "$2" == DENY && "$r" == ok ]] \
            || [[ -n "${4-}" && "$n" != "$4" ]] || [[ -n "${5-}" && "$t" != "$5" ]]; then
        bad "$1: want $2${4:+ $4 parts} got ${got//"$FS"/ | }"
    else
        ok "$1"
    fi
}
reason_is() {  # reason_is <description> <glob the reason must match> <lc output>
    # shellcheck disable=SC2053  # the reason is matched against a glob
    if [[ "${3##*"$FS"}" == $2 ]]; then ok "$1"; else bad "$1: got ${3//"$FS"/ | }"; fi
}
expect_reason() {  # expect_reason <description> <glob the reason must match> <cmd>
    reason_is "$1" "$2" "$(lc "$3")"
}
X=$'\x1d'
expect_list "a ; list is admitted"                  ALLOW 'ls a; ls b'                2 "ls a${X}ls b"
expect_list "an && list is admitted"                ALLOW 'ls a && ls b'              2
expect_list "an || list is admitted"                ALLOW 'ls a || ls b'              2
expect_list "a newline list is admitted"            ALLOW $'ls a\nls b'               2
expect_list "a trailing ; is dropped"               ALLOW 'ls a;'                     1 'ls a'
expect_list "a trailing newline is dropped"         ALLOW $'ls a\n'                   1
expect_list "a blank line is dropped"               ALLOW $'ls a\n\nls b'             2
expect_list "a pipeline is one part"                ALLOW 'git status; git log -1 | head' 2
expect_list "a quoted ; is one command"             ALLOW "echo 'a; b'"               1 "echo 'a; b'"
expect_list "an escaped ; is one command"           ALLOW 'find . -exec rm {} \;'     1
expect_list "a quoted newline is one command"       ALLOW $'echo \'a\nb\''            1
expect_list "operators in a jq filter are one command" ALLOW "jq '.a | .b; .c' f"     1
expect_list "UTF-8 text is one command"             ALLOW 'echo "naïve — café"'       1
expect_list "a double-quoted newline is one command" ALLOW $'jq "\n.a" f'             1
expect_list "parts keep their quoted text"          ALLOW "ls 'a;b' && cat \"x y\""   2 "ls 'a;b'${X}cat \"x y\""
expect_list "a UTF-8 part keeps its bytes"          ALLOW 'echo "naïve — café"; ls'   2 "echo \"naïve — café\"${X}ls"
expect_list "an assignment prefix is scoped to its command" ALLOW 'X=1 make; ls'      2
expect_list "an assignment prefix before a pipeline" ALLOW 'FOO=bar env | head; ls'   2
expect_list "a heredoc reduced to its first line may end a list" ALLOW "ls; cat > f <<'EOF'" 2
expect_list "a here-string is no heredoc"           ALLOW 'cat <<< x; ls'             2
expect_list "16 parts are admitted"                 ALLOW "$(printf 'ls; %.0s' $(seq 1 15))ls" 16
expect_list "17 parts are denied"                   DENY  "$(printf 'ls; %.0s' $(seq 1 16))ls"
expect_reason "the bound names its limit"           '*at most 16*' "$(printf 'ls; %.0s' $(seq 1 16))ls"
expect_reason "rule 0: an unterminated quote"       '*could not be split*' "echo 'a; ls b"
expect_reason "rule 0: a command holding \\x1f"     '*could not be split*' $'ls a\x1f; ls'
for c in 'ls & ls; ls' 'ls; (ls)' 'ls; echo $(id)' 'ls; echo "$(id)"' 'ls; echo `id`' 'ls; cat <(ls)' \
        'ls; tee >(cat)' ';ls' 'ls;;ls' 'ls && && ls' 'ls &&' 'ls ||' 'ls; ls |' $'ls &&\nls' '&& ls'; do
    expect_reason "rule 1 denies '$c'" '*;, &&, || or newlines only*' "$c"
done
expect_reason "rule 1: a heredoc the strips left whole" '*here-document*' $'ls; cat <<EOF\nx\nEOF'
expect_reason "rule 1: a heredoc body's lines are no parts" '*here-document*' \
    $'kubectl apply -f - <<\'EOF\'\nkind: x\nEOF'
expect_reason "rule 2: a comment line"              '*comment*' $'ls # x\nls'
expect_reason "rule 2: a mid-word #"                '*comment*' 'echo a#b && ls'
expect_reason "rule 2: miss 4, apostrophes in comments" '*comment*' $'echo a # it\'s\ncat x/y # it\'s'
reason_is "rule 2a: the tokeniser disagreeing with the scan" '*could not be split*' \
    "$(shell_words() { SW_WORDS=(wls); SW_OK=1; }; lc 'ls; ls')"
reason_is "rule 0: a tokeniser failure" '*could not be split*' \
    "$(shell_words() { SW_WORDS=(); SW_OK=0; }; lc 'ls; ls')"
for w in 'if' 'then' 'elif' 'else' 'fi' 'do' 'done' 'case' 'esac' 'while' 'until' 'for' 'select' 'function' \
        'coproc' '{' '}' '[[' ']]' '!' 'time' 'noglob' 'nocorrect'; do
    expect_reason "rule 3 denies '$w' at command position" "*'$w' starts a compound command*" "ls; $w x"
done
expect_reason "rule 3: miss 3, an if around eval"   "*'if' starts*" 'if true; then eval "$X"; fi'
expect_reason "rule 3: a reserved word after an assignment" "*'while' starts*" 'ls; X=1 while x'
for w in cd pushd popd chdir export declare typeset local readonly unset integer float read vared mapfile \
        readarray getopts let source . eval alias unalias autoload zmodload set shopt setopt unsetopt emulate trap \
        umask ulimit hash enable zparseopts; do
    expect_reason "rule 4 denies '$w'" "*'$w' changes shell state*" "ls; $w x"
done
expect_reason "rule 4: miss 1, cd before a search"  "*'cd' changes*git -C*" 'cd ~; grep -r password .'
expect_reason "rule 4: miss 2, an assignment"       "*'F=.env' changes*"    'F=.env; cat "$F"'
expect_reason "rule 4: an array assignment"         "*'X\[1\]=a' changes*"  'ls; X[1]=a'
expect_reason "rule 4: an append assignment"        "*'X+=a' changes*"      'ls; X+=a'
expect_reason "rule 4: two assignments alone"       "*'Y=2' changes*"       'ls; X=1 Y=2'
expect_reason "rule 4: cd behind command"           "*'cd' changes*"        'ls; command cd /'
expect_reason "rule 4: export behind builtin"       "*'export' changes*"    'ls; builtin export X'
expect_reason "rule 4: a bare exec"                 "*'exec' changes*"      'ls; exec'
expect_reason "rule 4: a bare exec with a redirection" "*'exec' changes*"   'ls; exec 3>f'
expect_reason "rule 4: read in a pipeline's last stage" "*'read' changes*"  'echo .env | read F; cat "$F"'
expect_reason "rule 4: printf -v"                   "*'printf -v' changes*" 'printf -v F .env; cat "$F"'
expect_reason "rule 4: print with v in a bundle"    "*'print -v' changes*"  'print -rv F x; ls'
expect_reason "rule 4: print -v after another option" "*'print -v' changes*" 'print -r -v F .env; cat "$F"'
expect_reason "rule 4: print -v after -C and its count" "*'print -v' changes*" 'print -C 2 -v F x; ls'
expect_reason "rule 4: printf -v behind command"    "*'printf -v' changes*" 'ls; command printf -v F x'
expect_list "print -v after -- is printed text"     ALLOW 'print -- -v F; ls'      2
expect_reason "rule 4 names the working directory the Bash tool keeps" '*keeps the working directory*' 'cd x; ls'
expect_list "printf without -v is no state change"  ALLOW 'printf %s x; ls'       2
expect_list "a state word as an argument is fine"   ALLOW 'echo cd; grep export f' 2
expect_list "a single cd is no list"                ALLOW 'cd x'                  1
expect_list "a single cd with a trailing ; is no list" ALLOW 'cd x;'              1
for b in "$BASH" /bin/bash; do
    [[ -x "$b" ]] || continue
    for c in 'ls a; ls b' 'cd ~; grep -r x .' $'ls # x\nls' 'ls; if x' 'ls &&' "ls 'a;b' && cat \"x y\""; do
        prog='source "$1"; shell_scan "$2"; list_check "$2"; printf "%s|%s" "$LIST_PARTS" "${LIST_REASON:-ok}"'
        got=$("$b" -c "$prog" _ "$DIR/_lib.sh" "$c")
        want=$(lc "$c")
        if [[ "$got" == "${want%%"$FS"*}|${want##*"$FS"}" ]]; then
            ok "list_check under $b: '$c'"
        else
            bad "list_check under $b: '$c' got $got"
        fi
    done
done

# _ms: the time in milliseconds (EPOCHREALTIME on bash 5; whole seconds before it).
_ms() {
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
        local t="${EPOCHREALTIME/[.,]/}"
        echo $(( t / 1000 ))
    else
        echo $(( SECONDS * 1000 ))
    fi
}

# norm_path: ~ and $HOME expand, a relative path joins the cwd, . and .. collapse and slashes fold; ~user and any other
# $ cannot be resolved, except with literal, where $ is a plain character.
np() {  # np <path> <cwd> [literal]: NORM_PATH, or FAIL
    if norm_path "$@"; then printf '%s' "$NORM_PATH"; else printf 'FAIL'; fi
}
while IFS='|' read -r path cwd mode want; do
    got=$(HOME=/h/u np "$path" "$cwd" ${mode:+"$mode"})
    [[ "$got" == "$want" ]] && ok "norm_path '$path' from '$cwd' is $want" \
        || bad "norm_path '$path': want $want got $got"
done <<'ROWS'
~|/c||/h/u
~/a|/c||/h/u/a
$HOME/a|/c||/h/u/a
${HOME}/a/../b|/c||/h/u/b
a/./b//c/|/c/d||/c/d/a/b/c
../../..|/c/d||/
/x/../../y|/c||/y
.|/c||/c
sub dir/x|/c||/c/sub dir/x
$X/a|/c||FAIL
~bob/a|/c||FAIL
$X/a|/c|literal|/c/$X/a
~/a|/c|literal|/h/u/a
ROWS

# probe_root_too_wide: / and $HOME or above, and /tmp or /private/tmp or above (the vault lives there).
for r in / /h /h/u /tmp /private /private/tmp; do
    HOME=/h/u probe_root_too_wide "$r" && ok "a probe root at $r is too wide" || bad "a probe root at $r was allowed"
done
for r in /h/u/x /h/v /tmp/claude-x /var /private/var; do
    if HOME=/h/u probe_root_too_wide "$r"; then bad "a probe root at $r was too wide"; else
        ok "a probe root at $r is narrow enough"; fi
done

# glob_quote escapes \ * ? [ so a directory name is matched literally.
glob_quote 'a*b?[c\d'
[[ "$GLOB_QUOTED" == 'a\*b\?\[c\\d' ]] && ok "glob_quote escapes pattern characters" \
    || bad "glob_quote gave $GLOB_QUOTED"

# probe_glob_plain: only ASCII letters, digits and . _ - * ? make a glob plain.
for g in '*.py' 'a?b' 'x-y_z.1' '*'; do
    probe_glob_plain "$g" && ok "the glob '$g' is plain" || bad "the glob '$g' was not plain"
done
for g in '' 'src/*.py' '*.{py,env}' '[a].py' '!x' 'a b' $'\xc3\xa9'; do
    if probe_glob_plain "$g"; then bad "the glob '$g' was plain"; else ok "the glob '$g' is not plain"; fi
done

# The directory probe. Fixtures are empty files with secret names; nothing holds a value.
pd=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/lib-probe.XXXXXX")
mkdir -p "$pd/plain/src" "$pd/repo/src" "$pd/sec" "$pd/lroot" "$pd/sp/a b" "$pd/locked/in" "$pd/w/.aws" "$pd/w/x" \
    "$pd/b[r]" "$pd/fold"
: >"$pd/plain/.env"
: >"$pd/plain/src/a.py"
: >"$pd/plain/src/k.pem"
git -C "$pd/repo" init -q
printf '.env\n' >"$pd/repo/.gitignore"
: >"$pd/repo/.env"
: >"$pd/repo/src/a.py"
: >"$pd/sec/id_ed25519"
ln -s "$pd/sec" "$pd/lroot/s"
: >"$pd/sp/a b/.env"
: >"$pd/w/.aws/credentials"
: >"$pd/w/x/a.txt"
: >"$pd/b[r]/.env"
: >"$pd/fold/creds."$'\xc5\xbf'"ecret"
probe() {  # probe <kind> <root> [<include> <exclude> <exclude-dir>]: "<rc> <hits>"
    local rc=0
    probe_reset
    probe_add "$1" "$2" form "${@:3}"
    dir_holds_secret || rc=$?
    printf '%s %s' "$rc" "$DHS_HITS"
}
expect_probe() {  # expect_probe <description> <want glob> <probe args...>
    local got
    got=$(probe "${@:3}")
    # shellcheck disable=SC2053  # the want is a pattern
    if [[ "$got" == $2 ]]; then ok "$1"; else bad "$1: want $2 got $got"; fi
}
expect_probe "find lists a root holding .env and a key"          "0 *$pd/plain/.env*"      find "$pd/plain"
expect_probe "the hit list names the key under a subdirectory"   "0 *$pd/plain/src/k.pem*" find "$pd/plain"
expect_probe "git honours the repository's .gitignore"           '1 '                      git "$pd/repo"
expect_probe "tracked lists committed files only"                '1 '                      tracked "$pd/repo"
# git C-quotes a name holding " \ or a control character whatever core.quotepath says; the listing must not.
mkdir -p "$pd/qrepo/q\"d"
git -C "$pd/qrepo" init -q
: >"$pd/qrepo/q\"d/.env"
expect_probe "git sees an untracked name holding a quote"        "0 $pd/qrepo/q\"d/.env"   git "$pd/qrepo"
git -C "$pd/qrepo" add -A
expect_probe "tracked sees a staged name holding a quote"        "0 $pd/qrepo/q\"d/.env"   tracked "$pd/qrepo"
# A name that is not valid UTF-8 must not cut the listing short: a UTF-8 tr stops at the first bad byte. APFS refuses
# such a name, so the work-tree row may skip; the stub rows run everywhere.
mkdir -p "$pd/ffrepo/b"
git -C "$pd/ffrepo" init -q
if : 2>/dev/null >"$pd/ffrepo/a"$'\xff'; then
    : >"$pd/ffrepo/b/.env"
    expect_probe "a name that is not UTF-8 hides no later secret"  "0 $pd/ffrepo/b/.env"     git "$pd/ffrepo"
else
    ok "a name that is not UTF-8 hides no later secret (skipped: the file system refuses the name)"
fi
git() {
    case " $* " in
        *' rev-parse '*) printf 'true\n' ;;
        *' ls-files '*) printf 'a\377\000b/.env\000' ;;
    esac
}
expect_probe "a listed name that is not UTF-8 hides no later secret" '0 /r/b/.env'          git /r
tr() { cat >/dev/null; return 1; }
expect_probe "a tr failure after a clean git makes the listing inconclusive" '2 '          git /r
unset -f git tr
expect_probe "find ignores .gitignore"                           "0 *$pd/repo/.env*"       find "$pd/repo"
# git lists an untracked nested repository as one dir/ entry and a submodule as one gitlink, but rg descends into both:
# kind git must list them in full.
mkdir -p "$pd/nest/inner" "$pd/nest/plain"
git -C "$pd/nest" init -q
git -C "$pd/nest/inner" init -q
: >"$pd/nest/inner/.env"
: >"$pd/nest/plain/a.py"
expect_probe "git descends an untracked nested repository"       "0 $pd/nest/inner/.env"   git "$pd/nest"
expect_probe "tracked does not descend a nested repository"      '1 '                      tracked "$pd/nest"
mkdir -p "$pd/subsrc" "$pd/outer"
git -C "$pd/subsrc" init -q
git -C "$pd/subsrc" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t.invalid \
    commit -q --no-verify --allow-empty -m init
git -C "$pd/outer" init -q
if git -C "$pd/outer" -c protocol.file.allow=always submodule add -q "$pd/subsrc" sub >/dev/null 2>&1; then
    : >"$pd/outer/sub/.env"
    expect_probe "git descends a submodule"                      "0 $pd/outer/sub/.env"    git "$pd/outer"
else
    ok "git descends a submodule (skipped: submodule add failed here)"
fi
# A reported gitlink that is not a directory (a name the line split mangles, or a submodule removed from disk) cannot be
# probed, so the listing is inconclusive.
git() {
    case " $* " in
        *' rev-parse '*) printf 'true\n' ;;
        *' -s '*) printf '160000 0000000000000000000000000000000000000000 0\tgone\000' ;;
    esac
}
expect_probe "a gitlink path that is not a directory is inconclusive"    '2 '                      git /r
unset -f git
expect_probe "git outside a work tree lists with find"           '0 *'                     git "$pd/plain"
expect_probe "an include list narrows the hits away"             '1 '                      find "$pd/plain" '*.py'
expect_probe "an exclude glob leaves the other hit"              "0 $pd/plain/src/k.pem"   find "$pd/plain" '' .env
expect_probe "two exclude globs drop both hits"                  '1 '  find "$pd/plain" '' $'.env\x1f*.pem'
expect_probe "an exclude-dir glob drops hits below it"           '1 '  find "$pd/plain" '' .env src
expect_probe "an include holding a brace is ignored (fails closed)" '0 *' find "$pd/plain" '*.{py,txt}'
expect_probe "a leading **/ also matches at the top"             "0 $pd/plain/.env"        find "$pd/plain" '**/.env'
expect_probe "find does not follow a symlinked directory"        '1 '                      find "$pd/lroot"
expect_probe "find -L follows a symlinked directory"             "0 $pd/lroot/s/id_ed25519" findL "$pd/lroot"
expect_probe "a hit under a directory holding a space"           "0 $pd/sp/a b/.env"       find "$pd/sp"
expect_probe "a name spelt with a long s is folded"              "0 $pd/fold/*"            find "$pd/fold"
if [[ "$(id -u)" != 0 ]]; then
    chmod 000 "$pd/locked/in"
    expect_probe "an unreadable subdirectory makes the listing inconclusive" '2 ' find "$pd/locked"
    chmod 755 "$pd/locked/in"
fi
probe_reset
probe_add find /r a
probe_add find /r a
[[ "$PROBE_N" == 1 ]] && ok "a repeated root is held once" || bad "a repeated root was held $PROBE_N times"
probe_reset
full=0
for (( i = 1; i <= 64; i++ )); do probe_add find "/r$i" a || full=1; done
probe_add find /r65 a && bad "a 65th root was accepted" || ok "a 65th root is refused"
(( ! full )) && ok "64 roots are accepted" || bad "fewer than 64 roots were accepted"
probe_reset
probe_add find /a a
probe_add find /b a
probe_add find /c a
probe_truncate 1
[[ "$PROBE_N" == 1 && "${#PROBE_ROOT[@]}" == 1 ]] && ok "probe_truncate keeps the first roots" \
    || bad "probe_truncate kept $PROBE_N roots"
probe_add find /a a
probe_add find /b a
[[ "$PROBE_N" == 2 && "${PROBE_ROOT[1]}" == /b ]] && ok "probe_truncate forgets a dropped root, not a kept one" \
    || bad "after probe_truncate: $PROBE_N roots, second ${PROBE_ROOT[1]:-none}"
probe_add tracked /p a '' '' '' :!x
probe_add tracked /p a '' '' '' :!y
[[ "$PROBE_N" == 4 ]] && ok "roots that differ only in their pathspecs are two entries" \
    || bad "pathspecs are not part of the key: $PROBE_N roots"

# The gps kinds list what git resolves from the command's pathspecs, exclusions included.
mkdir -p "$pd/gps/src" "$pd/gps/inner"
git -C "$pd/gps" init -q
: >"$pd/gps/.env"
: >"$pd/gps/src/a.py"
git -C "$pd/gps" add .env src/a.py
git -C "$pd/gps/inner" init -q
: >"$pd/gps/inner/.env"
expect_probe "gpstracked lists a tracked secret the pathspecs keep"  "0 $pd/gps/.env"   gpstracked "$pd/gps" '' '' '' .
expect_probe "gpstracked leaves out a secret an exclusion drops"     '1 '  gpstracked "$pd/gps" '' '' '' $'.\x1f:!.env'
expect_probe "gpstracked with no pathspecs lists the whole directory" "0 $pd/gps/.env"  gpstracked "$pd/gps"
expect_probe "gpsgit still lists a nested repository in full" \
    "0 $pd/gps/inner/.env" gpsgit "$pd/gps" '' '' '' $'.\x1f:!.env'
expect_probe "a gps kind outside a work tree lists with find"        '0 *'  gpstracked "$pd/plain" '' '' '' $':!.env'
expect_probe "a pathspec git rejects makes the listing inconclusive" '2 '  gpstracked "$pd/gps" '' '' '' /elsewhere

# Stub listers: the cap, a failure with and without a hit, and a lister that never finishes.
stub_cap() {
    printf '\0020\t/r\n'
    LC_ALL=C awk 'BEGIN { for (i = 0; i <= 100000; i++) print "f" i }'
    printf '\0030\n'
}
stub_fail() { printf '\0020\t/r\n'; printf 'a\n'; printf '\0031\n'; }
stub_hitfail() { printf '\0020\t/r\n'; printf '.env\n'; printf '\0031\n'; }
probe_stub() {  # probe_stub <lister>: "<rc>|<why>|<hits>"
    local rc=0
    probe_reset
    probe_add find /r form
    dir_holds_secret "$1" || rc=$?
    printf '%s|%s|%s' "$rc" "$DHS_WHY" "$DHS_HITS"
}
[[ "$(probe_stub stub_cap)" == "2|"*100000*"|" ]] && ok "the entry cap makes the listing inconclusive" \
    || bad "the entry cap: $(probe_stub stub_cap)"
[[ "$(probe_stub stub_fail)" == "2|"*"part of it could not be listed"*"|" ]] \
    && ok "a failed lister with no hit is inconclusive" \
    || bad "a failed lister: $(probe_stub stub_fail)"
[[ "$(probe_stub stub_hitfail)" == "0||/r/.env" ]] && ok "a hit before a failure still counts" \
    || bad "a hit before a failure: $(probe_stub stub_hitfail)"

# The watchdog and the cap, timed under every bash the hooks run on: inconclusive within the 2 500 ms budget, with no
# ERR trap firing.
pfix=$(mktemp "${CLAUDE_TEMP_DIR:-/tmp}/lib-pfix.XXXXXX")
cat > "$pfix" <<'FIXTURE'
set -uo pipefail
source "$1"
source "$2"
trap 'printf ERR' ERR
stub_slow() { sleep 3; }
stub_cap() {
    printf '\0020\t/r\n'
    LC_ALL=C awk 'BEGIN { for (i = 0; i <= 100000; i++) print "f" i }'
    printf '\0030\n'
}
probe_add find /r form
rc=0
dir_holds_secret "stub_$3" || rc=$?
printf '%s|%s' "$rc" "$DHS_WHY"
FIXTURE
for b in "$BASH" /bin/bash; do
    [[ -x "$b" ]] || continue
    for s in slow cap; do
        start=$(_ms)
        out=$("$b" "$pfix" "$DIR/_lib.sh" "$DIR/secret-patterns.sh" "$s" 2>/dev/null)
        el=$(( $(_ms) - start ))
        if [[ "$out" == "2|"* && "$out" != *ERR* ]] && (( el < 2500 )); then
            ok "the $s stub is inconclusive in ${el} ms under $b"
        else
            bad "the $s stub under $b: '$out' in ${el} ms"
        fi
    done
done
rm -f "$pfix"

# hook_deadline, under every bash the hooks run on: the hook runs again as a child, given its arguments and payload,
# and the child's stdout, stderr and exit status are relayed once. A child past the deadline is killed with its
# children and denied, as is one that dies by a signal; no watchdog outlives a call. The 1.25 s deadline sits far
# from the 31 s sleep and the 10 s bound.
hfix=$(mktemp "${CLAUDE_TEMP_DIR:-/tmp}/lib-hfix.XXXXXX")
cat > "$hfix" <<'FIXTURE'
set -uo pipefail
source "$1"
hook_deadline 1.25 "fixture ran out of time" "$@"
case "$2" in
    deny) hook_deny "denied" ;;
    echo) printf '%s:' "${HOOK_DEADLINE_CHILD:-}"; cat ;;
    status) printf 'to stderr' >&2; exit 2 ;;
    slow) sleep 31.4159 ;;
    signal) kill -KILL $$ ;;
esac
FIXTURE
herr=$(mktemp "${CLAUDE_TEMP_DIR:-/tmp}/lib-herr.XXXXXX")
# deadline_run <bash> <mode>: set out, rc, err and el (ms) for the fixture given the payload "payload".
deadline_run() {
    local start
    start=$(_ms)
    out=$(printf 'payload' | "$1" "$hfix" "$DIR/_lib.sh" "$2" 2>"$herr")
    rc=$?
    el=$(( $(_ms) - start ))
    err=$(cat "$herr")
}
for b in "$BASH" /bin/bash; do
    [[ -x "$b" ]] || continue
    deadline_run "$b" deny
    if [[ $rc -eq 0 && "$(jq -sc 'map(.hookSpecificOutput.permissionDecision)' <<< "$out")" == '["deny"]' ]]; then
        ok "hook_deadline relays a child's decision once under $b"
    else
        bad "hook_deadline relayed under $b: rc=$rc out=$out"
    fi
    pgrep -f 'sleep 1.25' >/dev/null && bad "a call under $b left its watchdog's sleep running" \
        || ok "a call under $b leaves no watchdog running"
    deadline_run "$b" echo
    [[ "$out" == "1:payload" ]] && ok "the child gets the payload and HOOK_DEADLINE_CHILD under $b" \
        || bad "the child under $b printed: $out"
    deadline_run "$b" status
    [[ $rc -eq 2 && "$err" == "to stderr" && -z "$out" ]] \
        && ok "a child's exit status and stderr are relayed under $b" \
        || bad "a child's status under $b: rc=$rc err=$err out=$out"
    deadline_run "$b" slow
    if [[ $rc -eq 0 && "$(jq -r '.hookSpecificOutput.permissionDecision + ":" +
            .hookSpecificOutput.permissionDecisionReason' <<< "$out" 2>/dev/null)" \
            == "deny:fixture ran out of time" ]] && (( el < 10000 )); then
        ok "a child past the deadline denies in ${el} ms under $b"
    else
        bad "a child past the deadline under $b: rc=$rc out=$out in ${el} ms"
    fi
    left=1
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -f 'sleep 31.4159' >/dev/null; then left=0; break; fi
        sleep 0.1
    done
    (( left == 0 )) && ok "a child past the deadline is killed with its children under $b" \
        || bad "a child past the deadline left its sleep running under $b"
    pkill -f 'sleep 31.4159' 2>/dev/null
    deadline_run "$b" signal
    [[ $rc -eq 0 && "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out" 2>/dev/null)" == deny ]] \
        && ok "a child that dies by a signal denies under $b" \
        || bad "a child killed by a signal under $b: rc=$rc out=$out"
done
rm -f "$hfix" "$herr"

# The run-wide deadline, under every bash the hooks run on: a slow expansion is cut and reads as unfinished, within
# the 2 500 ms budget; once the deadline has passed, no expansion or listing starts.
dfix=$(mktemp "${CLAUDE_TEMP_DIR:-/tmp}/lib-dfix.XXXXXX")
cat > "$dfix" <<'FIXTURE'
set -uo pipefail
source "$1"
source "$2"
trap 'printf ERR' ERR
case "$3" in
    slow-wild|slow-glob)
        hook_clock_start
        HOOK_DEADLINE_MS=400
        _wh_run() { sleep 3; }
        _glob_run() { sleep 3; } ;;
    past-*)
        if [[ -n "${EPOCHREALTIME:-}" ]]; then HOOK_T0=1; else HOOK_T0=s; SECONDS=100; fi ;;
esac
rc=0
case "$3" in
    *-wild) wild_holds_secret "/*" || rc=$? ;;
    *-glob) glob_dirs "/*/" || rc=$? ;;
    past-probe) probe_add find / form; dir_holds_secret || rc=$?; rc="$rc:$DHS_WHY" ;;
esac
printf '%s' "$rc"
FIXTURE
dcases=(slow-wild:3 slow-glob:3 past-wild:3 past-glob:3 "past-probe:2:the hook ran out of time before listing it")
for b in "$BASH" /bin/bash; do
    [[ -x "$b" ]] || continue
    for s in "${dcases[@]}"; do
        start=$(_ms)
        out=$("$b" "$dfix" "$DIR/_lib.sh" "$DIR/secret-patterns.sh" "${s%%:*}" 2>/dev/null)
        el=$(( $(_ms) - start ))
        if [[ "$out" == "${s#*:}" ]] && (( el < 2500 )); then
            ok "the deadline: ${s%%:*} gives ${out} in ${el} ms under $b"
        else
            bad "the deadline: ${s%%:*} under $b: want '${s#*:}' got '$out' in ${el} ms"
        fi
    done
done
rm -f "$dfix"
# An end marker marks a finished expansion: output cut before it reads as unfinished.
fin_awk() { LC_ALL=C awk -v cap=10 -v maxh=1 -v fin=1 -v sre=x -v are=y -v folds="" "$_DHS_AWK"; }
[[ "$(printf '/a\n\004\n' | fin_awk)" == E1 ]] && ok "a finished expansion reads as finished" \
    || bad "a finished expansion: $(printf '/a\n\004\n' | fin_awk)"
[[ -z "$(printf '/a\n' | fin_awk)" ]] && ok "an expansion cut before its end marker reads as unfinished" \
    || bad "a cut expansion: $(printf '/a\n' | fin_awk)"
[[ -z "$(printf '\004\n/a\n' | fin_awk)" ]] && ok "an end marker before more output does not count" \
    || bad "an early end marker: $(printf '\004\n/a\n' | fin_awk)"

# The probe's filter applies the narrow allows as path_is_secret does: not below the vault or a credential directory,
# and not past a .. segment; a general allow (*.example, *.pub) lifts through a .. segment.
probe_awk() {
    printf '%s\n' "$1" | LC_ALL=C awk -v cap=10 -v maxh=1 -v sre="$SECRET_PATH_AWK_RE" -v are="$SECRET_ALLOW_AWK_RE" \
        -v nre="$SECRET_NARROW_AWK_RE" -v lre="$SECRET_NOLIFT_AWK_RE" -v folds="" "$_DHS_AWK"
}
for p in /a/lib/certifi/cacert.pem /a/App/Secrets/Foo.cs /a/other/../.env.example /a/../x/id_rsa.pub; do
    [[ "$(probe_awk "$p")" == E1 ]] && ok "the probe filter lifts a narrow allow: $p" \
        || bad "the probe filter: $p gave $(probe_awk "$p")"
done
for p in /a/x/secrets/../../h/certifi/cacert.pem /a/App/Secrets/Foo.cs/.. /tmp/claude-a-vault/certifi/cacert.pem \
        /a/.ssh/certifi/cacert.pem; do
    [[ "$(probe_awk "$p")" == H* ]] && ok "the probe filter keeps a hit: $p" \
        || bad "the probe filter missed: $p gave $(probe_awk "$p")"
done

# wild_holds_secret expands a quoted directory plus a wildcard-only component.
rc=0
glob_quote "$pd/w"
wild_holds_secret "$GLOB_QUOTED/.aws/*" || rc=$?
[[ "$rc" == 0 && "$WH_HIT" == */.aws/credentials ]] && ok "a wildcard over ~/.aws matches credentials" \
    || bad "a wildcard over .aws: rc=$rc hit=$WH_HIT"
rc=0
wild_holds_secret "$GLOB_QUOTED/x/*" || rc=$?
[[ "$rc" == 1 ]] && ok "a wildcard over plain files matches nothing secret" || bad "a plain wildcard: rc=$rc"
rc=0
wild_holds_secret "$GLOB_QUOTED/*" || rc=$?
[[ "$rc" == 1 ]] && ok "a bare * skips dotfiles" || bad "a bare *: rc=$rc"
rc=0
glob_quote "$pd/b[r]"
wild_holds_secret "$GLOB_QUOTED/.*" || rc=$?
[[ "$rc" == 0 ]] && ok "a directory name holding [ is matched literally" || bad "a bracketed directory: rc=$rc"
rm -rf "$pd"

echo "-----"; echo "passed: $pass  failed: $fail"; [ "$fail" -eq 0 ]
