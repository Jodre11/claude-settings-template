#!/usr/bin/env bash
# Tests for the permission rules in settings.json.tmpl. Sourced by tests/run.sh.
# _pp_hit emulates the CLI's Bash-rule matcher as measured: an anchored glob over the whole command in which *
# matches any run of characters (none and spaces included), and a trailing " *" also matches the bare command. A
# rule ending in ":*" is the legacy prefix form instead: a literal prefix with no globbing, so
# "Bash(git *push * :*)" never matched "git push origin :x" (a rule ending ":**" globs). The emulation is exact
# only for single-spaced, unquoted commands, which is all these tables use.

# _pp_patterns <kind>: print the inner pattern of every Bash(...) rule in settings.json.tmpl permissions.<kind>.
_pp_patterns() {
    jq -r --arg k "$1" '.permissions[$k][]? | select(startswith("Bash(") and endswith(")")) | .[5:-1]' \
        "$REPO_ROOT/settings.json.tmpl"
}

# _pp_hit <kind> <command>: exit 0 if any Bash rule in permissions.<kind> matches <command>.
_pp_hit() {
    local pat prefix
    while IFS= read -r pat; do
        if [[ "$pat" == *':*' ]]; then
            prefix="${pat%:*}"
            if [[ "$2" == "$prefix" || "$2" == "$prefix "* ]]; then
                return 0
            fi
            continue
        fi
        # The CLI reads ? literally; a glob reads it as any one character.
        pat="${pat//\?/\\?}"
        # shellcheck disable=SC2053  # the rule is deliberately matched as an unquoted glob
        if [[ "$2" == $pat ]]; then
            return 0
        fi
        # shellcheck disable=SC2053
        if [[ "$pat" == *' *' && "$2 " == $pat ]]; then
            return 0
        fi
    done < <(_pp_patterns "$1")
    return 1
}

# _pp_expect_ask <description> <command>...: every command must hit an ask rule.
_pp_expect_ask() {
    local desc="$1" cmd missing=""
    shift
    for cmd in "$@"; do
        _pp_hit ask "$cmd" || missing+=" [$cmd]"
    done
    assert_equals "" "$missing" "$desc"
}

test_permission_policy_ask_git() {
    _pp_expect_ask "force-push forms prompt, with or without -C and in any flag position" \
        'git push --force' 'git push --force origin main' 'git push --force-with-lease' 'git push -f origin main' \
        'git push -fu origin main' 'git push origin main -f' 'git push origin main --force-if-includes' \
        'git push origin +main' 'git -C /r push --force origin main' 'git -C /r push origin main --force-with-lease' \
        'git -C /r push -f' 'git -C /r push origin +main' 'git -c push.default=current push --force'
    _pp_expect_ask "remote-ref deletion and mirror/prune pushes prompt" \
        'git push origin --delete old' 'git push --delete origin old' 'git push -d origin old' \
        'git push origin -d old' 'git push origin :old' 'git -C /r push origin :old' 'git push --mirror origin' \
        'git push --prune origin' 'git -C /r push origin --delete old'
    _pp_expect_ask "hard reset and forced clean prompt" \
        'git reset --hard' 'git reset --hard HEAD~1' 'git -C /r reset --hard origin/main' 'git reset HEAD~1 --hard' \
        'git reset -q --hard' 'git clean -f' 'git clean -fd' 'git clean -xdf' 'git clean --force' 'git clean -d -f' \
        'git -C /r clean -fdx' 'git clean . -f'
    _pp_expect_ask "forced branch deletion and reset prompt" \
        'git branch -D old' 'git branch old -D' 'git -C /r branch -D old' 'git branch -f main HEAD~1' \
        'git branch --delete --force old' 'git branch -d -f old' 'git branch --force main HEAD~1'
    _pp_expect_ask "history rewrites prompt" 'git filter-repo --path x' 'git filter-branch --tree-filter x HEAD'
    _pp_expect_ask "hook and signing bypasses prompt" \
        'git commit --no-verify -m x' 'git commit -n -m x' 'git commit -nm x' 'git commit -m x -n' \
        'git push --no-verify' 'git -C /r commit --no-verify -F /tmp/m' 'git config core.hooksPath /dev/null' \
        'git -c core.hookspath=/dev/null commit -m x' 'git commit --no-gpg-sign -m x' \
        'git -c commit.gpgsign=false commit -m x' 'git config commit.gpgSign false' \
        'git config --global commit.gpgsign false' 'git -C /r -c tag.gpgSign=0 tag -a v1' \
        'git --config-env=commit.gpgsign=V commit -m x' 'git config set commit.gpgsign false' \
        'git config --unset commit.gpgsign' 'git config --unset-all tag.gpgSign' 'git config unset commit.gpgsign'
}

# A trailing " *" also matches the bare command, so the config-write rules end "gpgsign * *": a space must follow the
# key, and a read that ends at the key stays quiet.
test_permission_policy_signing_reads_do_not_prompt() {
    local cmd hits=""
    for cmd in 'git config --get commit.gpgsign' 'git -C /r config --get rebase.gpgSign' 'git config commit.gpgsign' \
            'git -C /r config --get-regexp commit.gpgsign|gpg.format|user.signingkey' 'git config --list' \
            'git commit -S -m x'; do
        if _pp_hit ask "$cmd"; then
            hits+=" [$cmd]"
        fi
    done
    assert_equals "" "$hits" "reading the signing setting hits no ask rule"
}

# A fork hydrated from an older version of this template holds the broad signing ask rules, which also fired on
# reads; the hydrate must drop them and keep the fork's own ask rules.
test_permission_policy_old_signing_ask_rules_go() {
    local rule tmp
    for rule in 'Bash(git *gpgsign*)' 'Bash(git *gpgSign*)'; do
        assert_equals true "$(_pp_in '.__remove__.entries["permissions.ask"]' "$rule")" \
            "__remove__ drops the live over-matching $rule"
    done
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    cp "$REPO_ROOT/settings.json.tmpl" "$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"ask":["Bash(git *gpgsign*)","Bash(git *gpgSign*)","Bash(local-only *)"]}}' \
        >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "the real tmpl hydrates over a live file holding the old signing ask rules"
    assert_equals '[]' "$(_hy_q "$tmp" '[.permissions.ask[] | select(IN("Bash(git *gpgsign*)",
        "Bash(git *gpgSign*)"))]')" "the over-matching signing ask rules are gone"
    assert_equals true "$(_hy_q "$tmp" '.permissions.ask | index("Bash(local-only *)") != null')" \
        "a local-only ask rule is kept"
    rm -rf "$tmp"
}

test_permission_policy_ask_gh() {
    _pp_expect_ask "merges prompt, by command, REST and GraphQL" \
        'gh pr merge' 'gh pr merge 12 --squash' 'gh pr merge 12 --auto --repo o/r' \
        'gh api -X PUT repos/o/r/pulls/1/merge' 'gh api graphql -f query=mutation{mergePullRequest}' \
        'gh api graphql -f query=mutation{enablePullRequestAutoMerge}'
    _pp_expect_ask "repo delete and edit prompt, by command and REST" \
        'gh repo delete o/r --yes' 'gh repo delete' 'gh repo edit o/r --visibility public' \
        'gh api -X PATCH repos/o/r -f visibility=public' 'gh api repos/o/r -X PATCH -F visibility=private'
    _pp_expect_ask "every gh delete subcommand and DELETE request prompts" \
        'gh release delete v1 --yes' 'gh secret delete X' 'gh run delete 1' 'gh cache delete --all' \
        'gh api -X DELETE repos/o/r' 'gh api repos/o/r -X DELETE' 'gh api -XDELETE repos/o/r' \
        'gh api repos/o/r --method DELETE' 'gh api --method=DELETE repos/o/r' 'gh issue delete 3 --yes' \
        'gh label delete bug' 'gh variable delete X' 'gh release delete-asset v1 a.zip' \
        'gh repo deploy-key delete 1' 'gh project item-delete 1 --owner o --id x'
    _pp_expect_ask "public repo and gist creation prompts" \
        'gh repo create o/r --public --source . --push' 'gh repo create --public o/r' \
        'gh gist create --public notes.md' 'gh gist create notes.md'
    _pp_expect_ask "releases, workflow dispatch, forced syncs, secret writes and deploy keys prompt" \
        'gh release create v1' 'gh release upload v1 a.zip' 'gh release edit v1 --draft=false' \
        'gh workflow run deploy.yml' 'gh run rerun 1' 'gh repo sync o/r --force' 'gh secret set X --body y' \
        'gh repo deploy-key add k.pub'
    _pp_expect_ask "a REST merge prompts with trailing fields, a query or a fragment, and with the endpoint quoted" \
        'gh api -X PUT repos/o/r/pulls/1/merge -f merge_method=squash' 'gh api repos/o/r/pulls/1/merge -X PUT' \
        'gh api -X PUT "repos/o/r/pulls/1/merge"' "gh api -X PUT 'repos/o/r/pulls/1/merge'" \
        'gh api --method PUT "/repos/o/r/pulls/1/merge" -f sha=x' \
        'gh api -X PUT repos/o/r/pulls/1/merge?merge_method=squash' \
        'gh api -X PUT "repos/o/r/pulls/1/merge?merge_method=squash"' 'gh api -X PUT repos/o/r/pulls/1/merge#x'
    _pp_expect_ask "closing a PR with branch deletion prompts" \
        'gh pr close 12 --delete-branch' 'gh pr close --delete-branch 12' 'gh pr close -d 12' 'gh pr close 12 -d' \
        'gh pr close 12 -dc done'
}

test_permission_policy_ask_other() {
    _pp_expect_ask "destructive aws verbs and S3 uploads prompt" \
        'aws ec2 terminate-instances --instance-ids i-1' 'aws s3api delete-object --bucket b --key k' \
        'aws --profile p cloudformation delete-stack --stack-name s' 'aws s3 rm s3://b/k' \
        'aws s3 rm s3://b --recursive' 'aws --profile p s3 rm s3://b/k' 'aws s3 rb s3://b' \
        'aws s3 mv s3://b/a s3://b/c' 'aws s3 sync . s3://b --delete' 'aws s3 cp ./dump.sql s3://b/k' \
        'aws s3 cp - s3://b/k' 'aws s3 cp s3://b/a s3://b/c --acl public-read'
    _pp_expect_ask "package publishing and unlisting prompt" \
        'dotnet nuget push x.nupkg --source s' 'dotnet nuget delete P 1.0.0'
    _pp_expect_ask "tmux kill commands prompt" 'tmux kill-server' 'tmux kill-session -t x' 'tmux -L s kill-server' \
        'tmux -S /tmp/claude-x/s kill-pane -t 1' 'tmux kill-ses -t x'
    _pp_expect_ask "a quoted, escaped or tab-separated tmux kill command prompts" \
        'tmux "kill-server"' "tmux 'kill-session' -t x" 'tmux -L s "kill-server"' 'tmux \kill-server' \
        $'tmux -L s\tkill-window -t 1' 'tmux -L s "kill-pane"'
    _pp_expect_ask "a claude launch that drops hooks or widens permissions prompts" \
        'command claude --dangerously-skip-permissions' 'command claude -p --allow-dangerously-skip-permissions x' \
        'command claude -p --permission-mode bypassPermissions x' \
        'command claude --settings {"disableAllHooks":true} -p x' \
        'command claude --setting-sources project,local -p x' 'command claude --settings /tmp/claude-x/s.json -p x' \
        'command claude -p --allowedTools Bash x' 'command claude -p --allowed-tools Bash x' \
        'command claude -p --permission-prompt-tool mcp__x__y x'
}

test_permission_policy_neighbours_do_not_prompt() {
    local cmd hits=""
    for cmd in \
            'git push' 'git push origin main' 'git push -u origin feature/x' 'git push -u origin fix/x' \
            'git push --follow-tags' 'git -C /r push' 'git -C /r push origin feature-flags' \
            'git push origin HEAD:refs/heads/x' 'git stash push -m wip:x' 'git remote set-url --push template no_push' \
            'git config --get remote.origin.pushurl' 'git fetch --prune' 'git reset --soft HEAD~1' \
            'git reset HEAD file' 'git clean -n' 'git clean -nd' 'git clean --dry-run' 'git branch -d merged' \
            'git branch --show-current' 'git branch --format=%(refname:short)' 'git branch -a' 'git branch feature' \
            'git commit -m x' 'git commit --no-edit' 'git commit --amend --no-edit' \
            'git -C /r commit -F /tmp/claude-x/commit-msg.txt' 'git log --oneline -3' 'git status --porcelain' \
            'git show HEAD:path' 'gh pr view 1' 'gh pr view 1 --comments' 'gh pr create --title t --body-file f' \
            'gh pr list' 'gh repo view o/r' 'gh api repos/o/r/pulls/1/comments' 'gh api repos/o/r --jq .visibility' \
            'gh api graphql -f query=reviewThreads' 'gh run list --commit abc' 'gh run watch 1 --exit-status' \
            'aws s3 ls s3://b/delete-me/' 'aws s3 cp s3://b/k -' 'aws sts get-caller-identity' 'aws sso login' \
            'dotnet nuget list source' 'dotnet build' 'tmux rename-window x' 'tmux set status-style bg=red' \
            'command claude --version' 'command claude plugin marketplace update' \
            'gh pr create --title "chore: delete the stale publish job" --body-file f' \
            'gh pr edit 12 --title "refactor: delete dead code"' 'gh pr comment 12 --body "we can delete this now"' \
            'gh issue create --title "export drops deleted rows" --body-file f' 'aws s3 cp s3://b/k ./local' \
            'aws s3 cp s3://b/p ./local --recursive' 'gh repo create o/r --private' 'gh release view v1' \
            'gh release list' 'gh workflow list' 'gh run view 1' 'gh secret list' 'gh repo sync o/r' \
            'tmux rename-window skill-review' 'tmux new-window -n skill-x' 'tmux select-window -t skill-review' \
            'gh api repos/o/r/pulls/1/comments -f path=docs/merge-guide.md -f body=x' \
            'gh api repos/o/r/pulls/1/comments -f path=src/merged.ts' 'gh pr close 12' \
            'gh pr close 12 --comment done'; do
        if _pp_hit ask "$cmd"; then
            hits+=" [$cmd]"
        fi
    done
    assert_equals "" "$hits" "read-only and routine neighbours hit no ask rule"
}

# _pp_in <jq-path> <rule>: print true if <rule> is an element of the array at <jq-path> in settings.json.tmpl.
_pp_in() {
    jq --arg r "$2" "($1 // []) | index(\$r) != null" "$REPO_ROOT/settings.json.tmpl"
}

# The rules below were dropped from the allow list: their * reaches a write outside the temp dir or a second
# operand, runs code (python3 -c ... x.py), prints a live secret, or sends data out (curl -o / -d). A live
# settings.json keeps an allow rule the tmpl no longer lists, so each is also removed through __remove__.
test_permission_policy_narrowed() {
    local rule
    for rule in 'Bash(read-only commands)' 'Bash(mkdir -p /tmp/claude-*)' 'Bash(rm /tmp/claude-*)' \
            'Bash(rm -f /tmp/claude-*)' 'Bash(rm -rf /tmp/claude-*)' 'Bash(cat /tmp/claude-*)' \
            'Bash(cat * > /tmp/claude-*)' 'Bash(python3 *.py)' 'Bash(aws secretsmanager get-secret-value *)' \
            'Bash(aws ecr get-login-password *)' 'Bash(curl -fsSL *)' 'Bash(curl -s *)' 'Bash(curl -sS *)'; do
        assert_equals false "$(_pp_in .permissions.allow "$rule")" "the tmpl no longer allows $rule"
        assert_equals true "$(_pp_in '.__remove__.entries["permissions.allow"]' "$rule")" \
            "__remove__ drops the live $rule"
    done
    for rule in 'Bash(find *)' 'Bash(cp *)' 'Bash(curl *)' 'Write(//tmp/claude-**)'; do
        assert_equals true "$(_pp_in '.__remove__.entries["permissions.allow"]' "$rule")" \
            "__remove__ drops $rule, which older versions of this template allowed"
    done
    for rule in 'Bash(aws sso *)' 'Bash(aws sts *)' 'Bash(aws s3 ls *)' 'Bash(aws s3 cp *)' \
            'Bash(aws bedrock-runtime *)' 'Bash(chmod +x ~/.claude/hooks/*)' 'Bash(chmod +x ~/.claude/scripts/*)' \
            'Bash(dotnet build *)' 'Bash(dotnet add *)' 'Bash(dotnet run *)' 'Bash(dotnet list *)' \
            'Bash(dotnet nuget *)' 'Bash(dotnet package *)' 'Bash(cargo init *)' 'Bash(cargo check *)' \
            'Bash(cargo clippy *)' 'Bash(cargo fmt *)' 'Bash(cargo build *)' 'Bash(python3 -m *)' \
            'Bash(mktemp -d /tmp/claude-*)'; do
        assert_equals true "$(_pp_in .permissions.allow "$rule")" "the tmpl allows the narrow form $rule"
    done
}

test_permission_policy_narrowed_behaviour() {
    local cmd hits=""
    for cmd in "python3 -c print(1) x.py" 'python3 -c print(1)' 'aws ec2 describe-instances' \
            'aws secretsmanager get-secret-value --secret-id x' 'aws ecr get-login-password' 'chmod 777 /etc/hosts' \
            'chmod +x /tmp/x' 'dotnet tool install -g x' 'dotnet new console' 'dotnet test' 'dotnet restore' \
            'cargo publish' 'cargo install x' 'cargo test' 'curl -s https://example.invalid' \
            'curl -sS -o /tmp/claude-x/f https://example.invalid' 'curl -fsSL https://example.invalid' \
            'rm -rf /tmp/claude-x /home/me' 'mkdir -p /tmp/claude-x /etc/x' 'cat /tmp/claude-x/f' \
            'cat x > /tmp/claude-a/../../etc/y'; do
        if _pp_hit allow "$cmd"; then
            hits+=" [$cmd]"
        fi
    done
    assert_equals "" "$hits" "commands outside the narrow forms are not pre-approved"
    local missing=""
    # shellcheck disable=SC2088  # a literal ~ command string, matched the way the CLI sees it
    for cmd in 'aws s3 ls' 'aws s3 ls s3://b/' 'aws sts get-caller-identity' 'python3 -m pytest' \
            'dotnet build x.sln' 'cargo build' 'chmod +x ~/.claude/hooks/x.sh' 'mktemp -d /tmp/claude-x/y.XXXXXX' \
            'jb inspectcode x.sln' 'ruff check .' 'bash ~/.claude/scripts/handover-path.sh' \
            '~/.claude/scripts/set-session-topic.sh x'; do
        _pp_hit allow "$cmd" || missing+=" [$cmd]"
    done
    assert_equals "" "$missing" "the narrow forms still pre-approve their commands, bare forms included"
}

test_permission_policy_redundant_rules() {
    assert_equals 0 "$(jq '[.permissions.allow[] | select(startswith("Read("))] | length' \
        "$REPO_ROOT/settings.json.tmpl")" "no scoped Read rule sits under the bare Read allow"
    assert_equals 0 "$(jq '[.permissions[][]? | strings | select(endswith(":*)"))] | length' \
        "$REPO_ROOT/settings.json.tmpl")" "no legacy :* rule remains"
    local rule
    for rule in 'Read(~/.claude/commands/**)' 'Read(~/.claude/skills/**)' 'Read(~/.claude/agents/**)' \
            'Read(~/.claude/plugins/**)' 'Bash(jb:*)' 'Bash(ruff:*)' 'Bash(nbqa:*)' 'Bash(trivy:*)' \
            'Bash(eslint:*)' 'Bash(biome:*)' 'Bash(housekeeper-freshness:*)' \
            'Bash(~/.claude/scripts/set-session-topic.sh:*)' 'Bash(~/.claude/scripts/handover-path.sh:*)'; do
        assert_equals true "$(_pp_in '.__remove__.entries["permissions.allow"]' "$rule")" \
            "__remove__ drops the live $rule"
    done
    for rule in 'Bash(jb *)' 'Bash(ruff *)' 'Bash(nbqa *)' 'Bash(trivy *)' 'Bash(eslint *)' 'Bash(biome *)' \
            'Bash(housekeeper-freshness *)' 'Bash(~/.claude/scripts/set-session-topic.sh *)' \
            'Bash(~/.claude/scripts/handover-path.sh *)' 'Bash(bash ~/.claude/scripts/handover-path.sh)'; do
        assert_equals true "$(_pp_in .permissions.allow "$rule")" "the tmpl allows $rule"
    done
}

# _pp_hit escapes ?, which the CLI's matcher reads literally, but reads [ and ( as glob syntax and \ as an escape,
# which the CLI does not, so a rule holding one would be mis-emulated silently.
test_permission_policy_rules_are_emulable() {
    assert_equals "" "$(jq -r '.permissions | [.allow[]?, .ask[]?, .deny[]?][] | select(startswith("Bash("))
        | .[5:-1] | select(test("[\\[(\\\\]"))' "$REPO_ROOT/settings.json.tmpl")" \
        "no Bash rule holds [, ( or a backslash, so _pp_hit matches every rule the way the CLI does"
}

test_permission_policy_remove_is_disjoint() {
    assert_equals '[]' "$(jq -c '. as $t | [($t.__remove__.entries // {}) | to_entries[] | .key as $k | .value[]
        | select(. as $v | ($t | getpath($k | split(".")) // []) | index($v) != null)]' \
        "$REPO_ROOT/settings.json.tmpl")" "no __remove__ entry is also listed by the tmpl itself"
}

test_permission_policy_neighbours_are_preapproved() {
    local cmd missing=""
    for cmd in 'git push' 'git push origin main' 'git -C /r push --dry-run origin main' 'git clean -n' \
            'git reset --soft HEAD~1' 'git branch -d merged' 'git commit -m x' 'gh pr view 1' 'gh repo view o/r' \
            'gh api repos/o/r/pulls/1/comments' 'aws s3 ls s3://b/' 'aws sts get-caller-identity' \
            'dotnet nuget list source' 'tmux rename-window x' 'command claude --version'; do
        _pp_hit allow "$cmd" || missing+=" [$cmd]"
    done
    assert_equals "" "$missing" "the neighbours are pre-approved, so they run without a prompt"
}

# A fork hydrated from an older version of this template: its live settings.json holds the old broad rules and the
# old hook registrations. The hydrate must drop both, keep the fork's own rules, and land the whole ask list.
test_permission_policy_hydrated_over_live_shape() {
    local tmp
    tmp=$(mktemp -d)
    _hy_fixture "$tmp"
    cp "$REPO_ROOT/settings.json.tmpl" "$tmp/settings.json.tmpl"
    printf '%s\n' '{"permissions":{"allow":["Bash(git *)","Bash(read-only commands)","Bash(jb:*)",
        "Bash(mkdir -p /tmp/claude-*)","Bash(cat /tmp/claude-*)","Bash(cat * > /tmp/claude-*)",
        "Bash(rm -rf /tmp/claude-*)","Read(~/.claude/skills/**)","Bash(python3 *.py)",
        "Bash(aws secretsmanager get-secret-value *)","Bash(curl -s *)","Bash(curl -fsSL *)","Bash(find *)",
        "Bash(cp *)","Bash(curl *)","Write(//tmp/claude-**)","Bash(local-only *)"]},
        "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command",
        "command":"~/.claude/hooks/allow-permissions.sh","timeout":5}]},{"matcher":"Agent","hooks":[{"type":"command",
        "command":"~/.claude/hooks/agent-mode-guard.sh","timeout":5}]}],"PostToolUseFailure":[{"hooks":[{
        "type":"command","command":"~/.claude/hooks/api-failure-log.sh","timeout":5}]}]}}' >"$tmp/settings.json"
    _hy_run "$tmp" --force
    assert_equals 0 "$HY_RC" "the real tmpl hydrates over an older fork's live shape"
    assert_equals '[]' "$(_hy_q "$tmp" '[.permissions.allow[] | select(IN("Bash(read-only commands)", "Bash(jb:*)",
        "Bash(mkdir -p /tmp/claude-*)", "Bash(cat /tmp/claude-*)", "Bash(cat * > /tmp/claude-*)",
        "Bash(rm -rf /tmp/claude-*)", "Read(~/.claude/skills/**)", "Bash(python3 *.py)",
        "Bash(aws secretsmanager get-secret-value *)", "Bash(curl -s *)", "Bash(curl -fsSL *)", "Bash(find *)",
        "Bash(cp *)", "Bash(curl *)", "Write(//tmp/claude-**)"))]')" \
        "the live broad and redundant rules go, including an older fork's find/cp/curl"
    assert_equals true "$(_hy_q "$tmp" '.permissions.allow | index("Bash(local-only *)") != null')" \
        "a local-only allow rule is kept"
    assert_equals "$(jq '.permissions.ask | length' "$REPO_ROOT/settings.json.tmpl")" \
        "$(_hy_q "$tmp" '.permissions.ask | length')" "the whole ask list lands on a fork that had none"
    assert_equals "$(jq -S -c '.hooks' "$REPO_ROOT/settings.json.tmpl")" "$(_hy_q "$tmp" '.hooks')" \
        "the old hook registrations are replaced by the tmpl's"
    assert_equals true "$(_hy_q "$tmp" '.permissions.ask | length > 0')" "the fork gains a non-empty ask list"
    assert_equals '[]' "$(_hy_q "$tmp" '[.hooks[][] | .hooks[] | .command
        | select(test("allow-permissions|allow-write-permissions|agent-mode-guard"))]')" \
        "the fork registers none of the three old hook names"
    assert_equals 0 "$(_hy_q "$tmp" '[.hooks.PreToolUse[] | select(.matcher == "Agent")] | length')" \
        "the fork has no Agent guard"
    assert_equals '[]' "$(_hy_q "$tmp" '[.hooks.PostToolUseFailure[]? | .hooks[] | .command
        | select(test("api-failure-log"))]')" "the fork no longer logs failed tool calls raw"
    rm -rf "$tmp"
}
