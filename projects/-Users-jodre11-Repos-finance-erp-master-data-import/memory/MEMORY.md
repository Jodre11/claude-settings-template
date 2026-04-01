# Project Memory

## Preferences
- When summarising status with open PRs, always include full GitHub URLs (not short references)

## Current State (2026-03-25)

### Multi-Environment Rollout — Active Work

**Design spec:** `docs/superpowers/specs/2026-03-23-multi-environment-design.md`
**Infra plan:** `docs/superpowers/plans/2026-03-23-multi-environment-infrastructure.md`
**CI/CD plan:** `docs/superpowers/plans/2026-03-23-multi-environment-cicd.md`

**Terraform PR rule:** One PR, one `/apply`. Once `/apply`'d, do NOT add new commits. Multiple independent module directories CAN go in one PR. Only split if modules have dependencies preventing simultaneous apply.

**Key learning:** finance-terraform runs in finance AWS accounts, platform-terraform in platform accounts. Route53 zones and wildcard ACM certs are in the platform account. finance-terraform PRs require Platform + SRE approval.

**DNS zone ownership:** `haven-stage.com` is in platform-terraform (`staging/platform-dns/`). `haven.com` root zone is NOT in platform-terraform — only `api.haven.com` is (subdelegated). Records in `haven.com` require a Production Support ticket.

#### Infrastructure PRs (Phases 1-2) — ALL APPLIED

| PR | Repo | What | Status |
|---|---|---|---|
| A | platform-multicloud #25 | Staging + prod Entra ID app registrations | **Merged & applied** |
| B | [#563](https://github.com/HavenEngineering/finance-terraform/pull/563) | S3 buckets staging + prod | **Merged & applied** |
| C | [#564](https://github.com/HavenEngineering/finance-terraform/pull/564) | Lambda bootstrap staging + prod | **Merged & applied** |
| D | [#567](https://github.com/HavenEngineering/finance-terraform/pull/567) | CloudFront + WAF + WASM S3 staging + prod | **Merged & applied** |
| E | [#569](https://github.com/HavenEngineering/finance-terraform/pull/569) | Origin verify + ACM certs + `enable_custom_domain` toggle — all 4 modules | **Merged & applied 2026-03-25** |

#### #569 Apply Outputs (needed for remaining steps)

**Staging:**
- CloudFront domain: `djobvgo2cjjun.cloudfront.net`
- CloudFront distribution ID: `EEZPJGOJSUKIT`
- WASM bucket: `finance-master-data-import-wasm-staging`
- ACM cert ARN: `arn:aws:acm:us-east-1:471112640844:certificate/3768478d-e792-4582-98f4-a2c8e45829ce`
- DNS validation CNAME: `_207fae806260e8b196254bf774cf35a6.erpx-master-data-import.haven-stage.com.` -> `_a377368aa73b503e9dc89a8cc29917ad.jkddzztszm.acm-validations.aws.`

**Prod:**
- CloudFront domain: `d35sud8o96jfhr.cloudfront.net`
- CloudFront distribution ID: `E15CQ91RGU0QXS`
- WASM bucket: `finance-master-data-import-wasm-prod`
- ACM cert ARN: `arn:aws:acm:us-east-1:171547406407:certificate/2fd350b9-b753-46f0-926f-238f9b672633`
- DNS validation CNAME: `_ba6b0c6d7685d897fa204f303b9da2da.erpx-master-data-import.haven.com.` -> `_35ba43cee972a1ca1b295b5d2873597b.jkddzztszm.acm-validations.aws.`

#### Remaining Steps

| Step | What | Blocked by | Status |
|---|---|---|---|
| F1 | [platform-terraform #7266](https://github.com/HavenEngineering/platform-terraform/pull/7266): staging DNS validation CNAME + A-record | **Domain decision — Platform says don't use haven-stage.com** | **Blocked — awaiting Platform team member (on holiday)** |
| F2 | Production Support ticket: prod DNS validation CNAME + A-record for `haven.com` | Domain decision (may proceed independently) | **Not yet submitted** |
| F3 | finance-terraform PR: set `enable_custom_domain = true` in staging + prod CDN modules | F1 + F2 (certs must be `ISSUED`) | **PR to create** |
| H | GitHub repo settings: create `dev`/`staging`/`prod` environments, populate variables | Nothing (unblocked) | **Can do now** |
| Merge #8 | [PR #8](https://github.com/HavenEngineering/finance-erp-master-data-import/pull/8) — multi-env CI/CD workflows | H (environments must exist) | **Ready to merge after H** |
| First deploy | Manual `deploy-image-manual.yml` to staging, then prod | Merge #8 + H | **Manual** |

**Two-phase custom domain:** #569 creates ACM certs with `enable_custom_domain = false` (default). Certs start as `PENDING_VALIDATION`. After DNS validation CNAMEs are created cross-account and certs become `ISSUED`, step F3 flips the toggle to attach aliases + TLS 1.2 to CloudFront.

#### CI/CD (Phase 3) — PR OPEN
- [PR #8](https://github.com/HavenEngineering/finance-erp-master-data-import/pull/8) (`docs/multi-environment-design`) — multi-environment deploy workflows + lock grace period fix + spec fixes
- CI auto-deploys to dev (branch has open PR)

#### GitHub Environment Variables to Configure (Step H)

| Variable | `dev` | `staging` | `prod` |
|---|---|---|---|
| `AWS_PROFILE` | `finance-dev` | `finance-staging` | `finance-prod` |
| `LAMBDA_NAME` | `finance-aot-master-data-import` | `finance-aot-master-data-import` | `finance-aot-master-data-import` |
| `S3_WASM_BUCKET` | `finance-master-data-import-wasm-dev` | `finance-master-data-import-wasm-staging` | `finance-master-data-import-wasm-prod` |
| `CLOUDFRONT_DISTRIBUTION_ID` | `E3T2R0RXN7D1T9` | `EEZPJGOJSUKIT` | `E15CQ91RGU0QXS` |
| `ENTRA_CLIENT_ID` | `cc5ebeca-b7ba-4449-bfa7-847160f69640` | `36ce6ffa-41d6-475b-8c34-399234540c3f` | `dfbc0a8d-2327-40fc-b092-e5bbe743d2be` |
| `ENTRA_IDENTIFIER_URI` | `api://finance-master-data-import-Global` | `api://finance-master-data-import-Staging` | `api://finance-master-data-import-Prod` |

#### Deploy Status
- Dev currently running code from `docs/multi-environment-design` branch (CI auto-deployed via PR #8)

### Active PRs

| PR | Repo | Purpose | Status |
|---|---|---|---|
| [#7266](https://github.com/HavenEngineering/platform-terraform/pull/7266) | platform-terraform | Staging DNS: cert validation CNAME + A-record | **Open — blocked: Platform says don't use haven-stage.com; stale state lock** |
| [#8](https://github.com/HavenEngineering/finance-erp-master-data-import/pull/8) | finance-erp-master-data-import | Multi-env CI/CD workflows + lock grace period fix | **Open — ready to merge after H** |

### Completed PRs (dev + multi-env infra)
All merged & applied: platform-multicloud #20, #22, #25; platform-azure-terraform #463; platform-iamldap #737; platform-terraform #7168, #7181; finance-terraform #535, #538, #541, #542, #550, #551, #553, #556, #557, #558, #560, #563, #564, #566, #567, #569; finance-erp-master-data-import #1, #2, #4, #7. Closed: finance-terraform #568 (folded into #569).

### Entra ID Client IDs
| Environment | Client ID |
|---|---|
| Dev | `cc5ebeca-b7ba-4449-bfa7-847160f69640` |
| Staging | `36ce6ffa-41d6-475b-8c34-399234540c3f` |
| Prod | `dfbc0a8d-2327-40fc-b092-e5bbe743d2be` |

### Local Branch State
- **finance-terraform**: on `feat/master-data-import-cdn-custom-domain` (PR #569, now merged)
- **platform-terraform**: on `feat/master-data-import-staging-dns` (PR #7266)
- **finance-erp-master-data-import**: on `docs/multi-environment-design` (PR #8)

### Live Dev Environment

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
- **platform-multicloud**: `HavenEngineering/platform-multicloud` — Entra ID app registrations
- **platform-azure-terraform**: `HavenEngineering/platform-azure-terraform` — Entra ID security groups
- **platform-iamldap**: `HavenEngineering/platform-iamldap` — group membership management

### ECR / CI Details
- ECR registry: `745662293263.dkr.ecr.eu-west-1.amazonaws.com`
- Lambda ECR repo: `erp/erp-lambda-finance-aot-master-data-import`
- WASM ECR repo: `erp/erp-wasm-finance-master-data-import`
- Release workflow: `build-and-release-image` (workflow_dispatch, minor/major/patch bump)
- AWS profile for ECR access: `haven-745662293263-EcrPullAccess`

### Domain Blocker (2026-03-31)
- [project_domain_blocker.md](project_domain_blocker.md) — Platform team said haven-stage.com shouldn't be used; staging + prod custom domains uncertain
- [project_paul_waller_teams_message.md](project_paul_waller_teams_message.md) — 2026-03-31 Teams msg to Paul Waller (Platform, GH: paul-waller) re domain guidance; awaiting response

### Reference Files
- [orca-findings-538.md](orca-findings-538.md) — Orca triage for dev CDN (#538)
- [haven-design-tokens.md](haven-design-tokens.md) — Haven design system tokens
- [erpx-patch-api.md](erpx-patch-api.md) — ERPx PATCH API discovery notes
- [reference_integrations_ticket.md](reference_integrations_ticket.md) — Parent ticket: HavenEngineering/integrations#726, deadline 2026-04-30
