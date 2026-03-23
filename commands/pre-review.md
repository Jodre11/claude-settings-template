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

### Routing

**Use `code-analysis` (lightweight, single-agent)** when ALL of these are true:
- 5 or fewer files changed
- 150 or fewer total lines changed (insertions + deletions)
- No deletions of non-trivial code blocks (10+ contiguous deleted lines in a single hunk)

**Use `code-review-team` (full specialist team with Opus analysis)** when ANY of these are true:
- More than 5 files changed
- More than 150 total lines changed
- Significant deletions detected (10+ contiguous deleted lines in any hunk)
- The diff touches security-sensitive areas (auth, crypto, input validation, SQL, API endpoints)

Announce which approach you're using and why before starting, e.g.:
> 3 files, 47 lines changed — using lightweight review (code-analysis)

or:

> 12 files, 340 lines changed with significant deletions — using full review team (code-review-team)

Then dispatch the chosen agent with the base branch as its argument.
