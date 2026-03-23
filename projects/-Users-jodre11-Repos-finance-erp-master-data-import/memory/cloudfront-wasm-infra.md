# CloudFront + WASM S3 Infrastructure — Applied (2026-03-13)

## Live Environment

- **CloudFront domain**: `https://doogokq33npvz.cloudfront.net`
- **WASM S3 bucket**: `finance-master-data-import-wasm-dev`
- **WASM logs bucket**: `finance-master-data-import-wasm-dev-logs`
- **Lambda function**: `finance-aot-master-data-import` (function URL with AuthType NONE, resource policy restricts to CloudFront)
- **Region**: `eu-west-1` (WAF in `us-east-1` for CLOUDFRONT scope)
- **Terraform module**: `dev/master-data-import-cdn/`

## Infrastructure PRs (all applied)

| PR | Repo | Purpose |
|---|---|---|
| #535 | finance-terraform | S3 uploads/results bucket + Lambda definition |
| #541 | finance-terraform | `ENTRA_CLIENT_ID` env var |
| #542 | finance-terraform | Function URL + `ENTRA_IDENTIFIER_URI` + SSM permission |
| #538 | finance-terraform | CloudFront + WAF + S3 OAC + WASM S3 buckets |
| #550 | finance-terraform | Remove Lambda OAC from CloudFront (unblocks POST/PUT) |

**Key learning**: #538's plan required the function URL to exist in AWS. The `data "aws_lambda_function_url"` lookup queries live AWS API at plan time. Had to split #542 out of #538, apply it first, then rebase #538.

## Architecture

### CloudFront Origins

| Origin | Type | Access |
|--------|------|--------|
| Lambda function URL | Custom origin | `aws_lambda_permission` resource policy (CloudFront only) + JWT Bearer auth |
| WASM S3 bucket | S3 origin | OAC for S3 |

### CloudFront Cache Behaviours

| Priority | Path Pattern | Origin | Cache Policy | Auth |
|----------|-------------|--------|-------------|------|
| 1 | `/health` | Lambda | `CachingDisabled` | None (unauthenticated) |
| 2 | `/api/*` | Lambda | `CachingDisabled` | JWT (Entra ID Bearer) |
| 3 | `/_framework/*` | S3 | `CachingOptimized` (long TTL, immutable) | None |
| 4 | Default `/*` | S3 | `CachingDisabled` | None |

### SPA Fallback
- Custom error responses: S3 403/404 → `/index.html` with HTTP 200
- Required for Blazor client-side routing (`/import`, `/authentication/login-callback`)

### WAF
- Rate limiting: 500 req/5min per IP, scoped to `/api/*` only
- Managed rule sets: common, known bad inputs, IP reputation

### S3 Buckets
- Both use `terraform-aws-modules/s3-bucket/aws` v5.9.1
- WASM bucket: versioning, Intelligent-Tiering, `attach_deny_insecure_transport_policy = true`, S3 OAC policy
- Logs bucket: versioning, 90-day expiration, `log-delivery-write` ACL, `BucketOwnerPreferred`

### Lambda Environment Variables
- `S3_BUCKET_NAME` — uploads/results bucket
- `ERPX_CREDENTIALS_SECRET_NAME` — Secrets Manager secret
- `ERPX_BASE_URL` — ERPx API
- `ERPX_TOKEN_URL` — OAuth token endpoint
- `ENTRA_CLIENT_ID` — `cc5ebeca-b7ba-4449-bfa7-847160f69640`
- `ENTRA_IDENTIFIER_URI` — `api://finance-master-data-import-Global`

## Remaining Steps

1. **Deploy WASM to S3**: Run deploy workflow (`deploy-image-to-dev.yml`) to extract WASM OCI image and sync to S3
2. **Entra ID redirect URI**: Add `https://doogokq33npvz.cloudfront.net/authentication/login-callback` in platform-multicloud
3. **ALLOWED_ORIGIN**: May need to set on Lambda for CORS (currently permissive when unset; single-origin deployment shouldn't need it)

## Deferred
- **Custom domain + ACM cert**: Blocked on Platform confirming Route53 zone. Resolves Orca findings #1 (default SSL cert) and #3 (old TLS protocols).
- **Shield Advanced**: Not used anywhere in HavenEngineering org. Org-wide $3k/month decision.

## CI/CD Workflows

**Workflow: `build-and-publish-image.yml`** (PR/branch builds):
- Parallel jobs: `build-and-push-lambda` + `build-and-push-wasm`
- Tags: `sha-{12char}` + `pr-{N}-{run}` or `branch-{slug}-{run}`

**Workflow: `build-and-release-image.yml`** (semver releases from main):
- Parallel jobs: `build-and-push-lambda` + `build-and-push-wasm`
- Tags: `v{M.m.p}` + `sha-{12char}`
- Single git tag for both artefacts

**Workflow: `deploy-image-to-dev.yml`** (deploy from single `image-tag` input):
- Lambda: `aws lambda update-function-code`
- WASM: extract from OCI image → `aws s3 sync` → CloudFront invalidation
  - `_framework/*` → `Cache-Control: public, max-age=31536000, immutable`
  - Everything else → `Cache-Control: no-cache`
  - `--delete` flag removes stale files
- WASM steps gated on S3 bucket existing

## File Reference

| File | Purpose |
|------|---------|
| `dev/master-data-import-cdn/main.tf` | CloudFront distribution, S3 buckets, S3 OAC, Lambda permissions |
| `dev/master-data-import-cdn/waf.tf` | WAF Web ACL (rate limit + managed rules) |
| `dev/master-data-import-cdn/providers.tf` | `aws.us_east_1` alias for WAF |
| `dev/container-lambdas/lambdas.tf` | Lambda definition with function URL + env vars |
| `.github/workflows/deploy-image-to-dev.yml` | WASM extract + S3 sync + CF invalidation |
| `src/Haven.Finance.MasterDataImport.Lambda.Harness/Program.cs` | Health endpoint, JWT auth config |
