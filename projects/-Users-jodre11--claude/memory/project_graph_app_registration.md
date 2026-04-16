---
name: Graph app registration blocked
description: Entra ID app registration PR for delegated Graph access is closed pending security restriction resolution by John Hegarty
type: project
originSessionId: 56b87ff9-a280-4409-b850-e3c0ec851993
---
PR HavenEngineering/platform-iamldap#799 closed 2026-04-15 due to a security restriction blocking new app registrations.

- **Branch:** `entraid_graph_delegated_haddrellc` (still exists on remote)
- **Repo:** `HavenEngineering/platform-iamldap`
- **Folder:** `iamazure/entraid_graph_delegated_haddrellc`
- **Display name:** "Agentic Office Access - Christian Haddrell"
- **Scopes:** User.Read, Mail.Read, Calendars.Read, Chat.Read (all delegated)
- **Owner UPN:** christian.haddrell@haven.com
- **Blocker:** Security restriction on new app registrations; John Hegarty is working on resolving it
- **Post-apply step:** `az ad app update --id <application_id> --is-fallback-public-client true`

**Why:** This app registration enables agentic tooling (Claude Code skills/CLI) to access Graph API for mail, calendar, and Teams chat via delegated permissions.

**How to apply:** Once John Hegarty confirms the blocker is resolved, reopen the PR with `gh pr reopen 799` in the `platform-iamldap` repo. No code changes needed — the branch is ready.
