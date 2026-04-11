---
name: S3 CORS origins need updating for custom domains
description: S3 upload bucket CORS allowed_origins are stale — staging/prod use old domains, blocking browser uploads via presigned PUT URLs
type: project
---

**Diagnosed 2026-04-09:** The S3 upload buckets (`finance-master-data-import-{env}`) have stale CORS `allowed_origins` that don't include the new `haven-leisure.com` custom domains. Browser PUT requests to presigned S3 URLs fail with CORS errors.

| Env | Current (broken) | Correct |
|-----|-----------------|---------|
| Dev | `doogokq33npvz.cloudfront.net` + `localhost:7001` | custom domain + CloudFront + `localhost:7001` |
| Staging | `erpx-master-data-import.haven-stage.com` + `localhost:7001` | custom domain + CloudFront |
| Prod | `erpx-master-data-import.haven.com` | custom domain + CloudFront |

**Fix location:** `finance-terraform/{dev,staging,prod}/master-data-import/s3.tf` — `cors_rule` block.

**Why:** The custom domains changed from `haven-stage.com`/`haven.com` to `haven-leisure.com` during the multi-environment rollout, but the S3 CORS origins were never updated.

**How to apply:** Fix alongside the next finance-terraform PR (image_tag update for first staging/prod deploy). All three `master-data-import/` module directories can go in one PR. Dev only needs localhost for Aspire local dev; staging/prod don't need localhost.
