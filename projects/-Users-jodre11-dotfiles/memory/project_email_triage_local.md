---
name: Self-hosted email triage
description: Plan to build a private email classification pipeline using n8n + Ollama to replace SaneBox without sending email content to third parties
type: project
originSessionId: 7af688dc-5cc0-4eb4-b390-f237e17d62fa
---
Self-hosted email triage pipeline using n8n + Ollama — own-time project.

**Why:** SaneBox and similar services necessarily read email content server-side. User wants AI-assisted inbox sorting with no data leaving the local network.

**How to apply:** Preferred stack is n8n (IMAP polling, workflow orchestration) + Ollama (local LLM classification). A small model (Phi-3, Llama 3 8B) is sufficient for email triage. Could run on the NVIDIA dev box if acquired, but CPU inference is viable for this workload. Also do GitHub notification settings cleanup (uncheck email for Participating/Watching, keep weekly Dependabot digest only) and mark the 25k unread backlog as read.
