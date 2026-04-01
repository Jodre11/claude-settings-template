---
name: Domain blocker — haven-stage.com
description: Platform team said haven-stage.com shouldn't be used for new services (2026-03-31), blocking staging custom domain. Prod domain (haven.com) also uncertain.
type: project
---

Platform team (Christian Haddrell) said on Teams that `haven-stage.com` shouldn't be used: "I don't think we are and suppose to use staging" and "we not using staging in platform-terraform". When asked for alternatives, someone pointed to `finance-terraform/staging` — which misses the point since finance-terraform has no Route53 capability (DNS must come from platform-terraform or Production Support).

**Why:** The `staging/platform-dns` module in platform-terraform appears to have been abandoned — state lock stale since June 2025, only `www.haven-stage.com` actively using the domain. Platform team may be consolidating away from it.

**How to apply:**
- PR #7266 (staging DNS) is effectively blocked pending clarification
- A detailed question has been prepared for a specific Platform team member (on holiday as of 2026-03-31)
- Recommended interim path: skip staging custom domain, use default CloudFront domain (`djobvgo2cjjun.cloudfront.net`), proceed with `haven.com` for prod via Production Support ticket
- Domain options analysis: `/Users/jodre11/.claude/plans/encapsulated-drifting-tarjan.md`
- The ACM certs created by finance-terraform #569 for both staging and prod will remain `PENDING_VALIDATION` until DNS validation CNAMEs are created
