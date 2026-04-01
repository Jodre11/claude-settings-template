---
name: Teams message to Paul Waller re custom domains
description: 2026-03-31 Teams message to Paul Waller (Platform team, GitHub: paul-waller) seeking guidance on which domains to use for staging/prod custom domain setup
type: project
---

On 2026-03-31, sent a Teams message to Paul Waller (Platform team representative) asking for guidance on custom domain selection for staging and production CloudFront distributions.

**Key questions asked:**
1. Which domain(s) should we use for staging and production?
2. Is there a self-service option (e.g. delegated subzone in finance-terraform)?
3. Is skipping the staging custom domain an option (default CloudFront domain for staging, custom only for prod)?
4. Minor: staging/platform-dns Terraform state has been locked since June 2025 (lock ID `55906e6b-69be-23aa-e49f-34a51d50e9e9`)

**Context provided:**
- Surveyed available domains: haven.com (prod), haven-stage.com (staging), haven-dev.com (dev), staging.digitaldevs.co.uk (cross-account cert issue), hde.systems (tooling only)
- Security motivation: CloudFront default `*.cloudfront.net` cert can't enforce `minimum_protocol_version = "TLSv1.2_2021"` — Orca flags as medium
- Previously told haven-stage.com may not be appropriate for new services

**Why:** Custom domains are the last piece for closing the TLS 1.2 gap on staging/prod CloudFront distributions.
**How to apply:** Awaiting Paul's response. His guidance will determine which domain we use and whether we proceed with platform-terraform #7266 or take a different approach.
