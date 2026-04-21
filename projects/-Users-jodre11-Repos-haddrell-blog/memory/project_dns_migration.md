---
name: DNS migration to Cloudflare
description: haddrell.co.uk DNS moved from GoDaddy to Cloudflare on 2026-04-17 — original nameservers and rollback info
type: project
originSessionId: 17cf70f6-038d-450f-9895-bd48f11939c5
---
On 2026-04-17, nameservers for `haddrell.co.uk` changed from GoDaddy to Cloudflare.

**Original nameservers (for rollback):**
- `ns75.domaincontrol.com`
- `ns76.domaincontrol.com`

**New nameservers:**
- `diva.ns.cloudflare.com`
- `maciej.ns.cloudflare.com`

**Registrar:** 123-reg.co.uk (not GoDaddy — GoDaddy was delegated via Microsoft Domain Connect)

**Cloudflare account:** Personal account (`christian@haddrell.co.uk`), free plan.

**Why:** Cloudflare's unified Workers platform requires the domain on Cloudflare DNS to bind a custom domain. The old Pages CNAME model no longer exists.

**How to apply:** If email breaks, rollback by changing nameservers back to the GoDaddy pair at 123-reg. GoDaddy still has the original records. SMTP retry windows give ~5 days before any mail is lost.
