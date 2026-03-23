# Orca Security Findings — finance-terraform #538

Triaged 2026-03-13. PR comment posted: https://github.com/HavenEngineering/finance-terraform/pull/538#issuecomment-4053994651

## Findings

### 1. Medium — CloudFront Distribution Using Default SSL Certificate
- **Accurate.** Uses `*.cloudfront.net` default cert.
- Blocked on Platform providing Route53 zone for custom domain.
- When resolved: add `aliases`, `viewer_certificate` with `acm_certificate_arn`, `minimum_protocol_version = "TLSv1.2_2021"`.
- Setting `minimum_protocol_version` with `cloudfront_default_certificate` causes `ValidationException` on apply.

### 2. Low — AWS Shield Advanced Not In Use
- **Accurate, but org-wide.** Shield Advanced is not enabled on any CloudFront distribution across HavenEngineering.
- Shield Advanced: $3,000/month per AWS payer account, 1-year commitment. Not per-resource.
- If already subscribed elsewhere in AWS Organization, adding a distribution costs only data transfer surcharge ($0.025/GB).
- Confirmed via `gh search code "aws_shield" --owner HavenEngineering` — zero results.
- Org-level decision, not PR-scoped.

### 3. Low — CloudFront Distribution Allows Old SSL/TLS Protocols
- **Accurate — consequence of #1.** Default cert forces TLSv1 negotiation.
- No independent fix. Resolves when custom domain + ACM cert is added.

### 4. Low — S3 Bucket Policy Accepts HTTP Requests
- **False positive.** Orca flags inline `policy` on `module.s3_wasm` (only sees `AllowCloudFrontOAC` statement).
- Module has `attach_deny_insecure_transport_policy = true` — module merges deny-insecure-transport via `source_policy_documents`.
- Orca performs static analysis on `.tf` files, cannot resolve Terraform module internals.

### 5. Info — S3 Bucket Server Access Logging is Disabled
- **False positive.** Points at logs bucket (`module.s3_wasm_logs`).
- Logs bucket must not log to itself (infinite loop).
- Data bucket (`module.s3_wasm`) has logging targeting this bucket.
- Orca doesn't follow inter-bucket references.

## Key Learnings
- Orca static IaC analysis cannot resolve `terraform-aws-modules` module internals (e.g., `attach_deny_insecure_transport_policy`)
- Orca doesn't follow inter-resource references (logging bucket → data bucket)
- Always verify Orca findings against actual module behaviour before accepting them
- Shield Advanced pricing is per payer account, shared across AWS Organizations — always check org-wide before dismissing as expensive
- Local repos may be stale; use `gh search code --owner HavenEngineering` for org-wide searches
