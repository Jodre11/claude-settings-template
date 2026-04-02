---
name: Check memory before invoking skills
description: When a request seems like it could relate to ongoing work, check memory before launching into skill workflows
type: feedback
---

When the user gives a request that could relate to in-progress work, check MEMORY.md first before
invoking skills like brainstorming. The memory may reveal that the request is a continuation of
prior work (e.g. a test of a fix), not a new greenfield task.

**Why:** User asked to create an agent team to test a tmux fix, but I launched the brainstorming
skill and created 8 tasks instead of just dispatching the team. The memory clearly indicated this
was a test of the split-pane fix.

**How to apply:** Before invoking any skill, scan MEMORY.md for related context. If the request
maps to an existing project memory, act on that context directly rather than treating it as a new
design exercise.
