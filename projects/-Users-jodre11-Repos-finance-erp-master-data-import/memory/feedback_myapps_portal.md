---
name: My Apps portal configuration
description: Entra ID app registrations need user-facing display names, homepage URLs, and logos for the My Apps portal
type: feedback
---

Entra ID app registrations need three things for a good My Apps portal experience:

1. **Display names** should be user-facing, not technical identifiers. Convention: `ERPx Master Data Import Tool (Dev)`, `ERPx Master Data Import Tool (Staging)`, `ERPx Master Data Import Tool` (prod — no environment suffix).
2. **Homepage URL** (login_url on service principal) must be set or the My Apps tile won't launch correctly. Set to the custom domain URL for each environment.
3. **Logo** should match the app's browser favicon/icon.

**Why:** Without these, the My Apps portal shows generic names, broken launch links, and default icons. The tf-az-entraid-application module (v1.0.0) doesn't expose `logo_image` or `login_url` — these need manual portal configuration or a module update.

**How to apply:** When creating or updating Entra ID app registrations for this project, ensure all three are configured. For now these are set manually in Azure Portal; a future module update should codify them.