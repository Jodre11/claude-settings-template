---
name: All config in source control
description: User requires all environment config to be in source control, not GitHub settings or external stores
type: feedback
---

All configuration values must be in source control — never in GitHub Environment variables, repo settings, or other external stores that aren't visible in the codebase.

**Why:** User strongly rejected the GitHub Environment variables approach because config stored in GitHub settings is not reviewable, diffable, or auditable in the same way as code. The correction was emphatic: "I want everything in source control."

**How to apply:** When proposing CI/CD config, always use source-controlled files (e.g. `.github/environments.json`) loaded at runtime. Never propose `${{ vars.* }}` or GitHub Environment variables as a config mechanism. Secrets (`${{ secrets.* }}`) are acceptable since they can't go in source control, but non-secret config must be in code.
