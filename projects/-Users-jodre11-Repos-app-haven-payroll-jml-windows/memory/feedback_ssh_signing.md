---
name: SSH signing works via Bitwarden agent
description: Git commit signing uses Bitwarden SSH agent — ssh-add -l does NOT show Bitwarden keys but signing works fine
type: feedback
---

Git commit signing key is served by the Bitwarden SSH agent (`~/.bitwarden-ssh-agent.sock`).
`ssh-add -l` only lists keys from the system SSH agent, NOT Bitwarden-managed keys. This means
the signing key won't appear in `ssh-add -l` output, but `git commit` with signing works fine
because git uses `SSH_AUTH_SOCK` directly.

**Why:** Subagent incorrectly assumed signing was broken because `ssh-add -l` didn't show the
key. It tried to troubleshoot instead of just attempting the commit.

**How to apply:** Never diagnose commit signing as broken based on `ssh-add -l` output. Just
attempt the commit — if it fails, then investigate. Tell subagents not to check `ssh-add -l`
before committing.
