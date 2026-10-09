#!/usr/bin/env bash
# Tests for hooks/_lib.sh: the shell_words tokeniser and its plain-word classifier, the crash backstop, the git walk
# and shell_scan's P flag. This suite holds no secret-shaped values, so it may run through the Bash tool.
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
expect_words "a versioned listed name stays w"  'cat2 a'                     '[wcat2][pa]' "$NAMES" "$FRAG"
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
    held-pass) hook_hold_ask "held"; hook_hold_ask "second"; hook_pass ;;
    held-deny) hook_hold_ask "held"; hook_deny "denied" ;;
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
            <<< "$out")" == '["ask:held"]' ]]; then
        ok "a held ask is emitted once by hook_pass under $b, with its first reason"
    else
        bad "a held ask under $b printed: $out"
    fi
    out=$("$b" "$fixture" "$DIR/_lib.sh" held-deny 2>/dev/null)
    if [[ "$(jq -sc 'map(.hookSpecificOutput.permissionDecision)' <<< "$out")" == '["deny"]' ]]; then
        ok "a deny after a held ask wins under $b"
    else
        bad "a deny after a held ask under $b printed: $out"
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
