---
name: haddrell.co.uk registrar/DNS/email consolidation
description: Defer consolidating haddrell.co.uk onto a single vendor; wait for Microsoft to deprecate M365 Family custom domain as the natural forcing event
type: project
originSessionId: fcc7259e-7da9-49c1-993c-84e56488eaf0
---
Decision (2026-04-15): do NOT consolidate haddrell.co.uk onto a single registrar/DNS/email vendor yet. Current split is:
- Registrar: 123-reg (~£12–14/yr .co.uk)
- Authoritative DNS: GoDaddy (ns75/76.domaincontrol.com, bundled free via Microsoft Domain Connect)
- Email: Microsoft 365 Family personalized email (grandfathered, consumer SKU, ~5 family mailboxes)

**Why:**
- No duplicate billing — GoDaddy DNS is free, bundled with the M365 Family integration, not separately paid.
- Saving from transferring registrar elsewhere (e.g. Porkbun) is only ~£4–5/yr. Not worth the hassle.
- Consolidating now would break Microsoft's Domain Connect auto-management, putting the customer on the hook for hand-maintaining all MX/SPF/autodiscover/DKIM records. Risk of breaking live family email is high.
- Microsoft has been quietly strangling the M365 Family custom domain feature (new sign-ups closed around 2024, grandfathered only). Full deprecation is likely at some point. That will force an email migration anyway.

**How to apply:**
- If Christian asks again about moving off 123-reg for cost reasons, remind him he is not paying twice.
- If Microsoft announces end-of-life or further restrictions on the M365 Family personalized email feature, that is the forcing event — plan a one-shot migration: email to a dedicated provider (Fastmail/Migadu/Proton), DNS to Cloudflare, registrar to Porkbun or Cloudflare Registrar (if .co.uk is supported by then).
- Until that forcing event arrives, keep the current split and host anything new (e.g. the blog) on subdomains via editable-at-GoDaddy records.
