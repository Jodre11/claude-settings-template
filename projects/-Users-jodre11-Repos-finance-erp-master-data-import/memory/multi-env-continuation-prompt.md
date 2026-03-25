# Multi-Environment Continuation Prompt

Copy-paste this to resume after clearing context:

---

Continue executing the multi-environment infrastructure plan. Read memory for full context.

**Plan:** `docs/superpowers/plans/2026-03-23-multi-environment-infrastructure.md`
**Spec:** `docs/superpowers/specs/2026-03-23-multi-environment-design.md`

**Where we left off:** Tasks 1 and 2 are done (PRs created, Copilot review comments addressed). Waiting for human reviewers to approve and `/apply`.

**Completed:**
- Task 1 (PR A): platform-multicloud #25 — staging + prod Entra ID app registrations. Branch `feat/master-data-import-entraid-staging-prod`. Copilot comments fixed (missing `_environment.tf` symlinks, renamed `prod_users` to `users` in staging).
- Task 2 (PR B): finance-terraform #563 — staging + prod S3 buckets. Branch `feat/master-data-import-s3-staging-prod`. Copilot comments fixed (removed localhost from prod CORS).
- Deployed v0.2.0 to dev for demo (workflow run 23479546738) — check if it succeeded.

**What's next:**
1. PR #8 still needs merging (user handles via platform — branch protection)
2. Wait for PR A (#25) to be applied — need `application_id` outputs (staging + prod Entra client IDs)
3. Wait for PR B (#563) to be applied
4. Then Task 3 (PR C): Lambda bootstrap in `staging/container-lambdas/` + `prod/container-lambdas/` — needs the client IDs from PR A
5. Tasks 4-8 follow the dependency chain in the plan

**Key facts:**
- finance-terraform PRs need Platform + SRE review (NOT self-owned)
- platform-multicloud needs Platform review
- platform-terraform default branch is `master` (not `main`)
- Prod S3 CORS has no localhost (intentional — removed per review)
- Staging Entra ID: both Dev + Users groups; Prod: Users group only
- Staging oauth2 scope UUID: `8f5d0fc5-7595-475c-bb96-eae5b776e8b8`
- Prod oauth2 scope UUID: `dd46944b-a6be-4a6c-80bf-3613ca0a0e37`

---
