# Project Memory

## Current State (2026-03-21)

### PRs

| PR | Branch | Repo | Purpose | Status |
|---|---|---|---|---|
| #7168 | `feat/master-data-import-ecr` | platform-terraform | Lambda ECR repo | **Applied** |
| #7181 | `feat/wasm-ecr` | platform-terraform | WASM ECR repo | **Applied** |
| #20 | `feat/master-data-import-entraid` | platform-multicloud | Entra ID app registration | **Merged & applied** |
| #463 | — | platform-azure-terraform | Entra ID security groups (Dev + Users) | **Merged & applied** |
| #737 | — | platform-iamldap | Group membership (7 finance users) | **Merged & applied** |
| #535 | `feat/master-data-import-infra` | finance-terraform | S3 bucket + Lambda def | **Applied** |
| #537 | `feat/master-data-import-entraid` | finance-terraform | ~~Entra ID app registration~~ | **Closed** (superseded by platform-multicloud #20) |
| #541 | `feat/master-data-import-entra-client-id` | finance-terraform | `ENTRA_CLIENT_ID` env var on Lambda | **Merged & applied** |
| #542 | `feat/master-data-import-function-url` | finance-terraform | Function URL + `ENTRA_IDENTIFIER_URI` + SSM permission | **Merged & applied** |
| #538 | `feat/master-data-import-cdn` | finance-terraform | CloudFront + WAF + S3 OAC + WASM S3 | **Merged & applied** |
| #1 | `feat/master-data-import` | finance-erp-master-data-import | App code + CI/CD workflows | **Merged** |
| #2 | `feat/versioning-and-wasm-deployment` | finance-erp-master-data-import | Versioning + WASM deployment + parallel CI | **Merged & applied** |
| #22 | `feat/master-data-import-access-control` | platform-multicloud | `app_role_assignment_required` + group→app assignment | **Merged & applied** |
| #551 | `fix/lambda-function-url-auth-none` | finance-terraform | Change function URL auth to NONE (container-lambdas) | **Merged & applied** |
| #550 | `fix/remove-lambda-oac` | finance-terraform | Remove Lambda OAC from CloudFront (master-data-import-cdn) | **Merged & applied** |
| #553 | `fix/lambda-permission-hotfix` | finance-terraform | Restore Lambda access + delete orphaned OAC | **Merged & applied** |
| #554 | `fix/lambda-public-access-permission` | finance-terraform | Change Principal to `"*"` for function URL | **Closed without applying** (superseded by #560) |
| #560 | `fix/lambda-resource-policy` | finance-terraform | Grant public access to Lambda function URL | **Merged & applied** |
| #556 | `feat/master-data-import-cdn-origin-verify` | finance-terraform | X-Origin-Verify header + SSM parameter | **Merged & applied** |
| #557 | `feat/master-data-import-s3-cors` | finance-terraform | S3 CORS rule for presigned upload | **Merged & applied** |
| #558 | `feat/container-lambdas-origin-verify` | finance-terraform | `ORIGIN_VERIFY_SECRET` Lambda env var | **Merged & applied** |
| #4 | `feat/e2e-import-testing` | finance-erp-master-data-import | E2E testing + preview enhancements | **Merged** |

### Live Environment

- **CloudFront domain**: `https://doogokq33npvz.cloudfront.net`
- **WASM S3 bucket**: `finance-master-data-import-wasm-dev`
- **Lambda function URL**: `finance-aot-master-data-import` (AuthType NONE, Principal: "*", working)
- **CloudFront distribution ID**: `E3T2R0RXN7D1T9`
- **Function URL domain**: `2h74os7amtauw2hqt43kacpizm0cvbee.lambda-url.eu-west-1.on.aws`
- **WAF**: rate limit 500 req/5min per IP scoped to `/api/*`, managed rule sets (common, known bad inputs, IP reputation)
- **Region**: `eu-west-1` (WAF in `us-east-1` for CLOUDFRONT scope)

### What's Done
- Full implementation merged to `main` (PR #1)
- Versioning + WASM deployment (PR #2) merged
- Both ECR repos exist and accepting pushes
- Image `v0.1.0` in Lambda ECR, Lambda + S3 deployed to dev
- Entra ID app registration + security groups + access control
- CloudFront distribution live at `doogokq33npvz.cloudfront.net`
- Origin verify infrastructure deployed (CloudFront header + SSM + Lambda env var)
- Origin verify middleware implemented and tested in application code
- S3 CORS rule for presigned upload deployed
- Presigned upload endpoint implemented
- Lambda resource policy fixed — `Principal: "*"` with `FunctionUrlAuthType: NONE` (#560)
- Lambda reachable through CloudFront (verified: `/health` returns JSON, `/api/*` works)
- Origin verify blocks direct function URL access on `/api/*` (verified: returns 403)
- Sign-in via CloudFront works end-to-end (verified: Entra ID login + access control — users not in security groups are blocked)
- E2E testing + preview enhancements (PR #4) merged
- Cache-Control + error diagnostics + presigned GET for results (PR #6) merged

### ERPx PATCH API
See [erpx-patch-api.md](erpx-patch-api.md) for full discovery notes.

### Current Work (2026-03-21) — branch `feat/e2e-testing-2`

**Status: All committed and pushed. Build passes, 173 tests pass, zero warnings, InspectCode clean. Ready for PR to main.**

Branch includes:
- RFC 6902 JSON Patch for ERPx PATCH endpoint + 422-as-success handling
- Unified import grid — keeps preview table visible during import with progressive status updates
- **Preview lock (concurrency guard)** — S3-based advisory lock (`locks/{companyId}.json`)
- Synchronized failure hover — hovering a failed row highlights the matching failure row
- Skip legend colour fix — legend-skip dot matches skip badge
- NuGet upgrades: Sylvan.Data.Excel 0.5.4, HotReload.WebAssembly.Browser 10.0.201
- **Review fixes** (from code-review-team pre-review):
  - Cancel polling on execute failure (linked CTS + ContinueWith)
  - Detect lock theft during import (keep-alive checks Acquired response)
  - Dispose JsonDocument in static element initialisers
  - Stricter companyId validation (alphanumeric allowlist, max 10 chars)
  - Various InspectCode fixes (redundant defaults, unused params, naming)

### Next Steps
- PR `feat/e2e-testing-2` to `main`
- E2E test with real spreadsheets against dev environment
- Optimise ObjectAPI `select` parameter

### Verified (2026-03-18)
- ObjectAPI batch preview works — all 200s, found 16,890 existing projects in PUK
- Preview diff display works — strikethrough/bold for changed fields
- Parser date string bug fixed (`ad8a9a4`) — iCon date strings now parse to YYYYMM
- Parser whitespace trim bug fixed (`ad8a9a4`) — no more false-positive diffs

### Test Spreadsheets (repo root, untracked)
- `test-spreadsheet-mixed.xlsx` — flat format: 2 creates + 2 updates
- `test-spreadsheet-failures.xlsx` — flat format: 2 valid + 2 designed to fail at ERPx (bad cost centre / bad manager) + 1 create
- `test-spreadsheet-icon.xlsx` — iCon format: 2 creates + 2 updates + pcprojbl budget fields

### Aspire Local Dev
See [aspire-dashboard-playwright.md](aspire-dashboard-playwright.md) for Playwright-based log viewing.

### CloudFront + WASM S3 Infra
See [cloudfront-wasm-infra.md](cloudfront-wasm-infra.md) for full context.

**Deferred:**
- Custom domain + ACM cert — blocked on Platform confirming Route53 zone (resolves Orca findings re: default SSL cert and TLS version)
- Shield Advanced — not used anywhere in HavenEngineering org; $3k/month org-wide decision, not per-resource

### Orca Security Findings on #538
See [orca-findings-538.md](orca-findings-538.md) for full triage.
- #1 Medium: default SSL cert — deferred (needs custom domain)
- #2 Low: Shield Advanced — org-wide decision, not in use anywhere
- #3 Low: old TLS — consequence of #1, resolves together
- #4 Low: S3 policy HTTP — false positive (module handles `attach_deny_insecure_transport_policy`)
- #5 Info: S3 logging — false positive (logs bucket, not data bucket)

### Key Decisions
- Lambda function URL uses `AuthType: NONE` — no OAC (OAC blocks browser POST/PUT due to missing `x-amz-content-sha256`). Resource policy MUST use `Principal: "*"` (not `cloudfront.amazonaws.com`) because without OAC there is no SigV4 context. See `docs/cloudfront-lambda-auth-analysis.md`.
- Origin verify (`X-Origin-Verify` header) is the application-layer replacement for OAC/resource-policy access control
- Entra ID app registration in platform-multicloud (not finance-terraform)
- Entra ID identifier URI: `api://finance-master-data-import-Global`
- Entra ID client ID: `cc5ebeca-b7ba-4449-bfa7-847160f69640`
- Lambda Web Adapter ECR image: `public.ecr.aws/awsguru/aws-lambda-adapter` (NOT `aws-lambda-web-adapter`)
- 404 and 422 excluded from Polly retries (404: definitive "not found"; 422: ERPx success response)
- WASM S3 bucket separate from uploads/results bucket (different lifecycle, different access)
- Single git tag for both artefacts (same version, same release)
- `_framework/*` cached aggressively (content-hashed), everything else no-cache
- S3 modules use `terraform-aws-modules/s3-bucket/aws` v5.9.1 (AWS provider 6.x compatible)
- CDN module uses AWS provider `~> 6.0` via `_override.tf` (rest of repo on `~> 5.38`)
- SSM IAM wildcard at `/finance/master-data-import/*` (intentional — avoids churn for future params)
- HotReload.WebAssembly.Browser must use `Update` (not `Include`) in csproj — SDK implicitly references it; `Include` causes NU1504 duplicate

### Known Tech Debt
- **ObjectAPI `select` parameter**: `select=projectId,projectName,...` returns 400 on ERPx NPE. Currently fetches all fields without `select`.
- **ERPx permissions**: Service account gets 403 on `GET /v1/projects/{id}` for some operations.
- **Execute path N+1**: Each project requires 2 HTTP calls (exists check + create/update).
- **Unpatchable date fields UX gap**: `dateFrom`/`dateTo` removed from `IsFieldsMatch` because ERPx rejects date patches (error 4020). Users who change dates in their spreadsheet see "skipped" with no indication their date changes were silently ignored. Need a preview warning when dates differ but can't be patched.
- **Asymmetric CFG match in preview**: `IsCfgMatch` only checks payload fields against current values, not the reverse. PATCH semantics are correct (extra current fields are preserved), but preview doesn't surface extra current CFG fields not in the spreadsheet — could be misleading.
- **Presigned URL for missing S3 result**: Result endpoint returns a presigned GET URL without checking if the S3 object exists. Client gets a confusing 404 instead of a clear error. Should translate S3 404s in `ImportService.GetResultAsync` or check existence before generating the URL.
- **Coverage gaps**: `Haven.Finance.Clients.Erpx` at 78.84% and `bootstrap` (Lambda) at 70.78% — both below the 80% gate target.

### ECR / CI Details
- ECR registry: `745662293263.dkr.ecr.eu-west-1.amazonaws.com`
- Lambda ECR repo: `erp/erp-lambda-finance-aot-master-data-import`
- WASM ECR repo: `erp/erp-wasm-finance-master-data-import`
- Release workflow: `build-and-release-image` (workflow_dispatch, minor/major/patch bump)
- Current version: `v0.1.0`
- AWS profile for ECR access: `haven-745662293263-EcrPullAccess`

### Terraform Repos
- **finance-terraform**: `HavenEngineering/finance-terraform` (local: `../finance-terraform/`)
- **platform-terraform**: `HavenEngineering/platform-terraform` — default branch `master`
- **platform-multicloud**: `HavenEngineering/platform-multicloud` — Entra ID app registrations
- **platform-azure-terraform**: `HavenEngineering/platform-azure-terraform` — Entra ID security groups
- **platform-iamldap**: `HavenEngineering/platform-iamldap` — group membership management

### Org Infrastructure Context
- CloudFront is widely used across HavenEngineering (platform-cloudfront-www, platform-cloudfront-subdomains, platform-cloudfront-devprod, foundation-pagedrop, haven-terraform, platform-terraform-pci, app-haven-owner-arrivals, service-haven-maintenancemode, service-haven-owners)
- Shield Advanced is **not enabled anywhere** in the org
- GitHub org: `https://github.com/HavenEngineering`
- Local repos may be stale — always search GitHub directly for org-wide questions (`gh search code`)

### Haven Design System (from module-shared-haven-ui)
See [haven-design-tokens.md](haven-design-tokens.md) for full reference.
