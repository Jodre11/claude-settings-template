# Address PR Comments

Examine a GitHub PR for unresolved review comments and address them systematically.

## Input
- PR URL or number: $ARGUMENTS

## Instructions

### 1. Resolve repository and branch context
- Infer `{owner}/{repo}` from the current git remote, or extract from a PR URL if provided.
- Determine the current authenticated user: `gh api user --jq .login`
- Run `git fetch` and check whether the local branch is behind its remote tracking branch. If behind, warn the user and ask whether to proceed — addressing comments on stale code risks merge conflicts.

### 2. Fetch review threads and filter to actionable ones

#### 2a. Get thread resolution state via GraphQL
The REST API does not expose `isResolved`, `isOutdated`, or `isMinimized`. Use GraphQL to get the `databaseId` of the root comment in each thread along with its state:
```bash
gh api graphql -f query='
{
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {number}) {
      reviewThreads(first: 100) {
        totalCount
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          isOutdated
          path
          comments(first: 1) {
            nodes {
              databaseId
              isMinimized
              author { login }
            }
          }
        }
      }
    }
  }
}'
```
- Collect threads where `isResolved == false` AND the root comment `isMinimized == false` AND the root comment author is not the current user. These are the **actionable threads**.
- Also note which actionable threads have `isOutdated == true` — these need special handling in step 4 (the diff position no longer exists, but the concern may still be valid).
- If `pageInfo.hasNextPage == true`, paginate using `after: "{endCursor}"` until all threads are fetched.

#### 2b. Fetch all review comments (paginated)
```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments --paginate
```
**IMPORTANT**: Always use `--paginate`. The default page size is 30; without it, comments beyond page 1 are silently dropped.

#### 2c. Fetch review-level comments
Inline comments are attached to diff lines. Reviewers can also leave feedback in the review body (top-level text when submitting a review). These are a separate entity:
```bash
gh api repos/{owner}/{repo}/pulls/{number}/reviews --paginate
```
Check for non-empty `body` fields on reviews where `state` is not `APPROVED` and `user.login` is not the current user. Include these as additional actionable items (they won't have a `path` or `line` — treat them as general feedback).

### 3. Filter to actionable comments
- From the REST comments (step 2b), keep only root comments (`in_reply_to_id: null`) whose `id` is in the actionable set from step 2a.
- From the review bodies (step 2c), keep non-empty bodies from other users on non-approved reviews.
- Present a summary to the user: **"Found N actionable inline threads (M outdated) and K review-level comments. Proceed?"** Wait for confirmation before continuing. This prevents wasted effort on PRs with many comments where manual triage may be preferred.

### 4. Analyze each actionable comment
- Determine if the concern is valid and accurate
- Categorize: code change needed, documentation needed, or skip with justification
- Consider effort vs value tradeoff
- Prioritize: security > correctness > consistency > style
- For **outdated** threads (flagged in step 2a): check whether the code has already been changed to address the concern. If so, reply noting it's already addressed. If the concern is still conceptually valid despite the diff change, treat it normally.

### 5. Apply code changes for actionable comments
- Read the relevant file if not already read
- Apply the minimal change that addresses the concern
- Prefer documentation/comments for ambiguity, code changes for bugs/correctness
- Apply **all** changes before proceeding to step 6. Do not interleave changes with replies.

### 6. Verify changes
- Run `dotnet build` (or appropriate build command)
- Run tests if available
- If verification fails, fix the issue before proceeding. Do not post replies for changes that don't build or pass tests.

### 7. Commit and push
- Commit changes to the PR branch with a descriptive commit message
- Push to the remote
- Note the commit SHA for use in replies

### 8. Reply to each comment thread
Reply **after** pushing so that references to committed code are accurate.

Create a reply to a review comment:
```bash
gh api repos/{owner}/{repo}/pulls/{number}/comments \
  -X POST -F in_reply_to={comment_id} -F body="Your reply text"
```
- If addressed: explain what was changed, reference the commit if helpful
- If skipped: explain the rationale (e.g., "dev-only code", "implementation detail", "low value")
- Do NOT resolve/dismiss comments — leave that decision to the developer

**NOTE**: Do NOT use the `/comments/{id}/replies` sub-resource endpoint — it can return 200 but silently fail to persist the reply. Always use `POST /comments` with the `in_reply_to` field as shown above.

### 9. Summarize
- Present a table of all actionable comments showing: file, issue, action taken, outdated?

## Notes
- For own PRs, this is pre-review quality improvement before public scrutiny
- A PR may have multiple bot reviews (e.g., Copilot re-reviews after new commits) — handle all of them
- Each API reply creates a separate review card on the Conversation tab; this is normal GitHub behaviour

## `gh --jq` pitfalls
`gh` uses `gojq` (Go jq), which does **not** support `!=`. The `!` is also mangled by zsh shell escaping. Use the `| not` idiom instead:
```jq
# WRONG — will error or silently break:
select(.state != "APPROVED")

# CORRECT:
select(.state == "APPROVED" | not)
```
Apply this to all `--jq` filters used in the steps above.
