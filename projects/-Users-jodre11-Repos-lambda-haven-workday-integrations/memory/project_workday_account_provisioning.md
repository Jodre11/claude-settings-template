---
name: Workday Account Provisioning Lambda
description: Multi-repo project to build a Lambda that bridges Workday provisioning groups to Entra AD connector, tracked in HavenEngineering/integrations#736
type: project
originSessionId: 600d8b8d-a9d5-4ab7-936a-e343e6ded197
---
Building a .NET 10 AOT Lambda that writes provisioning group values to Workday workers so the Entra connector can provision/disable AD accounts. Two repos:

- **lambda-haven-workday-integrations** — monorepo for Lambda code + shared Workday client library
- **workday-terraform** — Terraform infra (Lambda, ECR, IAM, EventBridge, Secrets Manager, SSM)

**Why:** Entra connector cannot read Workday calculated fields (Microsoft limitation), so it cannot evaluate "hire date within N days". This Lambda bridges the gap by writing a provisioning group value the connector can read.

**How to apply:** All implementation follows the `finance-erp-aot-*` cookie cutter pattern. Design spec lives at `/Users/jodre11/Repos/workday-iac/docs/superpowers/specs/2026-04-16-workday-account-provisioning-design.md`. Tracks HavenEngineering/integrations#736.

## Current State (2026-04-22)

### lambda-haven-workday-integrations
- **PR #2** (`feat/initial-implementation`) — open, CI green, all Copilot review comments addressed, awaiting human review/approval
- Plan Tasks 1–11 and 15 complete, plus Aspire AppHost (deferred item) also done
- Lambda code, tests, CI/CD workflows, Dockerfile, docs all implemented
- **Code changes needed** — WQL query in `WorkdayRestClient.cs:24` is invalid (see architecture redesign below)

### workday-terraform
- **PR #1** (Task 12, scaffolding) — merged
- **PR #2** (Task 13, dev/secrets-manager) — merged
- **PR #3** (Task 14, dev/container-lambdas) — open, CI green, Platform team requested as reviewer. **Blocked on v0.1.0 release image** — ECR only has pre-release tags. Do not merge until release is cut.

### Workday Sandbox Configuration
- ISU: `ISU_WD_Account_Provisioning`, ISSG: `ISSG_WD_Account_Provisioning`
- Tenant: `havenleisureltd` (sandbox `impl-services1.wd107.myworkday.com`)
- OAuth client: `WD_Account_Provisioning_REST` — scopes: Public Data, Staffing, System; Include Workday Owned Scope: Yes
- 12 domain security policies configured and activated (full list in `project_workday_sandbox_validation.md`)
- Credentials in Secrets Manager: `workday/account-provisioning-credentials` (managed by workday-terraform)

### Architecture Redesign Required
The original design assumed WQL could query both worker data and provisioning group assignments. **It cannot.** WQL is a reporting layer — provisioning groups are not exposed as WQL fields. The data flow must split:

1. **WQL (REST/OAuth)** — read worker data: IDs, names, hire dates
2. **SOAP (WS-Security)** — read/write provisioning group assignments

The WQL query also used `WHERE lastModified >= '...'` which is invalid. Incremental querying uses `entryMoment` as a FROM clause parameter. Full details in `reference_workday_wql_documentation.md`.

### Blocking Issues
1. **Stale refresh token** — generated before API client scope changes. Must regenerate via "Generate Refresh Token for Integrations" in Workday GUI, then update Secrets Manager.
2. **WQL query invalid** — `provisioningGroup` and `lastModified` are not valid WQL fields/filters.

### Next Steps (ordered)
1. Regenerate refresh token in Workday GUI → update Secrets Manager
2. Verify WQL access works (minimal query: `SELECT workdayID FROM allWorkers LIMIT 1`)
3. Discover valid field aliases via `GET /dataSources?alias=allActiveEmployees` then `GET /dataSources/{ID}/fields`
4. Fix WQL query in `WorkdayRestClient.cs` — remove `provisioningGroup`, replace `lastModified` with `entryMoment`
5. Re-test SOAP operations (`Get_Provisioning_Groups`, `Put_Provisioning_Group_Assignment`) — now that Account Provisioning domain is granted
6. Redesign handler data flow for split WQL reads + SOAP writes
7. Update `docs/workday-api-setup-guide.md` — correct domain name and add full ISSG policy list
8. Get human review/approval on PR #2, merge, cut v0.1.0 release
9. Merge workday-terraform PR #3, then staging/prod Terraform PRs

### Open Items Requiring Human Input
- WQL field aliases to be confirmed via dataSources API after token regeneration
- Provisioning group names to be created in Workday sandbox for end-to-end testing
- Staging/prod secret values and Terraform modules
