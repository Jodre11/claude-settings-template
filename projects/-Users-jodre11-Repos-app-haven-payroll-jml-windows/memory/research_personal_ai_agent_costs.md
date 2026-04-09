---
name: Personal AI Agent Cost Research
description: Cost analysis of running OpenClaw/NanoClaw as a personal AI assistant backed by Opus 4.6, with model routing strategies and comparisons to Claude Code subscription plans
type: project
---

## Context (2026-04-07)

User is exploring running a self-hosted personal AI agent (OpenClaw or NanoClaw) backed by Claude
Opus 4.6, potentially alongside Claude Code for coding work. Research triggered by reviewing Claude
Code usage stats: **32.2M tokens, 390 sessions, 46 active days over 83 days**.

## Claude Code Usage Cost (Opus 4.6)

Opus 4.6 pricing (as of 2026-04-07): **$5/MTok input, $25/MTok output**.
(Note: Opus 4.1 was $15/$75 — Opus 4.6 is 3x cheaper.)

Cache pricing: write $6.25/MTok (5min) or $10/MTok (1hr), read $0.50/MTok.

Estimated cost for 32.2M tokens (3:1 input:output ratio):
- No caching: ~$321
- With heavy caching: ~$255

**Why:** Evaluating whether individual API or Max subscription plans are better value.

**How to apply:** Compare against subscription plans and alternative model providers when making
purchasing decisions.

## Subscription Plan Comparison

| Plan | Price/mo | 83-day cost | Verdict |
|---|---|---|---|
| Pro ($20) | $20 | $56 | Too restrictive for this volume |
| Max 5x ($100) | $100 | $280 | Viable, may throttle peak days |
| Max 20x ($200) | $200 | $560 | Overkill — 2x API cost |
| API with caching | ~$93/mo | $255 | Cheapest option |

## OpenClaw & NanoClaw

- **OpenClaw** (350K stars, MIT, TypeScript) — full-featured personal AI agent gateway. Connects
  20+ messaging platforms (WhatsApp, Telegram, Slack, Discord, etc.) to LLM APIs. Skills platform,
  browser control, cron jobs, Canvas. Heavy (~500K lines of code).
- **NanoClaw** (27K stars, MIT, TypeScript) — lightweight alternative built on Anthropic's Agent
  SDK. Container-isolated, per-group `CLAUDE.md` memory, simpler architecture. Connects same
  messaging platforms.

Both are self-hosted, always-on, single-user agents. Infrastructure cost is negligible (Node.js
process, ~$0–10/mo hosting). The real cost is LLM API calls.

## Model Routing Architecture

Smart routing pattern: cheap model handles simple requests, escalates complex ones to Opus.

```
You → Agent → Router (Haiku $1/$5) → Simple? → DeepSeek V3.2 ($0.20/$0.77)
                                    → Complex? → Opus 4.6 ($5/$25)
```

### Routing approaches considered:
1. **Classify-then-route** — Haiku classifies, never generates. ~$0.005/call.
2. **Try-then-escalate** — DeepSeek attempts, escalates on uncertainty. Most accurate.
3. **Category-based** — Hardcoded rules (coding→Opus, chat→DeepSeek). Simplest.
4. **Hybrid** — Haiku classifies + DeepSeek self-assessed confidence. Best balance.

### Cost impact (30M tokens/month personal assistant):

| Strategy | Monthly cost |
|---|---|
| All Opus | ~$280 |
| All DeepSeek | ~$12 |
| Router (20% → Opus) | ~$68 |
| Router (10% → Opus) | ~$40 |

### Failure modes:
- Over-escalation: costs money (acceptable)
- Under-escalation: bad quality (retry with Opus)
- Confident-but-wrong: hardest to catch — mitigate with category rules for code/finance/facts

## Aider Benchmark Reference (Polyglot Coding)

| Model | Score | Cost/run |
|---|---|---|
| Claude Opus 4 (32k thinking) | 72.0% | $65.75 |
| DeepSeek R1 (0528) | 71.4% | $4.80 |
| DeepSeek V3.2 | 70.2% | $0.88 |
| Claude Sonnet 4 (32k thinking) | 61.3% | $26.58 |
| Qwen3 32B | 40.0% | $0.76 |

DeepSeek V3.2 achieves 97% of Opus's coding score at 4% of the cost.

## Combined Setup Estimates (Claude Code + Personal Agent)

| Scenario | Monthly cost |
|---|---|
| Conservative (current coding + light personal) | $120–150 |
| Heavy (current coding + frequent personal) | $200–300 |
| Optimised (Opus for coding, routed for personal) | $80–120 |

## Open Questions for Follow-Up
- Does OpenClaw or NanoClaw have built-in model routing / multi-model support?
- OpenRouter has built-in routing — could it serve as the router layer?
- How well does DeepSeek V3.2 handle agentic tool-use vs pure text generation?
- What's the actual quality gap for personal assistant tasks (not just coding benchmarks)?
