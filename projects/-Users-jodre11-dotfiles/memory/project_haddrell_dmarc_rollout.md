---
name: haddrell.co.uk DMARC rollout
description: DMARC policy for haddrell.co.uk — SPF-only alignment, stay at p=none indefinitely, never reach p=reject
type: project
originSessionId: fcc7259e-7da9-49c1-993c-84e56488eaf0
---
Domain: haddrell.co.uk (Microsoft 365 Family personalized email, consumer SKU, grandfathered).
Authoritative DNS: GoDaddy (ns75/76.domaincontrol.com) via Microsoft Domain Connect.
Initial DMARC record:
`v=DMARC1; p=none; rua=mailto:christian@haddrell.co.uk; fo=1`

**Hard constraint:** DKIM is not available for this SKU (see `project_haddrell_dkim_unavailable.md`). Alignment is SPF-only. Any mailing list, forwarder, or `.forward` that rewrites MAIL FROM will fail DMARC alignment with no DKIM fallback.

**Policy ladder — cap at p=quarantine:**
1. `p=none` indefinitely until rua aggregate reports (e.g. via dmarcian or Postmark DMARC Digests free tier) show (a) all five family mailboxes routing only via Outlook infrastructure, (b) no forwarded or list-based sending, (c) several weeks of clean pass rates.
2. **Optional cautious next step, months later:** `p=quarantine; pct=10; sp=quarantine`. Raise `pct=` slowly (10 → 25 → 50 → 100) only if rua remains clean. This is the recommended ceiling.
3. **Do NOT reach `p=reject`.** Without DKIM, any forwarded/aliased legitimate family mail is hard-bounced. Cost exceeds anti-spoof benefit at family scale.

**Why cap at quarantine:** SPF-only alignment is fragile. Rejecting misaligned mail means losing real family correspondence via forwarding services (e.g. university aliases, legacy redirections) that the family may not even know is in use. Quarantine-into-spam is recoverable; reject is not.

**Deliverability at family volume (<5,000 msgs/day) is fine without DKIM.** Gmail/Yahoo/Outlook bulk-sender rules (Feb 2024; Outlook enforcement 2025-05-05 with 550 5.7.515) target high-volume senders, not individuals. Expect occasional spam-folder placement on strict receivers, no systematic rejection.

**How to apply:** When Christian asks about tightening DMARC, remind him: quarantine is the ceiling, not reject. Pushing to reject without DKIM will silently delete real mail.
