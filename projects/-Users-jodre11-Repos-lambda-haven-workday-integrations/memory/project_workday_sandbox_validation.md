---
name: Workday sandbox validation status
description: Sandbox validation complete — all API operations confirmed working, SOAP writes succeeding, ~11K employees processed
type: project
originSessionId: c80bfa75-056b-4ca9-bcf5-d50ebf56f239
---
## Validation Results (updated 2026-04-24)

ISU: `ISU_WD_Account_Provisioning`, Tenant: `havenleisureltd` (sandbox impl-services1.wd107)

### Status: All Operations Working

| Endpoint | Status | Notes |
|----------|--------|-------|
| OAuth token exchange | 200 | Token issued, scopes correct |
| WQL dataSources (metadata) | 200 | 63 data sources visible |
| WQL query via **GET** `/data?query=...` | 200 | Confirmed working, pagination working (10K page size) |
| WQL watermark query (`entryMoment`) | 200 | FROM-clause parameter, `=` operator only |
| WQL hire-date window query (`WHERE hireDate`) | 200 | `>=` and `<=` operators work in WHERE clause |
| Workers REST | 200 | 11,301 workers returned |
| Staffing REST | 200 | 11,301 workers returned |
| SOAP `Put_Provisioning_Group_Assignment` | **200** | All ~11K calls succeeded, zero failures |

### What Still Fails

| Endpoint | Status | Notes |
|----------|--------|-------|
| WQL query via **POST** `/data` | 403 S22 | Same query works via GET. Likely maps to Modify permission. |

### SOAP — Fixed and Working (2026-04-24)

External Account Provisioning domain was activated. All SOAP writes now succeed.

**Authoritative domains (View Security for Securable Item):**

| Domain Security Policy | Functional Area | Required | Status |
|---|---|---|---|
| iLoad Web Services | Implementation | Put | Not needed (Implementers only) |
| **External Account Provisioning** | **System** | **Put** | **Granted and activated** |
| Special OX Web Services | Implementation | Put | Not needed (Implementers only) |

### Domain Security Policies (18 configured)

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
| External Account Provisioning | Get and Put | System |

**Note:** "Provisioning Group Administration" is unnecessary — harmless but should be removed during minimal permissions audit.

### OAuth API Client: WD_Account_Provisioning_REST

- Scopes: Public Data, Staffing, System
- Include Workday Owned Scope: **Yes**
- Non-Expiring Refresh Tokens: Yes
- Refresh token regenerated 2026-04-23

### WQL — Confirmed Syntax

```sql
-- Watermark query (FROM-clause parameter, = only)
SELECT workdayID, employeeID, fullName, hireDate
FROM allActiveEmployees(entryMoment = "2026-04-20T00:00:00Z")

-- First run (no watermark)
SELECT workdayID, employeeID, fullName, hireDate FROM allActiveEmployees

-- Hire-date window query (WHERE clause, >= and <= work)
SELECT workdayID, employeeID, fullName, hireDate
FROM allActiveEmployees
WHERE hireDate >= "2026-04-23" AND hireDate <= "2026-04-25"
```

- `entryMoment` only supports `=` in FROM-clause — `>=` returns 400
- `provisioningGroup` is NOT a WQL field — only available via SOAP
- GET only — POST returns 403
