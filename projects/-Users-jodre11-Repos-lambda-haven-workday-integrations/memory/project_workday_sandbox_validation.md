---
name: Workday sandbox validation status
description: PoC test results against Workday sandbox — tracks which API operations work, domain security policies configured, auth issues, and known WQL query issues
type: project
originSessionId: 6788a956-c34a-4742-8036-079485c5a47d
---
## PoC Test Results (updated 2026-04-23)

ISU: `ISU_WD_Account_Provisioning`, Tenant: `havenleisureltd` (sandbox impl-services1.wd107)

### Current Status: WQL GET works, SOAP Put_Provisioning_Group_Assignment — wrong domain fixed, correct domain identified, pending grant

### What Works (confirmed 2026-04-23)

| Endpoint | Status | Notes |
|----------|--------|-------|
| OAuth token exchange | 200 | Token issued, scopes correct |
| WQL dataSources (metadata) | 200 | 63 data sources visible |
| WQL query via **GET** `/data?query=...` | 200 | Confirmed working |
| Workers REST (`/api/v1/.../workers`) | 200 | 11,301 workers returned |
| Staffing REST (`/api/staffing/v6/.../workers`) | 200 | 11,301 workers returned |
| SOAP Get_Workers | 200 | Previously confirmed |

### What Fails

| Endpoint | Status | Notes |
|----------|--------|-------|
| WQL query via **POST** `/data` | 403 S22 | Same query works via GET. Likely Workday maps POST to Modify permission. |
| SOAP Put_Provisioning_Group_Assignment | 500 "task submitted is not authorized" | Root cause identified — see below. |

### SOAP Put_Provisioning_Group_Assignment — Correct Fix (2026-04-23)

**Root cause:** The operation is governed by 3 domain security policies (confirmed via
**View Security for Securable Item** report). Our ISSG has permissions on none of them.

**Authoritative finding (View Security for Securable Item):**

| Domain Security Policy | Functional Area | Required | Currently Permitted |
|---|---|---|---|
| iLoad Web Services | Implementation | Put | Implementers |
| **External Account Provisioning** | **System** | **Put** | Implementers, ISSG INT002 Azure Active Directory |
| Special OX Web Services | Implementation | Put | Implementers |

**What needs to happen:**
1. Add `ISSG_WD_Account_Provisioning` to **External Account Provisioning** domain with Get and Put
   under Integration Permissions (and optionally View/Modify under Report/Task Permissions)
2. Activate Pending Security Policy Changes
3. Retest

**Previous wrong fix:** We added the ISSG to "Provisioning Group Administration" based on Okta/
Microsoft Entra third-party docs. This was the wrong domain — it does not govern
`Put_Provisioning_Group_Assignment` at all. The ISSG permissions on that domain are harmless but
unnecessary.

**Lesson learned:** Always use Workday's own **View Security for Securable Item** report to
identify governing domains. Third-party integration docs are unreliable for this.

### Domain Security Policies (18 items after both additions, confirmed 2026-04-23)

**Report/Task Permissions (View/Modify) — for REST:**

| Domain Security Policy | Access | Functional Area |
|---|---|---|
| Person Data: Personal Data | View Only | Personal Data |
| Set Up: User Provisioning | View and Modify | System, User Provisioning |
| Workday Query Language | View Only | System |
| Worker Data: Employment Data | View Only | Staffing |
| Worker Data: Workers | View Only | Staffing |
| Workday Accounts | View Only | System |
| Worker Data: All Positions | View Only | Staffing |
| Worker Data: Current Staffing Information | View Only | Staffing |
| Worker Data: Public Worker Reports | View Only | Staffing |
| Worker Data: Organization Information | View Only | Staffing |
| Person Data: Name | View Only | Contact Information |
| Account Provisioning | View and Modify | System |
| Manage: All Custom Reports | View and Modify | System |
| Custom Report Administration | View and Modify | System |
| Provisioning Group Administration | View and Modify | System |

**Integration Permissions (Get/Put) — for SOAP:**

| Domain Security Policy | Access | Functional Area |
|---|---|---|
| Set Up: User Provisioning | Get and Put | System, User Provisioning |
| Account Provisioning | Get and Put | System |
| Provisioning Group Administration | Get and Put | System |

**Still needed:** External Account Provisioning with Get and Put under Integration Permissions.

### OAuth API Client: WD_Account_Provisioning_REST

- Scopes: Public Data, Staffing, System
- Include Workday Owned Scope: **Yes**
- Non-Expiring Refresh Tokens: Yes
- Refresh token regenerated 2026-04-23 with ISU correctly selected

### JWT Token State

`act.sub` is present but **empty string**. This does not affect functionality — all working
endpoints return 200 regardless.

### WQL Query — Correct Syntax (confirmed from docs and testing)

```sql
SELECT workdayID, employeeID, fullName, hireDate
FROM allActiveEmployees(entryMoment = "2026-04-20T00:00:00Z")
```
- `entryMoment` is a FROM-clause parameter, not WHERE
- FROM-clause parameters only support `=` operator — `>=` returns 400 Bad Request
- `provisioningGroup` is NOT a WQL field — only available via SOAP
- `fullName` is valid (confirmed)
- For first run (no watermark), omit the parameter: `FROM allActiveEmployees`

### Key Finding: GET vs POST

WQL `GET /data?query=...` works. `POST /data` with same query returns 403. The docs say POST
is for queries over 2,048 characters. Our queries are well under that, so GET is sufficient.
POST may require View and Modify on the WQL domain (currently View Only) — not tested.
