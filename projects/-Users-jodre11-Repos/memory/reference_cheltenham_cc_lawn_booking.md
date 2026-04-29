---
name: Cheltenham CC lawn booking system
description: External booking system the club uses to reserve lawns for fixtures and roll-ups
type: reference
originSessionId: c60b67c7-dc00-4eb7-a591-ace8efa167d9
---

Cheltenham CC uses an external "MRBS-style" booking system at:

**https://croquetbooking.com/book/index.php?site=6**

Login is required (the user is signed in as `Christian Haddrell` in his Chrome session). Site ID is `6` for Cheltenham CC.

## Session model

Each day is divided into **three fixed sessions** (booked as a whole, not by minute):

| Session | Times |
|---|---|
| Morning | 09:30 – 13:00 |
| Afternoon | 13:00 – 16:30 |
| Evening | 16:30 – dusk |

A full **AC match** (~3½ hrs) is a natural one-session booking. A **GC match** (~2 hrs) easily fits within a session, and members commonly take the back end of a session because earlier games tend to finish early.

## Lawns

11 lawns, each split into a `p` (primary) and `s` (secondary) half for double-banking — so 22 bookable slots per session. **Byelaw 5: Lawns 1 & 8 are reserved exclusively for club competitions** — block matches should preferentially go on those.

Sunset on 28 April 2026 was 20:27, giving ~4hr of evening play; expect later sunsets through summer.

## URLs

- Day view (whole site): `index.php?view=day&view_all=1&page_date=YYYY-MM-DD&area=1&room=1&site=6`
- New booking: `edit_entry.php?view=day&year=YYYY&month=M&day=D&area=1&room=<lawn>&period=<0|1|2>&site=6` (period 0=Morning, 1=Afternoon, 2=Evening; `room` numbers map to lawn halves, e.g. 1=Lawn 1p, 2=Lawn 1s).

How to apply: When suggesting fixture times, talk in terms of these three sessions. When asked to find availability, navigate via Playwright (the user authenticates in his own Chrome) — the page has an HTML grid of `Create a new booking` links per (lawn × session) cell.
