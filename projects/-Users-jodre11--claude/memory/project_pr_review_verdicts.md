---
name: PR review verdict policy
description: Three-tier PR review outcome model — approve-with-comments for nitpicks, request-changes for anything substantive, avoid bare comment
type: project
originSessionId: 56b87ff9-a280-4409-b850-e3c0ec851993
---
PR reviews should use two effective verdicts, not three:

- **Approve** (with comments) — for nitpicks and suggestions only
- **Request changes** — for anything beyond a nitpick

The bare "comment" verdict (no approval, no request-changes) should not be used. If there's nothing worth requesting changes on, approve it.

**Why:** Bare comment creates ambiguity — the author doesn't know if they're blocked. Two clear signals are better than three ambiguous ones.

**How to apply:** When the review-pr skill produces its verdict, map findings to these two outcomes. Consider refining the skill to enforce this policy.
