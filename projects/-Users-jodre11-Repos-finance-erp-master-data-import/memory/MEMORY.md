# Project Memory

## Feedback & Preferences
- [Full GitHub URLs in status](feedback_source_control_config.md) — always include full URLs for PRs, never short references
- [All config in source control](feedback_source_control_config.md) — never use GitHub Environment variables for non-secret config
- [My Apps portal checklist](feedback_myapps_portal.md) — display name, homepage URL, logo for Entra ID apps
- [No demo offers](feedback_no_demos.md) — never volunteer user for demos in drafted messages

## Current State (2026-04-09)

### Next Steps — First Staging/Prod Release

| Step | What | Status |
|---|---|---|
| Merge PR #9 | [finance-erp-master-data-import #9](https://github.com/HavenEngineering/finance-erp-master-data-import/pull/9) — H4 branding, self-hosted assets, Aspire MCP, CI improvements | **Merged** |
| Release v0.4.0 | Run `build-and-release-image` workflow from `main` (minor bump) | **In progress** — [run 24233338409](https://github.com/HavenEngineering/finance-erp-master-data-import/actions/runs/24233338409) |
| Terraform PR | finance-terraform: update `image_tag` in all 3 `container-lambdas/lambdas.tf` + fix S3 CORS origins in all 3 `master-data-import/s3.tf` — one PR, one `/apply` | After release |
| WASM deploy | Manually trigger `deploy-wasm.yml` for staging + prod with same image tag | After terraform `/apply` |
| My Apps logo | [platform-multicloud #30](https://github.com/HavenEngineering/platform-multicloud/pull/30) — H4 brand mark logo for all envs | **Open — awaiting review + `/apply`** |

### Known Bug — S3 CORS
- [S3 CORS origins stale](project_s3_cors_bug.md) — staging/prod uploads broken because CORS still references old `haven-stage.com`/`haven.com` domains

### Multi-Environment — Complete
All infrastructure deployed and custom domains active. Design spec: `docs/superpowers/specs/2026-03-23-multi-environment-design.md`

**Terraform PR rule:** One PR = one `/apply`. Multiple module directories fine in one PR. Don't add commits after `/apply`. finance-terraform PRs need Platform + SRE approval.

**Environments:**

| Env | Custom Domain | CloudFront | Distribution ID | WASM Bucket |
|---|---|---|---|---|
| Dev | `master-data-import.dev.haven-leisure.com` | `doogokq33npvz.cloudfront.net` | `E3T2R0RXN7D1T9` | `finance-master-data-import-wasm-dev` |
| Staging | `master-data-import.staging.haven-leisure.com` | `djobvgo2cjjun.cloudfront.net` | `EEZPJGOJSUKIT` | `finance-master-data-import-wasm-staging` |
| Prod | `master-data-import.prod.haven-leisure.com` | `d35sud8o96jfhr.cloudfront.net` | `E15CQ91RGU0QXS` | `finance-master-data-import-wasm-prod` |

**Entra ID Client IDs:**

| Env | Client ID |
|---|---|
| Dev | `cc5ebeca-b7ba-4449-bfa7-847160f69640` |
| Staging | `36ce6ffa-41d6-475b-8c34-399234540c3f` |
| Prod | `dfbc0a8d-2327-40fc-b092-e5bbe743d2be` |

### Deploy Process (staging/prod)
1. **Lambda**: finance-terraform PR updating `image_tag` in `{env}/container-lambdas/lambdas.tf` → merge → `/apply`
2. **WASM**: manually trigger `deploy-wasm.yml` with same environment and image tag
3. **Future**: cross-repo `repository_dispatch` — [integrations #742](https://github.com/HavenEngineering/integrations/issues/742)

### Deploy Status
- Dev: running code from PR #9 merge (auto-deployed), version `v0.3.0` → releasing `v0.4.0`
- Staging/Prod: infrastructure ready, no code deployed yet

### Known Tech Debt
- **ObjectAPI `select` parameter**: returns 400 on `/v1/objects/projects`
- **Coverage gaps**: `Haven.Finance.Clients.Erpx` ~79%, `bootstrap` (Lambda) ~71%
- **Unpatchable date fields UX gap**: dates silently ignored in preview
- **Asymmetric CFG match in preview**: doesn't surface extra current CFG fields
- **Presigned URL for missing S3 result**: confusing 404 instead of clear error

### Key Decisions
- Custom domains on `haven-leisure.com` — [domain decision](project_domain_blocker.md)
- Lambda function URL `AuthType: NONE` + origin verify header — see `docs/cloudfront-lambda-auth-analysis.md`
- Entra ID app registrations in platform-multicloud (not finance-terraform)
- WASM S3 bucket separate from uploads/results bucket
- Single git tag for both artefacts (same version, same release)
- Prod S3 CORS: no localhost; dev only keeps localhost for Aspire

### Reference
- [reference_integrations_ticket.md](reference_integrations_ticket.md) — Parent ticket: integrations#726, deadline 2026-04-30
- [orca-findings-538.md](orca-findings-538.md) — Orca triage for dev CDN
- [haven-design-tokens.md](haven-design-tokens.md) — Haven design system tokens
- [erpx-patch-api.md](erpx-patch-api.md) — ERPx PATCH API discovery notes
- [project_paul_waller_teams_message.md](project_paul_waller_teams_message.md) — CloudFront architecture reply to Paul Waller

### Terraform Repos
- **finance-terraform**: `HavenEngineering/finance-terraform` (local: `../finance-terraform/`)
- **platform-terraform**: `HavenEngineering/platform-terraform` — default branch `master`
- **platform-multicloud**: `HavenEngineering/platform-multicloud` (local: `../platform-multicloud/`)
- **tf-az-entraid-application**: `HavenEngineering/tf-az-entraid-application` (local: `~/Repos/tf-az-entraid-application/`) — v1.1.0
