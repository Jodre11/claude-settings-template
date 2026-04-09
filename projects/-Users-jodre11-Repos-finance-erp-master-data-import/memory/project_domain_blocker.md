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

**New approach:**
- Domain: e.g. `master-data-import.haven-leisure.com` (or similar subdomain — TBD)
- DNS managed in: `HavenEngineering/tf-network`
- Reference docs: `https://docs-green.tooling.haven-leisure.com/general/platform-domains/#our-v3-set-up`

**Outstanding question from Paul:** Why CloudFront instead of API Gateway? Need to explain the architecture — WASM static files + API on same origin avoids CORS, plus WAF rate limiting and origin verify.

**Why:** This is the authoritative domain decision from Platform.
**How to apply:** All custom domain work (certs, DNS, CloudFront aliases) must target haven-leisure.com via tf-network instead of the previous haven-stage.com/haven.com approach.
