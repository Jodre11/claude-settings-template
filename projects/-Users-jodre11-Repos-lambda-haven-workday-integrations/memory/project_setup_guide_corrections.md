---
name: Setup guide corrections needed
description: Corrections to docs/workday-api-setup-guide.md — wrong domain name, missing ISSG policies, missing refresh token regeneration step
type: project
originSessionId: 600d8b8d-a9d5-4ab7-936a-e343e6ded197
---
## Corrections for `docs/workday-api-setup-guide.md`

### 1. Wrong domain name in Part 4.3
The guide says "Set Up: Provisioning Groups" — this domain does not exist in the tenant. The correct name is **Account Provisioning** (System functional area). Confirmed via Microsoft Entra/Workday integration docs and GUI screenshots.

### 2. Missing domain security policies
Part 4 only lists a subset. The full list of 12 policies needed on `ISSG_WD_Account_Provisioning` should be documented (see `project_workday_sandbox_validation.md` for the complete table).

### 3. Missing refresh token regeneration step
After changing API client scopes or enabling "Include Workday Owned Scope", existing refresh tokens do NOT inherit the new scopes. The guide should include a step to regenerate the refresh token via "Generate Refresh Token for Integrations" and update Secrets Manager.

### 4. WQL query guidance
The guide should note that `entryMoment` (FROM clause parameter) is the correct mechanism for incremental queries, not `lastModified` (which doesn't exist). Field aliases should be discovered via `GET /dataSources/{ID}/fields`.

**Why:** These corrections prevent the same troubleshooting cycle when setting up staging/prod tenants.

**How to apply:** Update the guide before merging PR #2 or as a follow-up commit.
