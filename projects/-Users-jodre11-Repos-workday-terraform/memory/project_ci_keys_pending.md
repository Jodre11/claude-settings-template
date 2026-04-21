---
name: Strongbox CI setup complete
description: Strongbox keyring and master key configured for CI — committed 2026-04-17, awaiting CI confirmation
type: project
originSessionId: 365a7c0f-a231-4a38-8c62-ead844d74573
---
Strongbox CI setup completed on 2026-04-17:

1. **`scripts/.strongbox_keyring`** — committed encrypted (manual encryption via `strongbox -clean` due to git filter not invoking on `git add -f`).
2. **`STRONGBOX_MASTER_KEY`** — added as GitHub repo secret.
3. **`scripts/.gitattributes`** and **`scripts/.strongbox-keyid`** — committed.

**Why:** CI secrets-manager module plans were failing with `Must provide a -key when using -decrypt`.

**How to apply:** If CI still fails on secrets-manager modules, check the master key value matches. Note: the git clean filter didn't work with `git add -f` (likely a git bug — force-adding ignored files may skip filter processing). If the keyring needs updating in future, use this hack to pre-encrypt before staging: `strongbox -clean scripts/.strongbox_keyring < scripts/.strongbox_keyring > /tmp/keyring_enc && cp /tmp/keyring_enc scripts/.strongbox_keyring`. Worth revisiting properly if the keyring needs frequent updates.
