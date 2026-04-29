---
name: Cheltenham CC contact list (CSV)
description: Local CSV with names, phone numbers, emails, and AC/GC/Short handicaps for all Cheltenham CC players
type: reference
originSessionId: c60b67c7-dc00-4eb7-a591-ace8efa167d9
---
The user keeps the club's contact list as a CSV in `~/Downloads/`, named `YYYY_M_D_CCC_Contacts.csv` (e.g. `2026_4_8_CCC_Contacts.csv` for the 8 April 2026 issue). A new dated file is published periodically; pick the most recent matching `*_CCC_Contacts.csv` rather than hard-coding a date.

**Columns:** `First name, Last name, Home, Mobile, Office, Email, AC, GC, Short`
- `AC` / `GC` / `Short` columns hold each player's handicap in that format (lower = stronger). Empty means the player doesn't play that format or has no handicap recorded yet.
- Surnames in the contact CSV are uppercase (e.g. `HADDRELL`), matching how the results spreadsheet renders them — useful when cross-referencing.

How to apply: When the user asks who someone is, what their handicap is, who their partner is, or for a phone/email — read this CSV first. For matchmaking/handicap context across competitions, join this CSV with the relevant sheet from the results workbook (see `reference_cheltenham_cc_results_sheet.md`).
