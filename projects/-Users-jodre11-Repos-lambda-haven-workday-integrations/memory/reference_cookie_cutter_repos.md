---
name: Cookie cutter reference repos
description: Locations of the finance-erp-aot pattern repos used as templates for workday integrations
type: reference
originSessionId: 4e150787-3352-4765-a4ee-f7fd9e15058d
---
- **Lambda code template:** `/Users/jodre11/Repos/lambda-finance-erp/src/` — project structure, Dockerfile, Program.cs, .csproj, pipeline scripts, workflows, analysers, test setup
- **Terraform template:** `/Users/jodre11/Repos/finance-terraform/` — directory layout, Lambda definitions, Strongbox secrets, SSM, EventBridge, IAM, backend config
- **PoC reference code:** `/Users/jodre11/Repos/workday-iac/WorkdayIaC.PoC/Program.cs` — SOAP/REST client reference for Workday API interaction
- **Strongbox secrets docs:** cloud-engineering wiki (clone via SSH: `git@github.com:HavenEngineering/cloud-engineering.wiki.git`, see `Secrets.md`)
