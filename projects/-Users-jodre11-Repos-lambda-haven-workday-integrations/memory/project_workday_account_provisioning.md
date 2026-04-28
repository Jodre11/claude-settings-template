---
name: Workday Account Provisioning Lambda
description: Multi-repo Lambda project — end-to-end validated (AD integration reads provisioning groups), awaiting PR review and v0.1.0 release
type: project
originSessionId: c80bfa75-056b-4ca9-bcf5-d50ebf56f239
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

## Current State (2026-04-28)

### Integration Chain — CONFIRMED

- **2026-04-28:** Jon White confirmed provisioning groups are readable from the AD integration
- Full technical chain validated: Lambda → SOAP write → Workday → AD integration reads assignments
- **Still needed:** proper end-to-end testing of business scenarios (new worker onboarding, hire-date window timing, access appearing at the right moment)
- **All ~11,000 active employees** processed successfully via SOAP, zero failures
- Two-query strategy: watermark query + hire-date window query in parallel via `Task.WhenAll`
- Threshold logic: `now >= hireDate - ProvisioningWindowDays` → "Network Access", else "No Access"

### Jon White (Modern Workplace) — Entra Connector Working

- Entra connector configured and reading provisioning groups from Workday
- XPath: `wd:Worker/wd:Worker_Data/wd:Account_Provisioning_Data/wd:Provisioning_Group_Assignment_Data[wd:Status='Assigned']/wd:Provisioning_Group/text()`
- Scoping filter: `EQUALS` "Network Access"

### lambda-haven-workday-integrations

- **Branch:** `feat/initial-implementation`, pushed, clean
- **PR #2:** open, awaiting review
- **Build:** 0 warnings, 29 tests passing, 0 InspectCode issues
- **Harness:** `/run` endpoint (full handler) + `/set-group` endpoint (ad-hoc assignments)

### workday-terraform

- **PR #1** (scaffolding) — merged
- **PR #2** (dev/secrets-manager) — merged
- **PR #3** (dev/container-lambdas) — open, CI green, **blocked on v0.1.0 release image**

### Wiki

Published: https://github.com/HavenEngineering/lambda-haven-workday-integrations/wiki/Setting-Up-a-Workday-API-Integration

### Workday Sandbox Configuration

- ISU: `ISU_WD_Account_Provisioning`, ISSG: `ISSG_WD_Account_Provisioning`
- Tenant: `havenleisureltd` (sandbox `impl-services1.wd107.myworkday.com`)
- OAuth client: `WD_Account_Provisioning_REST` — scopes: Public Data, Staffing, System
- 18 domain security policies configured ("Provisioning Group Administration" is unnecessary, should be removed)
- External Account Provisioning domain: **granted and activated** — SOAP writes working
- Credentials in Secrets Manager: `workday/account-provisioning-credentials` (finance-dev)
- **Temporary workaround:** ISU added to `ISSU_Fabric` for Authentication Policy inheritance

### Issue #736

Updated 2026-04-24 with comprehensive progress comment including:
- Full implementation details, sandbox validation results
- Entra connector configuration (XPath, steps, Microsoft docs)
- Test employees, repo status, security config
- "How to pick up this work" section for continuity

### Next Steps (ordered)

1. Get PR #2 reviewed and merged
2. Cut v0.1.0 release image to ECR
3. Merge workday-terraform PR #3 (Platform team `/apply`)
4. ~~Jon White: configure Entra connector in sandbox~~ ✓
5. ~~End-to-end validation (Entra reads provisioning groups correctly)~~ ✓ (2026-04-28)
6. Minimal permissions audit (trim ISSG to minimum domains)
7. Permanent Authentication Policy for ISSG (stop borrowing ISSU_Fabric)
8. Staging and production rollout
9. SOAP parallelisation (deferred, ~55min → ~3-6min)
10. Clean up redundant docs/wiki-screenshots from main
