---
name: Cloudflare deployment details
description: haddrell-blog Cloudflare Workers account, worker URL, and custom domain binding
type: reference
originSessionId: 17cf70f6-038d-450f-9895-bd48f11939c5
---
- **Cloudflare account:** `christian@haddrell.co.uk` (personal, free plan)
- **Worker URL:** `haddrell-blog.christian-d5a.workers.dev`
- **Custom domain:** `www.haddrell.co.uk`
- **Build:** `npm run build` → `wrangler.toml` points at `./dist`
- **Auto-deploy:** pushes to `main` on GitHub trigger a build
