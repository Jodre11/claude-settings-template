---
name: Workday Account Provisioning Integration
description: Decisions, sandbox setup state, API findings, AD provisioning flow, and next steps for the account provisioning integration (HavenEngineering/integrations#736)
type: project
originSessionId: f308e453-e6f2-46fa-be39-0871d7185713
---
## Core Problem (the whole point of this work)

The Entra provisioning app (Workday-to-AD) **cannot read Workday calculated fields or integration system attributes** — this is a [known Microsoft limitation](https://learn.microsoft.com/en-us/entra/identity/app-provisioning/hr-attribute-retrieval-issues#issue-fetching-workday-calculated-fields). This means Entra cannot evaluate derived logic (e.g. "is hire date within N days?") to decide *when* to provision. The result is premature provisioning — all workers get AD accounts immediately, weeks or months before their start date.

## Solution: Lambda + Provisioning Groups as Data Bridge

A scheduled Lambda reads workers from Workday, evaluates hire date proximity, and writes a provisioning group assignment via SOAP when the worker is within the provisioning window (default: hire date minus 1 day).

**Provisioning groups have no intrinsic business meaning here.** They are purely a data bridge — one of the few writable fields that Entra *can* read. The actual time-gate logic lives entirely in the Lambda; the provisioning group is just the delivery mechanism to surface the Lambda's decision to Entra.

The Entra provisioning app then picks up the group assignment during its own sync cycle and uses it in scoping filters to provision the AD account at the right time.

**Two documented workaround mechanisms:**
- **Provisioning groups** — tested and confirmed working. Current frontrunner.
- **Custom IDs** — alternative option, not yet tested. Either serves the same purpose.

Decision on which mechanism to use is still open.

## How AD Provisioning Currently Works

Discovered 2026-03-31 by investigating HavenEngineering repos:

1. **Microsoft Entra provisioning app** (Workday-to-AD) calls `Get_Workers` over SOAP, reads worker attributes, and creates/updates user accounts in on-prem AD (`OU=Workday,OU=Users,OU=AzureSync,DC=bourne-leisure,DC=co,DC=uk`)
2. **PowerShell post-provisioning scripts** on the HRIS VM pick up new accounts and configure them (groups, Exchange mailbox, UPN)
3. **Entra Connect** syncs on-prem AD to Entra ID
4. **MFA script** registers phone via Microsoft Graph

Key repos:
- `modernworkplace/workday-integrations/live/` — the PowerShell scripts (`Invoke-OnboardingWorkdayUser.ps1`, `Invoke-OnboardMFAV2.ps1`, `Invoke-MoveDisabledUsers.ps1`)
- `platform-azure-terraform` — Terraform for HRIS VM (`az-hav-vm-uks-prod-hris-workday-01`) and Entra Connect VM
- `legacy-haven-integrations` — old VS2012 AD integration code (predecessor)

## Provisioning Groups / Custom IDs

Provisioning groups do not exist yet in either sandbox or production. They need to be created as part of the setup.

**Candidate XPath for the field:**
`wd:Worker/wd:Worker_Data/wd:Account_Provisioning_Data/wd:Provisioning_Group_Assignment_Data/wd:Provisioning_Group`

**Pending confirmation (as of 2026-04-08):** Exact field name and whether it has a default value. Awaiting feedback from previous implementers.

**Working assumption:** Default value is "No Access". Lambda switches it to "Network Access" on hire date minus 1 day. Additional provisioning group values may be needed later for maternity, leavers, and other scenarios — rules TBD.

## Repo Situation

All spike/PoC work so far has been done in `workday-iac` — a repo originally created for a different purpose (Workday Integration-as-Code). Christian hijacked it because it had useful SOAP client code. **This repo is not the long-term home.** The work needs to move into a new standalone repo for the account provisioning Lambda.

**Why:** `workday-iac` was for general Workday integration system management; the account provisioning Lambda is a distinct product with its own deployment lifecycle.

**How to apply:** When moving to implementation, create a new repo. The PoC code in `workday-iac` is reference material, not a starting point to build on in-place.

## Architectural Decisions (confirmed 2026-04-16)

- **Monorepo**: `lambda-haven-workday-integrations` (HavenEngineering/platform-github#1035)
- **Terraform**: `workday-terraform` (HavenEngineering/platform-github#1036)
- **Product tag**: `workday` — pending org owner adding the custom property value. Message sent to John Hegarty.
- **Cookie cutter**: `finance-erp-aot-project-code-sync` in `lambda-finance-erp` and `finance-terraform` patterns
- **Shared library**: `Haven.Workday.Client` — SOAP + REST/OAuth client, shared across Lambdas
- **Auth**: OAuth for REST/WQL reads, SOAP WS-Security for provisioning writes only
- **Secrets**: Strongbox in `workday-terraform` → Secrets Manager → Lambda reads at runtime
- **Environments**: local (Aspire + MCP) / dev / staging / prod. Dev/staging → Workday sandbox, prod → production.
- **Schedule**: EventBridge cron, configurable per environment. High-water-mark in SSM for incremental polling.
- **Observability**: OTel sidecar extension → Datadog
- **Workday has no webhooks** — polling is the only option (confirmed via research 2026-04-16)
- **Design spec**: `workday-iac/docs/superpowers/specs/2026-04-16-workday-account-provisioning-design.md`

New ISU: `ISU_Account_Provisioning` — do not reuse `ISU_IaC_PoC` (had problems).

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

## Next Steps (updated 2026-04-16)

1. Get `workday` product custom property added by org owner (John Hegarty)
2. Get platform-github PRs #1035 and #1036 approved and applied
3. Create provisioning groups in sandbox (names TBD — "No Access", "Network Access" are working assumptions)
4. Test `Put_Provisioning_Group_Assignment` once groups exist
5. Write implementation plan from design spec
6. Implement the Lambda following the cookie-cutter pattern
