---
name: AWS CLI pagination
description: AWS CLI commands silently truncate results — always paginate or use --no-paginate to avoid undercounting
type: feedback
originSessionId: f0a5ec31-35e0-4efa-af7e-405332e48786
---
AWS CLI commands like `stepfunctions list-executions` default to 100 results per page and silently truncate. Always paginate through all pages or use `--no-paginate` when counting results.

**Why:** During the April 2026 Zonal Complex resubmission, `list-executions` returned 95 of 235 succeeded executions. This was misinterpreted as 140 files failing to process, nearly triggering an unnecessary second resubmission that would have recreated the duplication problem.

**How to apply:** When querying AWS for counts or completeness checks, always loop through `nextToken` pagination. Never trust a single-page result as the full picture. This applies to Step Functions, S3 list-objects, CloudWatch, and most AWS CLI list operations.
