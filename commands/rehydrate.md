---
description: Resume work from a phase-handover artifact, reconciling against the repo first
---

A handover artifact may exist for this directory. Your job is to regain context
from it **and verify it against current reality before acting** — the handover
is a snapshot frozen when it was written; the repo is ground truth now.

## 1. Locate and read

```bash
bash ~/.claude/scripts/handover-path.sh
```

Read the file at that path. If it does not exist, tell the user there is no
handover for this directory and stop. If its front-matter `status` is not
`active`, say so and ask whether to proceed anyway.

Once you have read it, name the session window from the handover's subject so a
long resume isn't labelled "rehydrate". Take the text of the `# Handover: <…>`
title line and pass it to the helper (no-ops cleanly outside tmux or on a
manually-renamed window):

```bash
~/.claude/scripts/set-session-topic.sh "<the handover title text>"
```

## 2. Reconcile — the load-bearing step

Recompute the fingerprint and compare it to what the handover recorded. **A
matching HEAD is not enough** — a whole phase can change the working tree with
no commit, so you must compare the dirty state too.

```bash
git rev-parse --show-toplevel    # if this fails → path mode (see below)
git branch --show-current
git rev-parse HEAD
git status --porcelain
```

**Repo mode** — branch + HEAD + `git status --porcelain` all reproduce the
handover's fingerprint:

- **Identical** → fast-path clean. Nothing changed (clearing the session does
  not touch the working tree, so this is the normal case). Resume.
- **Differs** (a commit landed, or local-only edits) → do **not** shortcut. Read
  the files the handover names under "Verify first" / "Next" and check its
  claims against current content. Resume only if the changes are consistent with
  the handover (e.g. you made the edits it expected); **stop and ask** if they
  contradict it (e.g. it says "implement auth" but auth is already done and tests
  pass — the handover is spent).

**Path mode** — `git rev-parse --show-toplevel` failed (parent/non-repo dir):
there is no working tree to fingerprint. This is **trust-the-file** mode. Read
the specific files/paths the handover names, sanity-check that its claims still
hold, and resume — but you cannot give the strong guarantee repo mode gives.

## 3. Disclose the mode — always

State plainly which reconciliation you performed, so a weak check never
masquerades as a strong one. For example:

- "Reconciled against the working tree, fingerprint matches — resuming."
- "HEAD matches but there are local changes since the handover; I checked
  `src/auth.ts` and they're consistent with its 'Next' steps — resuming."
- "Handover says next is X, but the repo shows X is committed and tests pass —
  this looks spent. Resume anyway, retire it, or something else?"
- "No git repo here (path mode), so I'm trusting the handover; I read the files
  it names and they look consistent — resuming."

## 4. Retirement

When the work the handover covers is confirmed **done** (this phase complete,
nothing left to resume), mark it consumed so the SessionStart sweep removes it:
edit the artifact's front matter `status: active` → `status: consumed`. The next
`/handover` for this directory would also overwrite it. Leave it `active` if the
phase is still in progress.
