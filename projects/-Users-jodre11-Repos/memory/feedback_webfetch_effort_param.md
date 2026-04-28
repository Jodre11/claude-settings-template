---
name: WebFetch effort parameter workaround
description: WebFetch fails when session effort parameter is passed to its internal model (Haiku) — use alternative approaches
type: feedback
originSessionId: 6ade2640-fd18-432f-ab51-e6bd521203f7
---
WebFetch tool fails with "This model does not support the effort parameter" when the session's reasoning effort setting is passed through.

**Why:** WebFetch internally uses a small/fast model (likely Haiku) that does not support the effort parameter. The session-level effort setting gets forwarded and causes a 400 error.

**How to apply:** When WebFetch fails with this error, work around it by:
1. Fetching the page via `curl` in Bash and extracting content with grep/text processing
2. Delegating the fetch to a subagent with `model: "sonnet"` which supports the effort parameter
3. Using search tools to find the information indirectly instead
