---
name: Disable merge queue, keep required checks
description: Want required status checks on main without the merge queue — change in platform-github Terraform
type: project
originSessionId: 675fc1f8-006f-447d-9b0a-b1f7938317bf
---
Keep required CI jobs (macOS, Windows, InspectCode x2, Copilot review) as branch protection checks, but disable the merge queue.

**Why:** The merge queue re-runs all required checks against the merged commit, adding ~10 minutes on top of already-passed CI. For a repo with 1–2 contributors this is unnecessary overhead — standard branch protection with required checks is sufficient.

**How to apply:** Change needs to be made in `HavenEngineering/platform-github` → `repos/foundation/app-haven-payroll-jml-windows.yaml`. Remove or disable the `merge-queue` block while keeping `required-checks` in the branch protection config. This is a Terraform-managed repo so the change goes through the Platform team's PR process.
