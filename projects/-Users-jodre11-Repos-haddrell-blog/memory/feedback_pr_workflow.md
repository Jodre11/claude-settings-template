---
name: Default to PR workflow when branch protection requires it
description: When a repo has PR-required branch protection on main, treat "push it" as "ship it via PR" — do not push straight to main even if the push would succeed via admin override
type: feedback
originSessionId: c93850f7-29f8-4263-8a1a-a63730d647cf
---
Default to PR workflow when the repo has PR-required branch protection.
Treat user shorthand like "push it" as "ship it" — not a literal `git push`
to main.

**Why:** On 2026-04-20, the user said "Push it" after staging the build #001
post. I committed and pushed directly to `main`. GitHub reported
`Changes must be made through a pull request` and
`Required status check "build" is expected` — both bypassed because the user
is repo admin. The user then clarified they had meant a PR and accepted the
result ("Oh well"), but the expectation was PR-first.

**How to apply:**
- Before pushing to a protected branch, check for PR-required rules
  (e.g. via `gh api repos/.../branches/main/protection` or by inspecting a
  dry-run push output).
- If PRs are required, propose creating a feature branch and PR unless the
  user has explicitly authorised direct-to-main for this change.
- If a push reports "Bypassed rule violations", surface that BEFORE acting —
  do not silently push through admin overrides.
- Existing workflow preferences (CLAUDE.md): no Co-Authored-By trailers; no
  Claude Code advertising in PR bodies; PR descriptions lead with a brief
  contextual summary for non-technical readers.
