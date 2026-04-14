---
name: PII in user data directory
description: The application's data directory (~/.jml-payroll) contains employee PII in reference data and import files — never claim the app stores no sensitive data
type: project
originSessionId: e48012d1-2169-4726-8310-f2ee7f159f5d
---
The Payroll JML application's user data directory (`~/.jml-payroll/reference-data/`) contains CSV
files with employee PII (names, pay rates, tax codes, NI numbers, etc. from `LiveEmployees.csv`,
`PayRates.csv`, and similar). The import files being processed also contain employee PII.

**Why:** The app processes payroll data for Workday — PII is inherent in the workflow. An earlier
draft of the IT deployment ticket and GitHub issue incorrectly stated "The application does not
store credentials or sensitive data." This was corrected on 2026-04-14.

**How to apply:** In any deployment documentation, security notes, or IT communications:
- State that the app does not store *credentials*
- Explicitly note that the user's data directory contains employee PII
- Recommend restricting application access to authorised payroll team members
- Never claim the application stores no sensitive data
