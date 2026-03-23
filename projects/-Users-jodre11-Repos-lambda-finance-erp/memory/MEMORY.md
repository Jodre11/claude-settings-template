# Memory Index

- [otel-collector-investigation.md](otel-collector-investigation.md) — OTLP collector investigation for PR #93

# Workflow

## Terraform
- Always run `terraform fmt` on changed `.tf` files before committing. CI runs `tf fmt -check` and will fail otherwise.
- Do NOT merge finance-terraform PRs — the platform team reviews and merges them. Just create the PR and leave it for their review.
