---
name: BST timezone awareness
description: AWS timestamps are UTC but local/displayed times are often BST (UTC+1) — always account for this when filtering
type: feedback
originSessionId: f0a5ec31-35e0-4efa-af7e-405332e48786
---
When filtering AWS resources by time (Step Functions executions, S3 versions, CloudWatch logs), timestamps from the AWS CLI are in UTC but the user's local time and some CLI display formats use BST (UTC+1). Always convert explicitly rather than assuming.

**Why:** Twice in the same investigation (April 2026), filtering by the wrong timezone produced incorrect results — first when identifying duplicate batch executions (filtering for 14:46 UTC vs 15:46 BST), then when counting resubmission executions (filtering for 21:10 BST instead of 20:08 UTC). The second error nearly caused 140 files to be resubmitted unnecessarily, recreating the exact duplication problem we were fixing.

**How to apply:** When constructing time-based filters for AWS queries, explicitly note and convert between UTC and BST. The user is in the UK — during British Summer Time (last Sunday in March to last Sunday in October), local time is UTC+1.
