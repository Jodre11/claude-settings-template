# Provenance

- Source: https://github.com/tfriedel/claude-office-skills
- Upstream commit: df9ce6b (2025-10-04)
- Installed: 2026-03-18
- `skills-system.md` intentionally excluded (pseudo-system-prompt, incorrect paths)

## Security patches applied

1. **Zip-slip protection** on all `zipfile.extractall()` calls
2. **XXE protection** — replaced `xml.etree.ElementTree` with `defusedxml.ElementTree` in `redlining.py`
3. **XXE protection** — all `lxml.etree.parse()` calls use `resolve_entities=False, no_network=True`
4. **Path traversal protection** — `html2pptx.js` validates image paths stay within HTML file's directory
