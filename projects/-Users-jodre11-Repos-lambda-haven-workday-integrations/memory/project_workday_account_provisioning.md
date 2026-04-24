---
name: Workday Account Provisioning Lambda
description: Multi-repo project to build a Lambda that bridges Workday provisioning groups to Entra AD connector, tracked in HavenEngineering/integrations#736
type: project
originSessionId: 6788a956-c34a-4742-8036-079485c5a47d
---
Building a .NET 10 AOT Lambda that writes provisioning group values to Workday workers so the
Entra connector can provision/disable AD accounts. Two repos:

- **lambda-haven-workday-integrations** — monorepo for Lambda code + shared Workday client library
- **workday-terraform** — Terraform infra (Lambda, ECR, IAM, EventBridge, Secrets Manager, SSM)

**Why:** Entra connector cannot read Workday calculated fields (Microsoft limitation), so it
cannot evaluate "hire date within N days". This Lambda bridges the gap by writing a provisioning
group value the connector can read.

**How to apply:** All implementation follows the `finance-erp-aot-*` cookie cutter pattern. Design
spec lives at `/Users/jodre11/Repos/workday-iac/docs/superpowers/specs/2026-04-16-workday-account-provisioning-design.md`.
Tracks HavenEngineering/integrations#736.

## Current State (2026-04-23)

### lambda-haven-workday-integrations
- **Branch:** `feat/initial-implementation`, pushed, CI should be green
- **POST→GET fix:** committed — WQL queries now use GET, handler always-writes pattern
- **Code quality pass complete:** 29 tests passing, 0 build warnings, 0 InspectCode issues at
  HINT severity (bar 2 false-positive MA0038 on C# 14 extension block — deprecated analyser)
- **Coverage:** ~90% method / ~80% branch — includes DI integration tests, caching tests, null
  hire date, multi-worker, token reuse, default options
- **C# 14 features used:** extension blocks in ServiceCollectionExtensions.cs
- **editorconfig:** trailing commas enabled, var rules enforced, MA0038 disabled

### workday-terraform
- **PR #1** (Task 12, scaffolding) — merged
- **PR #2** (Task 13, dev/secrets-manager) — merged
- **PR #3** (Task 14, dev/container-lambdas) — open, CI green, Platform team requested as
  reviewer. **Blocked on v0.1.0 release image** — ECR only has pre-release tags. Do not merge
  until release is cut.

### Workday Sandbox Configuration
- ISU: `ISU_WD_Account_Provisioning`, ISSG: `ISSG_WD_Account_Provisioning`
- Tenant: `havenleisureltd` (sandbox `impl-services1.wd107.myworkday.com`)
- OAuth client: `WD_Account_Provisioning_REST` — scopes: Public Data, Staffing, System; Include
  Workday Owned Scope: Yes
- 16 domain security policies configured and activated (full list in
  `project_workday_sandbox_validation.md`)
- Credentials in Secrets Manager: `workday/account-provisioning-credentials` (managed by
  workday-terraform)
- **Temporary workaround:** ISU added to `ISSU_Fabric` to inherit its Authentication Policy
  (permits API Client/OAuth2 bearer auth). Permanent auth policy for own ISSG pending.

### Sandbox Validation (2026-04-23)
All REST endpoints confirmed working: Workers (11,301), Staffing, WQL dataSources (63), WQL
query via GET. WQL POST returns 403 — use GET instead. Full details in
`project_workday_sandbox_validation.md`.

### Next Steps (ordered)
1. **Exercise code via Aspire harness** — run locally against Workday sandbox, verify logging
   completeness, telemetry (traces/metrics/logs), and end-to-end correctness
2. Get human review/approval on PR, merge, cut v0.1.0 release
3. Merge workday-terraform PR #3, then staging/prod Terraform PRs

### Open Items Requiring Human Input
- Permanent Authentication Policy for `ISSG_WD_Account_Provisioning` (colleague pursuing)
- Provisioning group names to be created in Workday sandbox for end-to-end testing
- Staging/prod secret values and Terraform modules
