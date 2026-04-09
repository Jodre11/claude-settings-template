---
name: Paul Waller domain guidance response
description: Paul Waller (Platform) responded 2026-04-07 — use haven-leisure.com subdomain via tf-network repo; also questioned CloudFront vs API Gateway
type: project
---

**2026-03-31:** Sent Teams message to Paul Waller asking for domain guidance.

**2026-04-07:** Paul responded with two points:

1. **Domain:** As an internal tool, it should sit as a subdomain on `haven-leisure.com`. DNS is managed through `HavenEngineering/tf-network` (not platform-terraform). Reference docs: `https://docs-green.tooling.haven-leisure.com/general/platform-domains/#our-v3-set-up` (internal, not externally accessible).

2. **Architecture question:** Platform normally exposes Lambdas through API Gateway, not CloudFront. Asked why we chose CloudFront over API Gateway.

**Why:** This changes the domain approach significantly — haven-leisure.com via tf-network, not haven-stage.com/haven.com via platform-terraform.
**How to apply:**
- platform-terraform #7266 (staging DNS) should be **closed** — wrong repo and wrong domain
- ACM certs in finance-terraform #569 were issued for haven-stage.com and haven.com — these will need to be **re-created** for haven-leisure.com subdomains
- Need to investigate tf-network repo for DNS record management pattern
- Need to draft response to Paul explaining the CloudFront architecture (WASM static files + API on same origin, WAF, origin verify)
