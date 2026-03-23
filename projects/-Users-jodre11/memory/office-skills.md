# Office Document Skills

Installed from https://github.com/tfriedel/claude-office-skills (commit df9ce6b, 2025-10-04).
Installed 2026-03-18 into `~/.claude/skills/office-{pptx,docx,pdf,xlsx}/`.

## Key facts
- Local copy, no auto-update from upstream
- `skills-system.md` excluded (pseudo-system-prompt, cloud sandbox paths)
- Security patches applied: zip-slip, XXE (defusedxml + lxml hardening), html2pptx path traversal
- Each skill directory has a `PROVENANCE.md` with details
- Dependencies: python-pptx, openpyxl, pypdf, defusedxml, lxml, Pillow, pdf2image, markitdown, pptxgenjs, playwright, sharp
- System tools needed: LibreOffice (soffice), Poppler (pdftoppm), Pandoc
