---
name: Workday Account Provisioning Integration
description: Decisions, sandbox setup state, API findings, AD provisioning flow, and next steps for the account provisioning integration (HavenEngineering/integrations#736)
type: project
---

## Architectural Decisions

New standalone repo for Workday integrations — not within service-finance-erp-pipeline. May grow into a suite (AD, enableAccounts, potentially payroll). Exact repo strategy (monorepo vs repo-per-integration) is an open question on the ticket.

**Why:** Separation of concerns; scope is broader than a single integration.

**How to apply:** Plan for multiple Lambda functions. Each integration gets its own Lambda. Tech stack: .NET 10 / C#, AOT container Lambda on arm64, following the Finance Terraform repo pattern.

New ISU: `ISU_Account_Provisioning` — do not reuse `ISU_IaC_PoC` (had problems).

## How AD Provisioning Currently Works

Discovered 2026-03-31 by investigating HavenEngineering repos:

1. **Workday's built-in AD provisioning connector** creates user accounts directly in on-prem AD (`OU=Workday,OU=Users,OU=AzureSync,DC=bourne-leisure,DC=co,DC=uk`)
2. **PowerShell post-provisioning scripts** on the HRIS VM pick up new accounts and configure them (groups, Exchange mailbox, UPN)
3. **Entra Connect** syncs on-prem AD to Entra ID
4. **MFA script** registers phone via Microsoft Graph

Key repos:
- `modernworkplace/workday-integrations/live/` — the PowerShell scripts (`Invoke-OnboardingWorkdayUser.ps1`, `Invoke-OnboardMFAV2.ps1`, `Invoke-MoveDisabledUsers.ps1`)
- `platform-azure-terraform` — Terraform for HRIS VM (`az-hav-vm-uks-prod-hris-workday-01`) and Entra Connect VM
- `legacy-haven-integrations` — old VS2012 AD integration code (predecessor)

**Critical insight:** No custom code calls `New-ADUser`. Workday's native connector creates the AD account. The connector almost certainly uses provisioning groups as its trigger.

**Our Lambda's role:** Detect workers with upcoming hire dates → set the correct provisioning group flag → Workday's native connector handles the rest.

## Provisioning Groups

Provisioning groups do not exist yet in either sandbox or production. They need to be created as part of the setup.

**Candidate XPath for the field:**
`wd:Worker/wd:Worker_Data/wd:Account_Provisioning_Data/wd:Provisioning_Group_Assignment_Data/wd:Provisioning_Group`

**Pending confirmation (as of 2026-04-08):** Exact field name and whether it has a default value. Awaiting feedback from previous implementers.

**Working assumption:** Default value is "No Access". Lambda switches it to "Network Access" on hire date minus 1 day. Additional provisioning group values may be needed later for maternity, leavers, and other scenarios — rules TBD.

## Sandbox Setup (impl-services1.wd107.myworkday.com, tenant: havenleisureltd)

Completed as of 2026-03-31:

- **ISU:** `ISU_Account_Provisioning` (credentials in user-secrets)
- **ISSG:** `ISSG_Account_Provisioning` (Unconstrained, member: the ISU)
- **OAuth Client:** Account Provisioning (Staffing scope) — Client ID, Secret, Refresh Token in user-secrets
- **Integration System:** Skipped for the spike (not needed for direct SOAP calls)

Domain Security Policies granted to ISSG (all activated and confirmed working):

| Domain Security Policy                    | Access      | Confirmed |
|-------------------------------------------|-------------|-----------|
| Account Provisioning                      | Get         | Yes       |
| External Account Provisioning             | Get and Put | Get only (no groups to Put) |
| Set Up: User Provisioning                 | Get and Put | Likely    |
| Worker Data: Current Staffing Information | Get         | Yes       |
| Worker Data: Public Worker Reports        | Get and Put | Yes       |
| Worker Data: Workers                      | Get         | Yes       |

## API Findings (confirmed 2026-03-31)

- `Get_Provisioning_Groups` on HR SOAP endpoint: **works** (HTTP 200, 0 results — no groups configured)
- `Get_Workers` on HR SOAP endpoint: **works** (10,000+ results with names, hire dates, employment data)
- `Get_Workers` single worker by Employee_ID: **works**
- `Put_Provisioning_Group_Assignment`: **implemented, not yet testable** (no provisioning groups exist)
- REST API has **no provisioning endpoints** — SOAP only for provisioning writes
- `Transaction_Log_Criteria_Data` returns workers with *any* transaction in date range, not specifically new hires. Production will need `Business_Process_Type` filter or WQL with `hireDate` predicate.
- Hire date path: `Worker_Data > Employment_Data > Worker_Status_Data > Hire_Date`
- `Put_Provisioning_Group_Assignment` takes provisioning group as **string name** (not WID)

## Domains We May Still Need (add iteratively if responses miss data)

- Worker Data: Personal Information (Get) — for names
- Worker Data: Employment Information (Get) — for hire dates
- Person Data: Work Contact Information (Get) — for email addresses

## Next Steps

1. Create provisioning groups in sandbox (names TBD)
2. Test `Put_Provisioning_Group_Assignment` once groups exist
3. Resolve open questions on ticket (repo strategy, business logic details, deployment)
4. Write implementation plan
5. Implement the Lambda
