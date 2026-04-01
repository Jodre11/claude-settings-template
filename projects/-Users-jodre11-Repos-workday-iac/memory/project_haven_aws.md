---
name: Haven AWS deployment conventions
description: AWS region and deployment patterns for Haven infrastructure
type: project
---

Default AWS region is **eu-west-2** (London). Always eu-west-2 unless a specific resource type is unavailable there, in which case eu-west-1 is used as fallback.

**How to apply:** Don't ask about region — use eu-west-2. If a Terraform resource or AWS service isn't available in eu-west-2, note the constraint and use eu-west-1.
