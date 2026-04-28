---
name: Get-group verification endpoint blocked on security activation
description: /get-group Harness endpoint built but blocked on Workday ISSG permission — needs ISU added to AD integration's ISSG and activation, expected Monday 2026-04-28
type: project
originSessionId: f67a9b29-1f83-46f4-a293-de7325c3dd86
---
Built a `/get-group` Harness endpoint that calls `Get_Workers` SOAP with `Include_Account_Provisioning`
to read back provisioning group assignments for specific employee IDs. Code is working but blocked on
Workday domain security.

**Issue:** ISSG_WD_Account_Provisioning has "Worker Data: Workers" as View Only (Report/Task permission),
not Get (Integration Permission). `Get_Workers` SOAP requires Get integration access.

**Chosen fix:** Add ISU_WD_Account_Provisioning into the AD integration's ISSG (which already has the
needed Get permissions). An ISU can belong to multiple ISSGs — permissions are unioned. This avoids
modifying domain security policies on our ISSG.

**Blocker:** Adding ISU to ISSG requires "Activate Pending Security Policy Changes" which needs the admin
team. Expected availability: Monday 2026-04-28.

**Also pending:** Jon White checking whether the four workers (175601, 175088, 177222, 177839) are now
showing "Network Access" after the `/set-group` call on 2026-04-25.

**How to apply:** Once activated, rebuild the Harness and test `/get-group` with those four employee IDs.
If it works, the endpoint becomes the verification mechanism for all future provisioning runs.
