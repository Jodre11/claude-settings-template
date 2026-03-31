---
name: md-to-clipboard
description: Use when the user wants to share Markdown content via Teams, Slack, Outlook, or other rich-text apps that don't render pasted raw Markdown. Converts Markdown to rich text on the macOS clipboard so it pastes as formatted text.
---

# Markdown to Rich Text Clipboard

Converts Markdown to HTML on the macOS clipboard using `pandoc` + `html2clip`. The user can then paste directly into Teams, Slack, Outlook, etc. and it renders as formatted text (bold, code, bullets, headings).

## Prerequisites

- macOS (relies on `NSPasteboard` via `html2clip`)
- `pandoc` installed (`brew install pandoc`)
- `html2clip` installed at `~/.local/bin/html2clip` (source: `~/.claude/tools/html2clip.swift`)
  If missing, compile from source: `swiftc ~/.claude/tools/html2clip.swift -o ~/.local/bin/html2clip`

Check both are available before proceeding. If `pandoc` is missing, tell the user to run
`brew install pandoc`. If `html2clip` is missing, compile it from the source above.

## Pipeline

    pandoc (markdown -> HTML) -> post-process HTML -> html2clip (HTML -> clipboard)

Do NOT use `textutil` or `pbcopy`. Do NOT pipe pandoc output directly to `html2clip` — the HTML must be post-processed first.

## Workflow

1. **Get the Markdown content.** Either:
   - The user points to an existing `.md` file, OR
   - You write the content to a temp file: `/tmp/claude-{session_id}/clipboard-export.md`

2. **Sanitise the Markdown source** before conversion:
   - Replace em dashes (`—`) with plain hyphens (`-`) — they corrupt through the pipeline
   - Replace any non-ASCII punctuation that could cause encoding issues

3. **Convert Markdown to HTML:**

        pandoc <file>.md -f markdown -t html --ascii -o <file>.html

   The `--ascii` flag forces ASCII entity encoding.

4. **Post-process the HTML.** This is critical — pandoc's raw output does not render well in Teams. Apply these transformations to the HTML file:

   a. Replace `&#xA0;` with regular spaces (pandoc inserts non-breaking spaces after abbreviations like `e.g.`, `i.e.`)
   b. Replace `&#x2019;` with `'` (smart curly quotes)
   c. Strip all `<p>` and `</p>` tags — Teams ignores paragraph margins entirely
   d. Insert `<span style="font-size:1px"><br></span>` between paragraphs for spacing
   e. Replace pandoc's code block wrappers (`<div class="sourceCode">...<pre>...<code>...</code></pre></div>`) with plain `<code>...</code>`
   f. Keep `<code>` for inline code — Teams renders it with monospace + grey background
   g. Keep `<ul>/<li>` for lists, `<strong>` for bold, `<em>` for italic
   h. Ensure `<ul>` is directly adjacent to its lead-in text (no `<br>` before it)
   i. Ensure text after `</ul>` follows directly (no `<br>` after it)

5. **Copy to clipboard:**

        cat <file>.html | html2clip

6. **Tell the user** the rich text is on their clipboard and ready to paste.

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

Teams strips or ignores:

| Element/Attribute | Effect |
|---|---|
| `<p>` margins | Zero margin — paragraphs collapse together |
| `style` on `<p>` | Stripped entirely |
| `font-size` on `<span>` | Minimum line height enforced (~full line) |
| `<pre>` | No special rendering |
| `<div>` | No special rendering |
| CSS `margin`, `padding` | Stripped |

## Paragraph Spacing

There is no half-line-break in Teams. The options are:
- No `<br>` = wall of text (no gap)
- `<span style="font-size:1px"><br></span>` = single line gap (Teams enforces minimum height)
- `<br><br>` = double line gap (too much)

Use `<span style="font-size:1px"><br></span>` between paragraphs as the standard spacer.

## Common Mistakes

- **Using `<p>` tags** — Teams strips margins, producing wall of text
- **Using `textutil` RTF pipeline** — merges paragraphs, strips CSS, loses code formatting
- **Using `pbcopy`** — puts text on clipboard, not HTML
- **Using pandoc output directly** — complex `<div class="sourceCode">` wrappers, `<p>` tags
- **Putting `<br>` before `<ul>`** — creates excessive gap between list lead-in and bullets
- **Skipping `--ascii`** — causes em dashes and Unicode to corrupt
- **Skipping `&#xA0;` fix** — produces visible artefacts after abbreviations
