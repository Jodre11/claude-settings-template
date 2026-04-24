---
name: Verify Workday security in the tenant, not external docs
description: When multiple domain security policies are candidates, verify in the Workday tenant rather than relying on third-party docs to choose between them
type: feedback
originSessionId: 642d91eb-2a8b-4818-90e9-6cfc1e017c9d
---

When identifying which Workday domain security policy to grant, always verify using the tenant's own "View Security for Securable Item" report rather than third-party integration docs.

**Why:** External Account Provisioning was identified as a candidate domain early in the investigation, but I steered us towards Provisioning Group Administration based on Okta/Microsoft Entra docs. This was the wrong domain entirely and cost hours of debugging. The tenant's own security metadata was the authoritative source all along.

**How to apply:** When there are multiple plausible domain security policies, don't use external documentation to choose between them. Run "View Security for Securable Item" in the tenant first — it takes 30 seconds and gives a definitive answer. Only fall back to external docs if tenant access isn't available.
