---
name: GPU cloud rental providers
description: Comparison of GPU cloud providers for ad-hoc AI/ML workloads — pricing, friction, reliability; RunPod preferred
type: reference
originSessionId: f93d2a9a-1baf-4f68-ac92-5816fbe90735
---
## Recommended: RunPod

- Per-second billing, no auction/bidding
- 200+ pre-built templates, good UI, Docker/SSH/Jupyter
- Secure Cloud ~99.5% uptime, 31+ regions
- A100 80GB: ~$1.39–1.99/hr | H100 80GB: ~$1.99–2.49/hr (Apr 2026)
- Workflow: sign up → add credit → spin up pod with PyTorch template → SSH in → destroy when done

## Alternatives

| Provider | A100 80GB/hr | H100 80GB/hr | Billing | Notes |
|----------|-------------|-------------|---------|-------|
| **Lambda Labs** | $1.29–2.49 | $2.49 | Per-hour | Own data centres, ML-focused support, US-only. Per-hour billing wastes money on short jobs. |
| **SynpixCloud** | $1.39 | — | — | Cheapest A100 found Apr 2026; not widely reviewed. |
| **Northflank** | $1.76 | $2.74 | — | Mid-range pricing. |
| **Vast.ai** | $1.20–2.00 | $3.29 | Per-second | Peer-to-peer marketplace. Cheapest consumer GPUs ($0.07/hr RTX 3090). **Avoid** — user experienced repeated preemption/outbidding on good-value servers. |

## Avoid for ad-hoc jobs

Hyperscalers charge 3–6x more for the same hardware:
- AWS H100: ~$12.29/hr on-demand
- Azure H100: ~$6.98/hr
- GCP H100: ~$14.19/hr

Only justified for enterprise compliance requirements.

## Talking head / avatar platforms (related)

For real-time AI avatar workloads specifically (e.g. Ditto + LiveKit), an A100 on RunPod at ~$1.40/hr is sufficient. ~$0.50 for a 20-minute session.

*Prices as of April 2026 — verify before renting.*
