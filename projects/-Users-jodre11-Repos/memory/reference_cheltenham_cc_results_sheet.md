---
name: Cheltenham CC results spreadsheet
description: Google Sheet holding Cheltenham Croquet Club's annual internal-competition entries, draws and results
type: reference
originSessionId: c60b67c7-dc00-4eb7-a591-ace8efa167d9
---
Cheltenham CC publishes internal-competition entries, fixtures and results in a public Google Sheet (one workbook per year, "{YEAR} Cheltenham CC Internal Competitions Results").

**2026 workbook:** https://docs.google.com/spreadsheets/d/1XXnAhvwD4L_rryliAV4cdHKfANX7Hav9GEV1tYwsufQ/edit

- Publicly readable — no auth needed.
- For programmatic access, use the export endpoints (don't try to parse the canvas-rendered web view):
  - Single sheet as CSV: `https://docs.google.com/spreadsheets/d/<ID>/export?format=csv&gid=<GID>`
  - Whole workbook as XLSX: `https://docs.google.com/spreadsheets/d/<ID>/export?format=xlsx`
- Workbook contains ~35 sheets covering AC and GC singles blocks/KOs, doubles (Curtis Webb, Barwell Salvers / GC Doubles), handicap competitions, Rabbits, MacKay, Sturdy Seniors, Short Croquet, One-Ball, etc., plus winter equivalents.
- Block sheets list entrants by name; KO sheets are populated from block winners as the season progresses.
