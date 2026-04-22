---
name: Workday sandbox validation status
description: PoC test results against Workday sandbox — tracks which API operations work, domain security policies configured, auth policy root cause, and known WQL query issues
type: project
originSessionId: f1a8a1e6-6ff0-406a-9647-c9b4227606b1
---
## PoC Test Results (2026-04-22)

ISU: `ISU_WD_Account_Provisioning`, Tenant: `havenleisureltd` (sandbox impl-services1.wd107)

### Root Cause of 403 S22 Errors (resolved 2026-04-22)

The ISSG `ISSG_WD_Account_Provisioning` was missing an **Authentication Policy** that permits
"API Client" (OAuth2 bearer) authentication. Workday has three independent permission layers for
REST API access:

1. **OAuth scopes** (API client) — functional area access
2. **Domain security policies** (ISSG) — what data the ISU can read/write
3. **Authentication Policy** (ISSG) — how the ISU is allowed to authenticate

We had 1 and 2 correct but layer 3 was never configured. New ISSGs do not automatically inherit
an auth policy permitting API Client authentication. The S22 error is generic and does not
distinguish between missing domain access and missing auth method.

**How proved:** Adding the ISU to `ISSU_Fabric` (which inherited a working auth policy from
production) immediately gave 200 on Workers/Jobs endpoints. No activation required.

**Temporary workaround (in place):** ISU added to `ISSU_Fabric` to inherit its auth policy.

**Permanent fix needed:** Colleague has raised this with the Workday API Authorization chat to
get a proper auth policy configured for `ISSG_WD_Account_Provisioning` directly.

### Current ISSG Domain Security Policies (12 items)

| Domain Security Policy | Access | Functional Area |
|---|---|---|
| Person Data: Personal Data | Get Only | Personal Data |
| Set Up: User Provisioning | Get and Put | System, User Provisioning |
| Workday Query Language | Get Only | System |
| Worker Data: Employment Data | Get Only | Staffing |
| Worker Data: Workers | Get Only | Staffing |
| Workday Accounts | Get Only | System |
| Worker Data: All Positions | Get Only | Staffing |
| Worker Data: Current Staffing Information | Get Only | Staffing |
| Worker Data: Public Worker Reports | Get Only | Staffing |
| Worker Data: Organization Information | Get Only | Staffing |
| Person Data: Name | Get Only | Contact Information |
| Account Provisioning | Get and Put | System |

### OAuth API Client: WD_Account_Provisioning_REST

- Scopes: Public Data, Staffing, System
- Include Workday Owned Scope: **Yes**
- Non-Expiring Refresh Tokens: Yes
- Refresh token regenerated 2026-04-22 after scope changes

### Test Results

| Test | Operation | Protocol | Result | Notes |
|------|-----------|----------|--------|-------|
| OAuth token exchange | `POST /ccx/oauth2/.../token` | REST | PASS | Token issued successfully |
| WQL worker query | `POST /ccx/api/wql/v1/.../data` | REST | FAIL 403 S22 → see auth policy fix | Was auth policy, not token/scope issue |
| WQL dataSources | `GET /ccx/api/wql/v1/.../dataSources` | REST | FAIL 403 S22 → see auth policy fix | Same root cause |
| Get_Workers | SOAP HR endpoint | SOAP | PASS | Returns 206 workers with hire dates |
| Get_Provisioning_Groups | SOAP HR endpoint | SOAP | Not re-tested | Account Provisioning domain now added |
| Put_Provisioning_Group_Assignment | SOAP HR endpoint | SOAP | Not re-tested | Account Provisioning domain now added |

### WQL Query Issues (code changes still needed)

The current query in `WorkdayRestClient.cs:24` is invalid:
```sql
SELECT workdayID, employeeID, fullName, hireDate, provisioningGroup
FROM allActiveEmployees WHERE lastModified >= '...'
```

Problems:
1. `provisioningGroup` is NOT a valid WQL field — provisioning data only available via SOAP
2. `lastModified` is NOT a valid WQL filter — must use `entryMoment` in FROM clause
3. `fullName` is valid (confirmed in official Workday docs)

Correct approach:
```sql
SELECT workdayID, employeeID, fullName, hireDate
FROM allActiveEmployees
```
- Use `FROM allActiveEmployees(entryMoment >= "2026-04-20T00:00:00Z")` for incremental
- Provisioning group assignments must be read/written via SOAP separately
