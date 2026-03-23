# PR Review Patterns

## Resolved comment threads on GitHub
- GitHub REST API cannot unresolve review comment threads programmatically
- Replying to a resolved/hidden thread will remain hidden and likely be ignored
- If an issue in a resolved thread is still unresolved, create a **new standalone comment** on the current commit instead of replying to the old thread
- Include any additional clarifications/reasoning from the old thread in the new comment so context is self-contained
- The `review-pr` skill now handles this: it fetches thread resolution status via GraphQL (`isResolved`) and adjusts behaviour accordingly

## Copilot/bot review comments
- Check timestamps of bot comments vs subsequent commits — the author may have already addressed them
- Only comment on issues that are still present in the latest code
- Don't reply to resolved conversations unless we want to reopen the issue
