---
name: Site follow-ups deferred from build #001 post
description: Concrete site improvements identified during the build #001 post brainstorm but deliberately not included in that post — to revisit later
type: project
originSessionId: f7d3d43c-8cc5-4ff2-8b1a-8278c2a8b139
---
Surfaced during the brainstorm for build post #001 (`001-haddrell-from-scratch`)
on 2026-04-20. The post itself only flags two gaps (per-post OG images, link
checker in CI). The items below were identified as worth doing but cut from
the post — either because they are infra-level (not visible to a site reader)
or because they are content roadmap items.

The user explicitly asked to "remember the other gaps" so they can be revisited.

## DNS hygiene on `haddrell.co.uk` (post-Cloudflare migration)

- **Stale `CNAME 24324387 → google.com`** — flagged in `CONTEXT.md` as a
  likely-stale Search Console record while the zone was still on GoDaddy. Now
  that the zone is on Cloudflare (since 2026-04-17), confirm whether the
  record was preserved deliberately or can be dropped.
- **DMARC escalation** — currently `p=none` (monitor-only). Per the existing
  M365 Family SKU constraints, the documented ceiling is `p=quarantine` (never
  `p=reject` — DKIM is unavailable on this SKU). After several weeks of clean
  `rua` reports, escalate to `p=quarantine`. Set a calendar reminder rather
  than leaving this parked indefinitely.

**Why:** small loose ends from the GoDaddy → Cloudflare migration that the
user wants tracked but not surfaced on the public site.

**How to apply:** when next working on DNS or email infrastructure for the
domain, raise these as candidate work items.

## Future build post — agentic-development angle for `/builds`

PLAN.md flagged this as deferred: an agentic-development write-up for `/builds`
including raw session transcripts and curated diffs as a differentiator. Build
#001 deliberately stays at narrative level; this would be a separate, deeper
build post (likely `002-…` or later).

**Why:** the differentiator content for this site is the *method* of building
with agentic tools, but layering raw transcripts into `001` would have made
that post too long. Worth its own dedicated piece.

**How to apply:** when scoping the next build post, consider whether this is
the right slot — or whether `002` should cover a different personal project
first and the transcripts piece comes later.

## Explicitly NOT a follow-up

- **About page sparseness** — three short paragraphs is intentional. LinkedIn
  carries the detailed profile. Do not "improve" the about page on this basis.
