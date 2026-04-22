---
name: Workday sandbox validation status
description: PoC test results against Workday sandbox — tracks which API operations work, domain security policies configured, and known WQL query issues
type: project
originSessionId: 600d8b8d-a9d5-4ab7-936a-e343e6ded197
---
## PoC Test Results (2026-04-21)

ISU: `ISU_WD_Account_Provisioning`, Tenant: `havenleisureltd` (sandbox impl-services1.wd107)

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
- **Issue**: Refresh token was generated before scope changes — must regenerate to pick up new scopes

### Test Results

| Test | Operation | Protocol | Result | Notes |
|------|-----------|----------|--------|-------|
| OAuth token exchange | `POST /ccx/oauth2/.../token` | REST | PASS | Token issued successfully |
| WQL worker query | `POST /ccx/api/wql/v1/.../data` | REST | FAIL 403 S22 | Stale refresh token — scopes changed but token not regenerated |
| WQL dataSources | `GET /ccx/api/wql/v1/.../dataSources` | REST | FAIL 403 S22 | Same stale token issue |
| Get_Workers | SOAP HR endpoint | SOAP | PASS | Returns 206 workers with hire dates |
| Get_Provisioning_Groups | SOAP HR endpoint | SOAP | Not re-tested | Previously failed, Account Provisioning domain now added |
| Put_Provisioning_Group_Assignment | SOAP HR endpoint | SOAP | Not re-tested | Account Provisioning domain now added |

### Blocking Issues

1. **Refresh token must be regenerated** — via "Generate Refresh Token for Integrations" in Workday GUI, then update `oauth_refresh_token` in Secrets Manager secret `workday/account-provisioning-credentials`

### WQL Query Issues (code changes needed)

The current query is invalid:
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

**Why:** WQL is a reporting/query layer over Workday data sources. Provisioning groups are not exposed as WQL fields. The architecture needs splitting into WQL reads (worker data) + SOAP writes (provisioning assignments).

**How to apply:** Fix the WQL query in WorkdayRestClient.cs, regenerate refresh token, then re-test.
