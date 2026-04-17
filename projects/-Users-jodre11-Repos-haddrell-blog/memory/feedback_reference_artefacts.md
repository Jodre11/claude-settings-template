---
name: Trust reference artefacts over reconstruction
description: When the user provides a reference image or file, trace/use it directly rather than reverse-engineering from an incomplete predecessor
type: feedback
originSessionId: 0db45988-4395-428f-b0ce-1d35f2372ad9
---
When the user provides a reference artefact (transparent PNG, design mockup, example output), treat it as the source of truth and derive the deliverable directly from it — don't try to reconstruct the same output by manipulating an earlier, less-complete source.

**Why:** During the Dougal logo work, the user's source SVG (`Logo-Outline.svg`) defined interior face details as negative space, which rendered dark on dark backgrounds. I spent many turns on hull-extraction and white-underlay approaches to "repair" the SVG, when the user already had a transparent PNG with explicit white fills baked in. The user's instruction was: composite the PNG on a coloured background, then trace the amalgamated image — mapping bg colour to transparent and preserving the others. That one-shot workflow produced the correct SVG in minutes, after I had burned ~30 minutes on the wrong approach.

**How to apply:** If the user shares a reference artefact, ask yourself: "Can I derive the deliverable *from this*, or am I trying to derive it *around this*?" Tracing (potrace for bitmaps, manual redraw for designs) is often faster and more faithful than reconstructing from compound-path gymnastics. Also: when the user says "stop, here's what I want you to do," follow their specific recipe rather than proposing alternatives.
