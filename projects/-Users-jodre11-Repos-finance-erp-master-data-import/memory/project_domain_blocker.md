---
name: Domain decision — haven-leisure.com via tf-network
description: Paul Waller confirmed haven-leisure.com for internal tools, managed in tf-network repo. Replaces earlier haven-stage.com/haven.com approach.
type: project
---

**Resolved 2026-04-07:** Paul Waller confirmed the domain should be a subdomain of `haven-leisure.com`, managed through `HavenEngineering/tf-network`.

**Impact on existing work:**
- platform-terraform #7266 (haven-stage.com staging DNS) — should be **closed**, wrong repo and domain
- finance-terraform #569 ACM certs — issued for `erpx-master-data-import.haven-stage.com` and `erpx-master-data-import.haven.com` — need **re-creating** for `*.haven-leisure.com` subdomains
- finance-terraform CDN modules' `enable_custom_domain` toggle — domain/cert ARN values will change

**Fully resolved 2026-04-08.** Custom domains active in all three environments:
- `master-data-import.dev.haven-leisure.com`
- `master-data-import.staging.haven-leisure.com`
- `master-data-import.prod.haven-leisure.com`

DNS zones are in platform-terraform (`{env}/platform-dns/`), not tf-network. Wildcard ACM certs (`*.{env}.haven-leisure.com`) in `{env}/platform-k8s/acm.tf`.

**Why:** This is the authoritative domain decision from Platform (Paul Waller).
**How to apply:** All custom domain work targets `haven-leisure.com`. DNS records for CloudFront aliases go in `{env}/platform-dns/dns.tf`.
