---
description: "Analyze local changes before creating a PR"
argument-hint: "[base-branch]"
---
Before analyzing, run `git fetch` and check whether the current branch is behind its remote tracking branch. If local is behind remote, warn me and ask whether to proceed — reviewing stale code may be wasted effort.

## Choose review approach

Determine the base branch using these steps (in order):
1. If `$ARGUMENTS` is provided and non-empty, use it as the base branch
2. `gh pr view --json baseRefName -q .baseRefName 2>/dev/null`
3. `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||'`
4. Fall back to `main`

Then measure the diff:
- `git diff $BASE...HEAD --stat` to get the summary
- Count the number of changed files and total lines changed (insertions + deletions)

Follow the shared agent team review instructions in `~/.claude/includes/agent-team-review.md`.
