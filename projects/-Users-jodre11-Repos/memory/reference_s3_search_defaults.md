---
name: S3 search defaults
description: Default AWS profile, bucket, and region for the s3-search skill — used by the s3-search plugin when querying S3 buckets
type: reference
---

Default settings for `s3search` CLI commands:

| Setting | Value |
|---------|-------|
| Profile | `finance-prod-elevated` |
| Bucket | `haven-finance-source-data-prod` |
| Region | None (inherited from profile — resolves to `eu-west-1`) |

When authentication fails, tell the user to run:
`aws sso login --profile finance-prod-elevated`
