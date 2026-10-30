#!/usr/bin/env bash
# Tests for gh-merge-ask.sh: gh pr merge prompts unless every repository the command can target is on the hook's
# unprompted list; a merge with no repository named is judged by the origin remote of the working directory. Anything
# else, unrelated commands included, gets no decision, so the native rules decide them.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/gh-merge-ask.sh"
pass=0; fail=0
ok()  { printf 'PASS: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

scratch=$(mktemp -d "${CLAUDE_TEMP_DIR:-/tmp}/gma-test.XXXX") || { printf 'FAIL: mktemp -d\n'; exit 1; }
trap 'rm -rf "$scratch"' EXIT
OURS=ExampleOrg/ours-repo
printf '# unprompted repositories\n\n  %s  # trailing comment\nExampleOrg/second\n' "$OURS" > "$scratch/repos"
export GH_MERGE_ASK_REPOS_FILE="$scratch/repos"
for spec in "ours:git@github.com:$OURS.git" "https:https://github.com/$OURS" "other:git@github.com:Acme/widgets.git"; do
    name=${spec%%:*}
    git init -q "$scratch/$name"
    git -C "$scratch/$name" remote add origin "${spec#*:}"
done
mkdir -p "$scratch/plain" "$scratch/ours/sub/dir"
git init -q "$scratch/fork"
git -C "$scratch/fork" remote add origin "git@github.com:$OURS.git"
git -C "$scratch/fork" remote add upstream "https://github.com/Acme/widgets.git"
git init -q "$scratch/both"
git -C "$scratch/both" remote add origin "git@github.com:$OURS.git"
git -C "$scratch/both" remote add mirror "https://github.com/ExampleOrg/second"
git init -q "$scratch/rewrite"
git -C "$scratch/rewrite" remote add origin "https://github.com/$OURS"
git -C "$scratch/rewrite" config "url.https://github.com/Acme/widgets.insteadOf" "https://github.com/$OURS"
git init -q "$scratch/pushurl"
git -C "$scratch/pushurl" remote add origin "https://github.com/$OURS"
git -C "$scratch/pushurl" config remote.origin.pushurl "https://github.com/Acme/widgets"
unset GH_REPO GH_HOST

# run <cwd> <command>: the hook's stdout for a Bash payload carrying <command>, run from <cwd>.
run() {
    jq -nc --arg c "$2" --arg d "$1" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' \
        | "$HOOK" 2>&1
}

# expect <ask|deny|none> <cwd> <command>: a deny must give the list route.
expect() {
    local out decision reason
    out=$(run "$2" "$3")
    decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out" 2>/dev/null)
    reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<< "$out" 2>/dev/null)
    if [[ "$1" == none && -z "$out" ]] || [[ "$1" == ask && "$decision" == ask ]] \
            || [[ "$1" == deny && "$decision" == deny && "$reason" == *"as its own Bash call"* ]]; then
        ok "$1 from ${2##*/}: $3"
    else
        bad "$1 from ${2##*/}: $3 -> ${out:-<no output>}"
    fi
}

o="$scratch/ours"
x="$scratch/other"
p="$scratch/plain"

# Ours, by name or by working directory: no decision.
expect none "$x" "gh pr merge 214 --repo $OURS --merge --match-head-commit abc"
expect none "$x" "gh pr merge 214 --repo=$OURS --merge"
expect none "$x" "gh pr merge 214 -R $OURS --merge"
expect none "$x" "gh pr merge 214 -R exampleorg/OURS-repo --merge"
expect none "$x" "gh pr merge 214 -R ExampleOrg/second --merge"
expect none "$x" "gh pr merge 214 --repo github.com/$OURS --merge"
expect none "$x" "gh pr merge https://github.com/$OURS/pull/214 --merge"
expect none "$o" "gh pr merge 214 --merge"
expect none "$o/sub/dir" "gh pr merge 214 --merge"
expect none "$scratch/https" "gh pr merge 214 --merge"
expect none "$o" "gh pr merge 214 --repo $OURS --merge"
expect none "$x" "gh pr -R $OURS merge 214"
expect none "$x" "gh pr --repo=$OURS merge 214 --merge"
expect none "$scratch/both" "gh pr merge 214 --merge"

# Flags or quotes around the subcommand do not hide a merge.
expect ask "$o" "gh pr -R Acme/widgets merge 7"
expect ask "$o" "gh pr --repo=Acme/widgets merge 7"
expect ask "$x" "\"gh\" pr merge 7"
expect ask "$x" "gh \"pr\" 'merge' 7"
expect ask "$x" "g\\h pr merge 7"

# Every remote gh could pick must be listed, and a URL must name github.com itself.
expect ask "$scratch/fork" "gh pr merge 7 --merge"
expect ask "$o" "gh pr merge https://evil.example/$OURS/pull/1"
expect ask "$o" "gh pr merge https://evil.example/x?github.com/$OURS/pull/1"
expect ask "$o" "gh pr merge evil.example/$OURS/pull/1"
expect ask "$o" "gh pr merge 7 --repo evil.example/$OURS"
expect ask "$scratch/rewrite" "gh pr merge 7 --merge"
expect ask "$scratch/pushurl" "gh pr merge 7 --merge"

# Only --repo and a full PR URL name the target; any other reference still leaves the remotes to be checked.
expect ask "$x" "gh pr merge github.com/$OURS --merge"
expect ask "$x" "gh pr merge $OURS.git/x/y --merge"
expect ask "$x" "gh pr merge 7 --body https://github.com/$OURS/pull/1"
expect ask "$x" "gh pr merge -sb https://github.com/$OURS/pull/1"
expect ask "$x" "gh pr merge -sR Acme/widgets 7"
expect ask "$x" "gh pr merge -bR $OURS"
expect ask "$x" "gh pr merge -tR $OURS"
expect ask "$x" "gh pr merge -sbR $OURS"
expect ask "$x" "gh pr merge -qR $OURS 7"
expect none "$x" "gh pr merge -sR $OURS 7"
expect none "$x" "gh pr merge -dmR$OURS 7"
expect none "$x" "gh pr merge 7 -R$OURS -sb body"

# Words split as the shell splits them: a quoted span is one word, and an unquoted # starts a comment.
expect ask "$x" "gh pr merge 7 --body \"x -R $OURS\""
expect ask "$x" "gh pr merge 7 --subject 'see --repo $OURS'"
expect ask "$x" "gh pr merge 7 # -R $OURS"
expect ask "$x" "gh pr merge 7 #--repo=$OURS"
expect ask "$x" "gh pr merge 7 --body \"unterminated -R $OURS"
expect none "$x" "gh pr merge 7 \"-R$OURS\" --subject \"a # b\""
expect none "$x" "gh pr merge 7 -R $OURS --body \"fixes #12\""
expect none "$x" "gh pr merge 7 -R $OURS --subject a#b"
expect ask "$x" "gh pr merge 7"$'\v'"-R $OURS"
expect ask "$x" "gh pr merge 7"$'\r'"-R $OURS"
expect ask "$x" "gh pr merge 7"$'\f'"-R $OURS"
expect none "$x" "gh pr merge 7"$'\t'"-R"$'\t'"$OURS"
long=$(printf 'x%.0s' {1..5000})
expect ask "$x" "gh pr merge 7 -R $OURS --body $long"
expect none "$o" "gh pr merge github.com/$OURS --merge"
expect none "$x" "gh pr merge https://github.com/$OURS/pull/214/files --merge"

# The shell expands an unquoted glob or brace, and a word before gh can redirect it, so neither is judged.
expect ask "$o" "gh pr merge 7 {-R,Acme/widgets}"
expect ask "$o" "gh pr merge 7 -R$OURS ?"
expect ask "$o" "g[h] pr merge 7"
expect ask "$o" "gh pr {merge,} 7"
expect ask "$o" "GIT_DIR=elsewhere gh pr merge 7"
expect ask "$o" "/opt/homebrew/bin/gh pr merge 7"
expect ask "$o" "gh pr {merge,7} -R Acme/widgets"
expect ask "$o" "gh pr {m,7}erge -R Acme/widgets"
expect ask "$o" "{gh,pr} merge 7 -R Acme/widgets"
expect ask "$o" "gh \"pr\" {merge,7} -R Acme/widgets"
expect ask "$o" "/opt/homebrew/bin/?h pr merge 7"
expect ask "$o" "=gh pr merge 7"
expect ask "$o" "gh {p..p}r merge 7 -R Acme/widgets"
expect ask "$o" "gh \$'pr' merge 7 -R Acme/widgets"
expect ask "$o" "gh \$\"pr\" merge 7 -R Acme/widgets"
expect ask "$o" "gh pr \$'merge' 7 -R Acme/widgets"
expect ask "$o" "gh \$'\\x70r' merge 7 -R Acme/widgets"
expect deny "$o" "echo \"a\" && gh \$\"pr\" merge 7"
expect ask "$o" "true # it's"$'\n'"gh \$'pr' merge 7 -R Acme/widgets"
expect ask "$o" "true # it\"s"$'\n'"gh \$\"pr\" merge 7 -R Acme/widgets"
expect ask "$o" "cat <<EOF"$'\n'"it's"$'\n'"EOF"$'\n'"gh \$'pr' merge 7 -R Acme/widgets"
expect none "$o" "echo \$HOME"
expect none "$o" "grep -rln \"enum Field\\b\\|enum Field\$\" src"
expect none "$o" "grep -n 'pr merge\$' notes.txt"
expect none "$o" "echo \"cost: 5\$\" \\\$'x'"
expect none "$o" "gh pr merge 7 --subject \"a [b] {c} *\""
expect none "$o" "ls *.json {a,b}"
expect none "$o" "ls .github/workflows/*.yml"
expect none "$o" "rg prompt src/*.cs"
expect none "$o" "gh api graphql -f query='{ repository(name: \"pr\") { pullRequest(number: 1) { id } } }'"
GH_REPO=Acme/widgets expect ask "$o" "gh pr merge 7 --merge"
GH_HOST=evil.example expect ask "$o" "gh pr merge 7 --repo $OURS"

# Someone else's, or unknown: ask.
expect ask "$o" "gh pr merge 7 --repo Acme/widgets --merge"
expect ask "$o" "gh pr merge 7 -R Acme/widgets"
expect ask "$o" "gh pr merge 7 --repo=Acme/widgets"
expect ask "$o" "gh pr merge https://github.com/Acme/widgets/pull/7"
expect ask "$o" "GH_REPO=Acme/widgets gh pr merge 7"
expect ask "$o" "gh pr merge 7 --repo $OURS-fork"
expect ask "$o" "gh pr merge 7 --repo Evil/$OURS"
expect ask "$o" "gh pr merge 7 --repo $OURS --repo Acme/widgets"
expect ask "$o" "gh pr merge 7 --repo"
expect ask "$o" "gh pr merge 7 --repo \"\$R\""
expect ask "$o" "gh pr merge 7 --repo $OURS --body https://github.com/Acme/widgets/pull/7"
expect ask "$x" "gh pr merge 7 --merge"
expect ask "$p" "gh pr merge 7 --merge"
expect ask "$scratch/missing" "gh pr merge 7 --merge"
expect ask "" "gh pr merge 7 --merge"
expect ask "$x" "gh pr merge"
expect ask "$x" "gh  pr   merge 7"
expect ask "$x" "/opt/homebrew/bin/gh pr merge 7"
expect ask "$x" "env FOO=1 gh pr merge 7"
expect ask "$x" "gh pr merge 7 \$X"
expect ask "$x" "gh pr merge 7 > out.txt"
expect ask "$x" "echo hi | gh pr merge 7"

# A merge in a list is denied with the route to run it alone, so the guard can check it.
expect deny "$x" "echo hi; gh pr merge 7"
expect deny "$o" "cd $x && gh pr merge 7"
expect deny "$o" "git -C $x status; gh pr merge 7"
expect deny "$o" "git status && gh pr merge 1 --squash"
expect deny "$o" "gh pr merge 1"$'\n'"ls"
expect deny "$o" "gh pr merge 1 || true"
# A text heredoc whose notes mention a merge is one command, so it keeps today's ask.
expect ask "$o" "cat > notes.md <<'EOF'"$'\n'"then gh pr merge 7"$'\n'"EOF"

# A comment is not a repository, and a missing or empty list skips no prompt.
expect ask "$x" "gh pr merge 7 -R unprompted/repositories"
GH_MERGE_ASK_REPOS_FILE="$scratch/absent" expect ask "$o" "gh pr merge 214 --repo $OURS --merge"
: > "$scratch/empty"
GH_MERGE_ASK_REPOS_FILE="$scratch/empty" expect ask "$o" "gh pr merge 214 --merge"

# Not a merge: no decision.
expect none "$x" "gh pr view 7"
expect none "$x" "gh pr list --search merge"
expect none "$x" "gh pr view 7 --json merge"
expect none "$x" "gh pr list -R Acme/widgets --search merge"
expect none "$x" "gh pr merged 7"
expect none "$x" "echo gh pr mergex"
expect none "$x" "ls"

# A malformed payload fails closed only for a merge; it never crashes silently.
out=$(printf 'not json' | "$HOOK" 2>&1)
if [[ -z "$out" || "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<< "$out" 2>/dev/null)" == ask ]]; then
    ok "malformed payload: no decision or ask"
else
    bad "malformed payload -> $out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
