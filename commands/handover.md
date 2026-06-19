---
description: Write a phase-handover artifact so a fresh session can resume this work
---

You are at a phase seam (end of brainstorming, planning, or an implementation
phase) and the user wants to reset context and continue in a clean session.
Your job is to write a **handover artifact** that a fresh session will read via
`/rehydrate` to regain context — and to do it accurately, because the handover
is lossy and a thin or wrong one is the only real failure mode of this workflow.

## Where the file goes

Resolve the path — do not guess it:

```bash
bash ~/.claude/scripts/handover-path.sh
```

That prints the absolute path (under `~/.claude/handovers/`, keyed by git repo
root or cwd). Write the artifact there, overwriting any existing handover for
this directory (a new phase supersedes the old one).

## Record the reconciliation fingerprint

The fingerprint is how `/rehydrate` later decides whether the repo has drifted.
Capture current state — committed **and** uncommitted, because a whole phase can
pass with no commit:

```bash
git rev-parse --show-toplevel    # repo root (fails if not in a repo → path mode)
git branch --show-current
git rev-parse HEAD
git status --porcelain           # the dirty/untracked fingerprint — load-bearing
```

If `git rev-parse --show-toplevel` fails, you are in **path mode** (a parent or
non-repo directory): there is no working tree to fingerprint, so record the
absolute paths/files the work touched instead, and note that reconciliation will
be trust-the-file.

## Artifact format

Write Markdown with this front matter and body. Keep `status: active`.

```markdown
---
status: active
mode: repo            # or: path
generated: <ISO-8601 you compute, e.g. via `date -u +%Y-%m-%dT%H:%M:%SZ`>
branch: <branch or "-">
head: <HEAD sha or "-">
dirty: |
  <verbatim `git status --porcelain` output, or "-" if clean / path mode>
---

# Handover: <one-line what-this-work-is>

## Phase just completed
<which superpowers phase, and the key decisions/outcomes of it>

## Done
<concrete, checkable bullets — what is actually finished and verified>

## Next
<the immediate next steps for the resuming session, as checkable claims>

## Verify first
<specific things the fresh session should check against the repo before
resuming — files to read, tests to run, what "clean" looks like. For path mode,
list the exact files/dirs to spot-check.>

## Context the repo doesn't carry
<intent, constraints, rejected approaches, why — anything not recoverable by
reading code or git log>
```

## After writing

1. Show the user the drafted artifact and its path.
2. **Stop and let them review it** — do not auto-clear or end the session. The
   handover being lossy is the one risk that warrants a human check; a few
   seconds of review is the point.
3. Tell them: review, then `/clear` (or restart to pick up an update); the
   SessionStart hook will detect the handover and prompt the fresh session to
   `/rehydrate`.

Do not retire or mark anything `consumed` here — that happens at `/rehydrate`
time when the work is confirmed done.
