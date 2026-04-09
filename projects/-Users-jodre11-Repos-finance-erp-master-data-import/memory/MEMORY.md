# Project Memory

## Preferences
- When summarising status with open PRs, always include full GitHub URLs (not short references)
- [All config in source control](feedback_source_control_config.md) — never use GitHub Environment variables for non-secret config

## Current State (2026-04-08)

### Multi-Environment Rollout — Active Work

**Design spec:** `docs/superpowers/specs/2026-03-23-multi-environment-design.md`
**Infra plan:** `docs/superpowers/plans/2026-03-23-multi-environment-infrastructure.md`
**CI/CD plan:** `docs/superpowers/plans/2026-03-23-multi-environment-cicd.md`

**Terraform PR rule:** One PR gets exactly one `/apply`. That single `/apply` applies all module directories in the PR together. Once `/apply`'d, do NOT add new commits — the PR is done. Multiple independent module directories CAN go in one PR (they're not a reason to split). Only split PRs if there's a genuine ordering dependency between modules. Do not list module directories as separate apply steps in PR descriptions — it implies multiple `/apply` comments are needed.

**Key learning:** finance-terraform runs in finance AWS accounts, platform-terraform in platform accounts. Route53 zones and wildcard ACM certs are in the platform account. finance-terraform PRs require Platform + SRE approval.

**DNS zone ownership:** `{env}.haven-leisure.com` zones are in platform-terraform (`{env}/platform-dns/`). Wildcard ACM certs (`*.{env}.haven-leisure.com`) already exist in `{env}/platform-k8s/acm.tf`. DNS records for CloudFront aliases go in `{env}/platform-dns/dns.tf`.

**Custom domains:** `master-data-import.{env}.haven-leisure.com`. All three environments fully operational.

#### Environment CloudFront Details

**Dev:**
- CloudFront domain: `doogokq33npvz.cloudfront.net`
- CloudFront distribution ID: `E3T2R0RXN7D1T9`
- WASM bucket: `finance-master-data-import-wasm-dev`
- Custom domain: `master-data-import.dev.haven-leisure.com` (active)

**Staging:**
- CloudFront domain: `djobvgo2cjjun.cloudfront.net`
- CloudFront distribution ID: `EEZPJGOJSUKIT`
- WASM bucket: `finance-master-data-import-wasm-staging`
- Custom domain: `master-data-import.staging.haven-leisure.com` (active)

**Prod:**
- CloudFront domain: `d35sud8o96jfhr.cloudfront.net`
- CloudFront distribution ID: `E15CQ91RGU0QXS`
- WASM bucket: `finance-master-data-import-wasm-prod`
- Custom domain: `master-data-import.prod.haven-leisure.com` (active)

#### Route53 Zone IDs (haven-leisure.com)
- Dev: `Z0641457244UIP2SZ79N2` (`dev.haven-leisure.com`)
- Staging: `Z0043771386ATLDADKBR2` (`staging.haven-leisure.com`)
- Prod: `Z087260813NK12A69EC1R` (`prod.haven-leisure.com`)

#### Remaining Steps

| Step | What | Blocked by | Status |
|---|---|---|---|
| ~~Apply #582~~ | [finance-terraform #582](https://github.com/HavenEngineering/finance-terraform/pull/582) — dev CloudFront alias | — | **Done** |
| ~~Env config~~ | Environment config in source control (`.github/environments.json`) | — | **Done** |
| ~~Merge #8~~ | [PR #8](https://github.com/HavenEngineering/finance-erp-master-data-import/pull/8) — multi-env CI/CD workflows + deploy-wasm | — | **Merged 2026-04-08** |
| ~~My Apps~~ | My Apps portal branding (display names, login URLs, logos) | — | **Done** |
| First deploy | Release + deploy to staging, then prod | — | **Next — see deploy process below** |
| WASM dispatch | Auto-trigger WASM deploy after finance-terraform apply | GitHub App or PAT with `actions:write` | **Ticketed: [integrations #742](https://github.com/HavenEngineering/integrations/issues/742) — future nice-to-have** |

#### Staging/Prod Deploy Process (after PR #8 merges)
1. **Lambda**: finance-terraform PR updating `image_tag` in `{env}/container-lambdas/lambdas.tf` → merge → `/apply`
2. **WASM**: manually trigger `deploy-wasm.yml` with the same environment and image tag
3. Both steps must use the same image tag to keep Lambda and WASM in sync
4. **Future**: cross-repo `repository_dispatch` to automate step 2 — see [integrations #742](https://github.com/HavenEngineering/integrations/issues/742)

#### Cross-Repo WASM Deploy Automation (deferred)
- **Ticket**: [HavenEngineering/integrations#742](https://github.com/HavenEngineering/integrations/issues/742)
- **Problem**: after finance-terraform `/apply` on container-lambdas, WASM deploy is a separate manual step that's easy to forget
- **Proposed**: `repository_dispatch` from finance-terraform to finance-erp-master-data-import after successful apply
- **Blocker**: requires a GitHub App or PAT with `actions:write` on the target repo. No cross-repo `repository_dispatch` pattern exists in the org today. Existing `platform-github-terraform` App (ID `867876`) lacks `actions:write`.
- **Manual workaround**: trigger `deploy-wasm.yml` manually after each finance-terraform apply on container-lambdas

#### Deploy Status
- Dev currently running code from `docs/multi-environment-design` branch (CI auto-deployed via PR #8)
- Staging and prod: infrastructure ready, no code deployed yet

### Active PRs

None — all multi-environment PRs merged/applied.

### Completed PRs (dev + multi-env infra + custom domains + CI/CD)
All merged & applied: platform-multicloud #20, #22, #25, #26, #27; tf-az-entraid-application #2 (tagged v1.1.0); platform-azure-terraform #463; platform-iamldap #737; platform-terraform #7168, #7181, #7343; finance-terraform #535, #538, #541, #542, #550, #551, #553, #556, #557, #558, #560, #563, #564, #566, #567, #569, #579, #581, #582; finance-erp-master-data-import #1, #2, #4, #7, #8. Closed: finance-terraform #568 (folded into #569), platform-terraform #7266 (wrong domain — replaced by haven-leisure.com approach), integrations #739 (domain blocker — resolved).

### Entra ID Client IDs
| Environment | Client ID |
|---|---|
| Dev | `cc5ebeca-b7ba-4449-bfa7-847160f69640` |
| Staging | `36ce6ffa-41d6-475b-8c34-399234540c3f` |
| Prod | `dfbc0a8d-2327-40fc-b092-e5bbe743d2be` |

### Local Branch State
- **finance-terraform**: on `feat/master-data-import-enable-custom-domain-dev` (PR #582)
- **platform-terraform**: on `feat/master-data-import-haven-leisure-dns` (PR #7343 — merged)
- **finance-erp-master-data-import**: on `docs/multi-environment-design` (PR #8)
- **tf-az-entraid-application**: on `main` (v1.1.0 tagged)
- **platform-multicloud**: on `feat/master-data-import-myapps-branding` (PR #27 — merged)

### Live Dev Environment

- **Custom domain**: `https://master-data-import.dev.haven-leisure.com` (active)
- **CloudFront domain**: `https://doogokq33npvz.cloudfront.net`
- **WASM S3 bucket**: `finance-master-data-import-wasm-dev`
- **Lambda function URL**: `finance-aot-master-data-import` (AuthType NONE, Principal: "*")
- **CloudFront distribution ID**: `E3T2R0RXN7D1T9`
- **Function URL domain**: `2h74os7amtauw2hqt43kacpizm0cvbee.lambda-url.eu-west-1.on.aws`
- **WAF**: rate limit 500 req/5min per IP scoped to `/api/*`, managed rule sets
- **Region**: `eu-west-1` (WAF in `us-east-1` for CLOUDFRONT scope)
- **Entra ID client ID**: `cc5ebeca-b7ba-4449-bfa7-847160f69640`
- **Entra ID identifier URI**: `api://finance-master-data-import-Global`
- **Current version**: `v0.2.0` (redeployed 2026-03-24 for demo)

### Key Decisions
- Lambda function URL uses `AuthType: NONE` — no OAC. Resource policy `Principal: "*"`. See `docs/cloudfront-lambda-auth-analysis.md`.
- Origin verify (`X-Origin-Verify` header) is the application-layer replacement for OAC
- Entra ID app registration in platform-multicloud (not finance-terraform)
- Lambda Web Adapter ECR image: `public.ecr.aws/awsguru/aws-lambda-adapter`
- 404 and 422 excluded from Polly retries
- WASM S3 bucket separate from uploads/results bucket
- Single git tag for both artefacts (same version, same release)
- `_framework/*` cached aggressively (content-hashed), everything else no-cache
- S3 modules use `terraform-aws-modules/s3-bucket/aws` v3.14.0
- CDN module uses AWS provider `~> 6.0` via `_override.tf` (rest of repo on `~> 5.38`)
- SSM IAM wildcard at `/finance/master-data-import/*`
- Prod S3 CORS: no localhost (removed per Copilot review); staging/dev keep localhost for local dev

### Known Tech Debt
- **ObjectAPI `select` parameter**: returns 400 on `/v1/objects/projects`. Code: `ErpxProjectWriteService.cs:130`.
- **Coverage gaps**: `Haven.Finance.Clients.Erpx` at 78.84%, `bootstrap` (Lambda) at 70.78%
- **Unpatchable date fields UX gap**: dates silently ignored in preview
- **Asymmetric CFG match in preview**: doesn't surface extra current CFG fields
- **Presigned URL for missing S3 result**: confusing 404 instead of clear error

### Terraform Repos
- **finance-terraform**: `HavenEngineering/finance-terraform` (local: `../finance-terraform/`)
- **platform-terraform**: `HavenEngineering/platform-terraform` — default branch `master`
- **platform-multicloud**: `HavenEngineering/platform-multicloud` (local: `../platform-multicloud/`) — Entra ID app registrations
- **platform-azure-terraform**: `HavenEngineering/platform-azure-terraform` — Entra ID security groups
- **platform-iamldap**: `HavenEngineering/platform-iamldap` — group membership management
- **tf-az-entraid-application**: `HavenEngineering/tf-az-entraid-application` (local: `~/Repos/tf-az-entraid-application/`) — shared Terraform module for Entra ID apps (v1.1.0)

### ECR / CI Details
- ECR registry: `745662293263.dkr.ecr.eu-west-1.amazonaws.com`
- Lambda ECR repo: `erp/erp-lambda-finance-aot-master-data-import`
- WASM ECR repo: `erp/erp-wasm-finance-master-data-import`
- Release workflow: `build-and-release-image` (workflow_dispatch, minor/major/patch bump)
- AWS profile for ECR access: `haven-745662293263-EcrPullAccess`

### Domain Decision (resolved 2026-04-07, #739 closed 2026-04-08)
- [project_domain_blocker.md](project_domain_blocker.md) — Resolved: `haven-leisure.com` for internal tools (Paul Waller, Platform)
- [project_paul_waller_teams_message.md](project_paul_waller_teams_message.md) — Paul also questioned CloudFront vs API Gateway; replied explaining the architecture

### Reference Files
- [orca-findings-538.md](orca-findings-538.md) — Orca triage for dev CDN (#538)
- [haven-design-tokens.md](haven-design-tokens.md) — Haven design system tokens
- [erpx-patch-api.md](erpx-patch-api.md) — ERPx PATCH API discovery notes
- [reference_integrations_ticket.md](reference_integrations_ticket.md) — Parent ticket: HavenEngineering/integrations#726, deadline 2026-04-30
- [project_domain_blocker.md](project_domain_blocker.md) — Domain decision: haven-leisure.com
- [project_paul_waller_teams_message.md](project_paul_waller_teams_message.md) — CloudFront architecture reply to Paul Waller
