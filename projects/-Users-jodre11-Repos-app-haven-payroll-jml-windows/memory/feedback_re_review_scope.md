---
name: Re-review scope rules
description: When re-reviewing a PR after fixes, only comment on (1) our previous bug comments that remain unfixed and (2) new bugs introduced by fix commits. Ignore CoPilot comments. Ignore suggestions/nitpicks. Approve if nothing blocking.
type: feedback
---

When re-reviewing a PR after fix commits:
1. Only flag **our** previous bug comments that were marked resolved but not actually fixed
2. Only flag **new bugs** introduced by the fix commits themselves
3. Ignore CoPilot/other bot comments entirely
4. Don't re-raise issues from the original commit that were already reviewed
5. Suggestions and nitpicks are not worth commenting on in a re-review
6. If issues are non-blocking, approve with comments — the author can't proceed without an approval
7. Comments should be detailed and helpful to avoid ping-pong — explain *why* the fix didn't work, provide options

**Why:** User corrected approach where full review findings were presented on a re-review. Re-reviews should be scoped tightly to avoid noise.

**How to apply:** When `/review-pr` is invoked and there are existing resolved threads from us, diff the fix commits separately, check our bug comments were actually resolved, and only comment on gaps + new issues.
