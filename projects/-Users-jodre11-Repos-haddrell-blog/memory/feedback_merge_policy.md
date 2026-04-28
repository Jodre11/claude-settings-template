---
name: Squash-only merge policy
description: User prefers squash-only merge with PR title+description as commit message and auto-delete branches; configure on every new repo
type: feedback
originSessionId: 8240c80d-9e38-42ea-9750-129ea6a7554c
---
Configure GitHub repos with squash-only merge policy:
- `--enable-squash-merge`
- `--enable-merge-commit=false`
- `--enable-rebase-merge=false`
- `--squash-merge-commit-message=pr-title-description`
- `--delete-branch-on-merge`

**Why:** User said "squash and merge all prs, should be a policy in gh" while reviewing PR #6 on haddrell-blog (which had three commits and a noisy history). They view squash-only as the right default for any repo, not a per-repo decision. Keeps `main` history clean (one commit per PR), preserves the PR description as the durable record, and trims dead branches automatically.

**How to apply:** When starting work in a new GitHub repo (or noticing a repo doesn't have this), run:
```
gh repo edit <owner/repo> \
    --enable-squash-merge \
    --enable-merge-commit=false \
    --enable-rebase-merge=false \
    --squash-merge-commit-message=pr-title-description \
    --delete-branch-on-merge
```
Verify with `gh repo view <owner/repo> --json mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed,deleteBranchOnMerge`. (`squashMergeCommitMessage` isn't exposed in that JSON view but is set by the edit.)

When advising on PR-merging workflow, default to "squash and merge" — never suggest merge commits or rebase merges unless the user explicitly asks.
