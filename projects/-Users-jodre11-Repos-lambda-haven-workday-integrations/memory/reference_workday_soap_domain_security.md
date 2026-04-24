---
name: Workday SOAP operation to domain security policy mapping
description: How to find which domain security policy governs a Workday SOAP operation using View Security for Securable Item — the authoritative method. Includes the correct domain for Put_Provisioning_Group_Assignment.
type: reference
originSessionId: 642d91eb-2a8b-4818-90e9-6cfc1e017c9d
---

## Finding the domain security policy for a SOAP operation

### The authoritative method: View Security for Securable Item

**This is the only reliable way.** Third-party docs (Okta, Microsoft Entra, SailPoint) and even
Workday's own public API operations index are often incomplete or wrong.

1. In the Workday tenant, search for **"View Security for Securable Item"** (it's a report).
2. For **Securable Item**, type the SOAP operation name (e.g. `Put_Provisioning_Group_Assignment`).
3. The report shows **every domain security policy** that governs the operation, the required
   permission type (Get/Put), and which security groups are currently permitted on each domain.

This report is the single source of truth. It shows domains you would never find by browsing
the domain tree or searching third-party integration docs.

### What doesn't work reliably

- **Workday public SOAP API operations index** — the "Contextual Security" field often says
  "No Information".
- **Third-party integration docs** (Okta, Microsoft Entra) — they document the domains *they*
  need, which may not be the domains *your* operation needs. We wasted hours adding ISSG
  permissions to "Provisioning Group Administration" based on Okta docs — this was the wrong
  domain entirely.
- **Browsing Domain Security Policies for Functional Area** — useful once you know the domain
  name, but you can't discover the right domain this way.

### Granting ISSG access to a domain security policy

Two approaches (from the domain side is more reliable):

- **From the ISSG:** Maintain Permissions for Security Group → add the domain. This sometimes
  returns "No matches found" even when the ISSG type is allowed (confirmed: the ISSG is
  unconstrained and the domain allows unconstrained groups — likely a Workday search/UI bug).
- **From the domain (preferred):** Domain Security Policies for Functional Area → find the domain →
  ellipsis → Edit Permissions → add the ISSG to Integration Permissions (Get/Put) and optionally
  Report/Task Permissions (View/Modify).

Always activate pending security policy changes afterwards.

## Known mapping: Put_Provisioning_Group_Assignment

Confirmed via **View Security for Securable Item** report (2026-04-23):

| Domain Security Policy | Functional Area | Required Permission | Currently Permitted |
|---|---|---|---|
| iLoad Web Services | Implementation | Put | Implementers |
| **External Account Provisioning** | **System** | **Put** | Implementers, ISSG INT002 Azure Active Directory |
| Special OX Web Services | Implementation | Put | Implementers |

The ISSG needs **Get and Put** on **External Account Provisioning** (System functional area).

**Wrong domain (do not use):** "Provisioning Group Administration" — this was suggested by
Okta/Microsoft Entra docs but is NOT one of the domains governing this operation.
