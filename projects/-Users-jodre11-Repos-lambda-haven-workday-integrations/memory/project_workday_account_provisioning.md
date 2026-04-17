---
name: Workday Account Provisioning Lambda
description: Multi-repo project to build a Lambda that bridges Workday provisioning groups to Entra AD connector, tracked in HavenEngineering/integrations#736
type: project
originSessionId: 4e150787-3352-4765-a4ee-f7fd9e15058d
---
Building a .NET 10 AOT Lambda that writes provisioning group values to Workday workers so the Entra connector can provision/disable AD accounts. Two repos:

- **lambda-haven-workday-integrations** — monorepo for Lambda code + shared Workday client library
- **workday-terraform** — Terraform infra (Lambda, ECR, IAM, EventBridge, Secrets Manager, SSM)

**Why:** Entra connector cannot read Workday calculated fields (Microsoft limitation), so it cannot evaluate "hire date within N days". This Lambda bridges the gap by writing a provisioning group value the connector can read.

**How to apply:** All implementation follows the `finance-erp-aot-*` cookie cutter pattern. Design spec lives at `/Users/jodre11/Repos/workday-iac/docs/superpowers/specs/2026-04-16-workday-account-provisioning-design.md`. Tracks HavenEngineering/integrations#736.
