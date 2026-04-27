---
name: OCI account and deployment setup
description: Oracle Cloud account details, region, and deployment approach for the SearXNG instance
type: project
originSessionId: 4f9d12d4-2136-4d57-b494-bcde54ee8750
---
Self-hosted SearXNG on Oracle Cloud Always Free tier (VM.Standard.A1.Flex, 4 OCPUs, 24 GB RAM).

- OCI account: christian47, region eu-stockholm-1
- Credentials stored in Bitwarden item "OCI - cloud-searxng", loaded via `source scripts/env.sh`
- PEM key written to ~/.oci/oci_api_key.pem
- PAYG upgrade submitted 2026-04-27 (may take time to process; ARM instance provisioning may fail until approved)

**Why:** Free-tier ARM instance for running SearXNG search engine, accessed via Tailscale.
**How to apply:** If provisioning fails with capacity/quota errors, likely the PAYG upgrade hasn't completed yet — advise waiting and retrying.
