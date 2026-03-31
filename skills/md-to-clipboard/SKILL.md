---
name: md-to-clipboard
description: Use when the user wants to share Markdown content via Teams, Slack, Outlook, or other rich-text apps that don't render pasted raw Markdown. Converts Markdown to rich text on the macOS clipboard so it pastes as formatted text.
---

# Markdown to Rich Text Clipboard

Copies Markdown as Teams-compatible rich text to the macOS clipboard using `md2clip`.

## Prerequisites

- macOS
- `pandoc` installed (`brew install pandoc`)
- `md2clip` on PATH (`ln -sf ~/.claude/tools/md2clip ~/.local/bin/md2clip`)

## Workflow

1. **Get the Markdown content.** Either:
   - The user points to an existing `.md` file, OR
   - Write the content to a temp file: `/tmp/claude-{session_name}/clipboard-export.md`

2. **Run `md2clip`:**

       md2clip /tmp/claude-{session_name}/clipboard-export.md

   The script handles all sanitisation, HTML conversion, post-processing, and clipboard copy.

3. **Tell the user** the rich text is on their clipboard and ready to paste.

## What `md2clip` handles internally

- Sanitises Unicode punctuation (em dashes, smart quotes)
- Converts Markdown to HTML via pandoc (`--ascii`)
- Joins pandoc's line-wrapped paragraphs onto single lines
- Strips `<p>` tags (Teams ignores paragraph margins)
- Inserts blank lines between paragraphs for single-line-gap spacing
- Simplifies pandoc code block wrappers to plain `<code>`
- Removes excessive gaps around lists
- Copies HTML to clipboard via JXA/NSPasteboard

## Teams HTML Compatibility Reference

Teams' HTML sanitiser is aggressive. It keeps:

| Element | Renders as |
|---|---|
| `<code>` | Monospace font + grey background |
| `<ul>/<li>` | Bullet list |
| `<ol>/<li>` | Numbered list |
| `<strong>` | Bold |
| `<em>` | Italic |
| `<br>` | Line break (full line height, minimum enforced) |
| `<a href>` | Clickable link |
| `<table>` | Rendered table with borders |

Teams strips or ignores: `<p>` margins, `style` attributes, `<pre>`, `<div>`, CSS `margin`/`padding`.

## Paragraph Spacing

Blank lines in the HTML source produce single-line gaps in Teams. This is the correct approach.
Avoid `<span style="font-size:1px"><br></span>` — Teams enforces minimum line height on any
`<br>`, producing double-height gaps regardless of the font-size hack.
