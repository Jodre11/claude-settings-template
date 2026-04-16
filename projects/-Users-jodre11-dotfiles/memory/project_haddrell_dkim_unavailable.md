---
name: haddrell.co.uk DKIM unavailable (M365 Family SKU)
description: DKIM is not customer-configurable on M365 Family personalized email; outgoing mail is not signed under haddrell.co.uk; re-check April 2027
type: project
originSessionId: fcc7259e-7da9-49c1-993c-84e56488eaf0
---
Definitive finding (investigated 2026-04-15): customer-configurable DKIM is **not available** for the Microsoft 365 Personal/Family "personalized email address" SKU. Outgoing mail from haddrell.co.uk via pamx1.hotmail.com is not DKIM-signed under the customer domain. There is no DNS record, UI, or API that changes this.

**Evidence:**
- Microsoft Q&A #4645793 (moderator Prince R, 2024-02-01): no official announcement of DKIM support for personalized domains.
- Microsoft Q&A #4630108 (2024-08-06, unchallenged): Hotmail server is configured to not stamp DKIM signatures for outgoing custom-domain mail.
- Microsoft Q&A #5098608 (Microsoft support Qian, 2021-07): DKIM/DMARC are exclusive to Exchange Online (business).
- No updates since 2023 retirement of new sign-ups. Product is in maintenance, not active development.

**Do not:**
- Publish `selector1._domainkey` / `selector2._domainkey` CNAMEs using the business pattern (`<selector>-<domain-dashes>._domainkey.<tenant>.onmicrosoft.com`) — they would point at nothing.
- Expect the Defender portal (security.microsoft.com) to show this domain — it is consumer SKU, no tenant.

**Verification commands (both should remain empty):**
```
dig +short CNAME selector1._domainkey.haddrell.co.uk
dig +short CNAME selector2._domainkey.haddrell.co.uk
```

If either ever returns a target, Microsoft has either shipped the feature or an unexpected record was added — re-investigate.

**To observe signing behaviour on outgoing mail:** send from a family mailbox to Gmail, open the message, View Original, inspect `Authentication-Results`. Expect `dkim=none` (or `dkim=pass` aligned to outlook.com, not haddrell.co.uk) and `spf=pass`, `dmarc=pass` (once p=none is live).

**Re-check trigger:** Re-evaluate in April 2027 (≥12 months from investigation) or sooner if Microsoft announces consumer DKIM. Canonical places to watch: Microsoft Q&A threads referenced above, Microsoft Tech Community blog.

**Why this matters elsewhere:** this constraint caps the DMARC policy at `p=quarantine` (see `project_haddrell_dmarc_rollout.md`) — reaching `p=reject` would silently kill legitimately forwarded family mail.
