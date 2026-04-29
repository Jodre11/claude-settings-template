---
name: Terraform PR and apply constraints
description: How PRs are applied in workday-terraform — single /apply comment, no dependent modules, independent modules fine together
type: feedback
originSessionId: 651c7128-16e9-46d4-8de4-3e07dc6965cc
---
The Platform team applies a PR by adding a single `/apply` comment. This fires once and applies all Terraform changes in the PR.

**Rules:**
- A PR must not include modules that depend on each other — no ordering is possible within a single apply. If ordered application is required, use separate PRs.
- Independent modules may coexist in a single PR.
- Avoid combining CI workflow changes with Terraform changes (risk of overlooking gate removals enabling unwanted changes).
- Non-Terraform changes (docs, config) can coexist with Terraform changes.

**Why:** This has been a recurring source of confusion. The key insight is that `/apply` is a one-shot action — it applies everything, with no ability to sequence dependent changes.

**How to apply:** When deciding whether to split or combine PRs, ask: "do any modules in this PR depend on the output of another module in this PR?" If yes, split. Otherwise, combine freely.
