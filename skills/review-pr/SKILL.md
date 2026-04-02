---
name: review-pr
description: Review a GitHub pull request with inline comments
argument-hint: "[pr-number-or-url]"
---

# PR Review Workflow

Review the pull request specified by $ARGUMENTS.

## Step 1: Gather PR Information

```bash
gh pr view $ARGUMENTS --json title,body,author,state,baseRefName,headRefName,additions,deletions,changedFiles,commits
gh pr diff $ARGUMENTS
gh api repos/{owner}/{repo}/pulls/{pr}/comments --jq '.[] | {id, path, body: .body[0:150], in_reply_to_id}'
gh api graphql -f query='query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        nodes {
          isResolved
          comments(first: 10) {
            nodes {
              databaseId
              path
              body
              author { login }
            }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | {isResolved, comments: [.comments.nodes[] | {id: .databaseId, author: .author.login, path: .path, body: .body[0:120]}]}'
```

The third command fetches existing review comments to avoid duplication.
The fourth command fetches the resolution status and **all replies** for each review thread via GraphQL. Read author replies on resolved threads carefully — the author may have already addressed the concern.

## Step 2: Analyze Changes

### Choose review approach

From the PR metadata gathered in Step 1, check additions, deletions, and changedFiles.

**Use `code-analysis` agent (lightweight)** when ALL of these are true:
- 5 or fewer files changed
- 150 or fewer total lines changed (additions + deletions)
- No deletions of non-trivial code blocks (10+ contiguous deleted lines in a single hunk)

**Use agent team review (full specialist team in tmux panes)** when ANY of these are true:
- More than 5 files changed
- More than 150 total lines changed
- Significant deletions detected (10+ contiguous deleted lines in any hunk)
- The diff touches security-sensitive areas (auth, crypto, input validation, SQL, API endpoints)

For the agent team path: do NOT use the `code-review-team` agent or the Agent tool.
Instead, create a team of teammates in separate tmux panes using the existing reviewer
agent definitions (security-reviewer, correctness-reviewer, consistency-reviewer,
style-reviewer, archaeology-reviewer, reuse-reviewer, efficiency-reviewer, and
jbinspect-reviewer if C# files are in the diff). Each teammate runs autonomously in
standalone mode. Instruct each to write findings to
`/tmp/claude-{session_name}/review-{reviewer-name}.md`. Wait for ALL teammates to
finish before starting synthesis — jbinspect-reviewer takes longer because
`jb inspectcode` must load and analyse the full .NET solution. JetBrains InspectCode
findings are 100% confidence (static analysis tooling); classify severity from the
output: ERROR → Critical, WARNING → Important, SUGGESTION → Suggestion. Then read the
reports and synthesize: cross-reference findings with your own independent analysis,
classify as Consensus/Contested/Dismissed/Opus-only, and format with sequential
numbering and Opus assessments (see `/pre-review` for the full output format).
Then continue with the additional checks and Step 3 below.

For the lightweight path: pass the PR's base branch as the argument to `code-analysis`.

### Additional checks (regardless of which agent was used)

After the review agent reports back, also consider these PR-specific concerns that the agents may not cover:
- Deleted test files — what coverage is lost?
- Changed configuration files — are paths/settings appropriate for all developers?
- New interfaces/classes — do names avoid collisions with common libraries?

## Step 3: Plan Comments

Before adding comments, cross-reference findings against existing comments from other reviewers.

**Handling existing comments — check resolution status first:**

Resolved threads are hidden on the PR conversation page. Replying to a resolved thread will not make it visible again, so replies to resolved threads will likely be ignored by the author.

**Resolved threads:**
- **If the underlying issue has been fixed**: Do nothing — the thread was correctly resolved.
- **If the underlying issue is still present**: Do NOT reply to the resolved thread. Instead, create a **new standalone comment** on the current head commit at the relevant line. Include full context and reasoning in the new comment since the old thread is hidden.
- **If the existing comment was inaccurate but the thread is resolved**: Do nothing — there is no value in correcting hidden feedback that has already been dismissed.

**Open (unresolved) threads:**
- **If an existing comment covers the same point**: Do NOT create a duplicate. Instead, reply to the existing thread if you have supporting evidence, additional context, or a different perspective.
- **If you agree with an existing comment**: Reply with supporting information (e.g., "Agreed - this also affects X and Y")
- **If you disagree or the comment is inaccurate**: Reply with a respectful contradiction explaining your reasoning. It is important to correct misleading feedback so the author isn't sent on a wild goose chase.
- **If the point is already well-covered**: Skip it entirely

**IMPORTANT:** Always check open comments for accuracy. Inaccurate or misleading comments must be disputed - do not let incorrect feedback stand unchallenged.

Create a summary table of findings, noting which are new vs replies:

| # | File | Type | Action | Summary |
|---|------|------|--------|---------|
| 1 | file.cs | Issue | New comment | Brief description |
| 2 | other.cs | Suggestion | Reply to #123 (open) | Supporting evidence |
| 3 | foo.cs | Issue | New comment (resolved thread still relevant) | Re-raise issue from resolved thread #456 |

Present this to the user and ask if they want to proceed.

## Step 4: Re-check PR State Before Posting

There may be a significant delay between gathering PR information (Step 1) and posting comments (now). The author or other reviewers may have replied, resolved threads, or pushed new commits in the meantime.

**Before posting any comments or submitting a review**, re-fetch:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments --jq '.[] | {id, path, body: .body[0:150], in_reply_to_id}'
gh api graphql -f query='query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        nodes {
          isResolved
          comments(first: 10) {
            nodes {
              databaseId
              path
              body
              author { login }
            }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | {isResolved, comments: [.comments.nodes[] | {id: .databaseId, author: .author.login, body: .body[0:120]}]}'
gh pr view $ARGUMENTS --json headRefOid -q '.headRefOid'
```

Compare against Step 1 data:
- **Threads now resolved that were open before**: Check the author's reply — they may have addressed the concern. Drop any planned replies to these threads.
- **New commits pushed**: Re-fetch the diff and re-evaluate findings. The head SHA for comment attachment may have changed.
- **New comments added**: Adjust planned comments to avoid duplicates or stale feedback.

If the plan changes materially, present the updated findings table to the user before proceeding.

## Step 5: Add Inline Comments

**IMPORTANT:** Only reply to **open (unresolved)** comment threads. Never reply to resolved threads — replies to resolved threads remain hidden and will be ignored. If a resolved thread contains an issue that is still present in the code, create a new standalone comment instead.

**For new comments**, attach to a specific line to show the code hunk context:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --method POST \
  -f commit_id='{head_sha}' \
  -f path='{file_path}' \
  -F line={line_number} \
  -f side='RIGHT' \
  -f body='{comment_body}'
```

Note: Use `-F` (not `-f`) for the `line` parameter to pass it as an integer.

**For replies to existing comments**, use `in_reply_to` with the same line positioning:

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --method POST \
  -f commit_id='{head_sha}' \
  -f path='{file_path}' \
  -F line={line_number} \
  -f side='RIGHT' \
  -f body='{reply_body}' \
  -F in_reply_to={existing_comment_id}
```

**Important:**
- Each comment must be a separate API call (enables independent resolution)
- Always attach comments to a specific line number to show the diff hunk context
- Use `-F` for integer parameters (`line`, `in_reply_to`)
- Use `in_reply_to` to add to existing threads - do NOT create duplicates
- Do NOT copy existing code into comments - the line attachment provides the code context
- Keep comments concise and actionable
- Prefix optional suggestions with `(optional)` or `(nitpick)`

**Tone:** Comments represent the user publicly. Be polite, suggestive, and requesting:
- Use "Consider...", "Would it be worth...", "Could we...", "It might be better to..."
- Avoid directive language like "You should...", "Change this to...", "This is wrong"
- Thank the author for good patterns or improvements where appropriate
- Frame issues as questions or suggestions, not demands

## Comment Format Guidelines

**Existing code**: Reference via file/hunk attachment - do NOT copy into comment body.

**Suggested fixes**: Include code examples showing what to change TO.

Good comment:
```
This path appears to be specific to a local development environment. Consider reverting to:
\`\`\`json
"commandLineArgs": "-fs NTFS -cf SourceData/TestingConfig/testConfig.json -e Local",
\`\`\`
```

Bad comment (copies existing code):
```
This code:
\`\`\`json
"commandLineArgs": "-fs NTFS -cf /LocalHavenBucket/..."
\`\`\`
Should be changed to...
```

The file attachment provides the link to the existing code - only include the suggested replacement.

## Step 6: Submit Review Verdict

For complex PRs (many files, large changes, or new functionality), include a **top-level review comment** that:
1. **Acknowledges the good**: Brief praise for what the PR does well (architecture, patterns, improvements)
2. **Summarizes concerns**: High-level overview of the issues raised in inline comments
3. **Justifies the verdict**: Explain why you're approving, requesting changes, or just commenting

This is especially important for REQUEST_CHANGES - the author deserves context on why the PR is blocked.

Ask the user which review action to take:

| Action | When to use |
|--------|-------------|
| **APPROVE** | Changes are acceptable; any comments are minor suggestions or nitpicks |
| **REQUEST_CHANGES** | Blocking issues exist that must be addressed before merge |
| **COMMENT** | Feedback provided without blocking; defer decision to others |

Submit the review with:

```bash
gh pr review $ARGUMENTS --approve --body "Review summary here"
# or
gh pr review $ARGUMENTS --request-changes --body "Review summary here"
# or
gh pr review $ARGUMENTS --comment --body "Review summary here"
```

**Review body guidelines:**
- Summarize key findings (1-3 sentences)
- Reference the number of inline comments added
- For APPROVE: note any optional suggestions worth considering
- For REQUEST_CHANGES: clearly state what must be addressed
- Keep it concise - details are in the inline comments

## Step 7: Summarize

After submitting, provide the user with:
- Review action taken (approved/requested changes/commented)
- Number of inline comments added
- Link to the PR
