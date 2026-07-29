---
name: analysis
description: Produce a written analysis the human asked for — an audit, assessment, investigation, or deep-dive — and package it to share. Use when asked to analyze / audit / assess / investigate something and write it up, OR when the output is "to share", "for stakeholders", "for approval", or "for review". Covers the format decision (markdown vs standalone HTML) and, for standalone HTML, the shared self-contained generator so charset/viewport/embedded-assets are never hand-rolled or forgotten.
---

# Producing Analysis

When the human asks you to analyze, audit, assess, or investigate something and
write it up — especially to share, for stakeholders, for approval, or for review —
this is how you package it.

## Step 1: Pick the format

| Output | Use for |
|--------|---------|
| **Markdown in-repo** | working docs beside the code — `project-documentation/` (or `…/temporary/` if throwaway) |
| **Standalone HTML file** | anything shared — forwarded, emailed, opened offline or on a phone |

Sharing intent decides it; if unsure, ask. (Never build Artifacts — they aren't
shareable without an enterprise/team Anthropic account.)

## Step 2: Standalone HTML — use the shared generator, never hand-roll

**Do NOT write the HTML / `<head>` / CSS by hand.** Hand-rolled report HTML forgets
`charset` + `viewport` every time — invisible until someone opens it on a phone and
gets mojibake and unreadable zoom. The shared generator guarantees them.

Build a data JSON, then run the kit tool:
```bash
node "$CLAUDE_PROJECT_DIR"/.claude/lib/gen-report.mjs . <data>.json <out>.html
```

Data shape (analysis mode):
```json
{
  "title": "…", "subtitle": "… · for review · date",
  "note": "<b>TL;DR</b> …",
  "stats": [ { "value": "3", "label": "findings" }, { "value": "1", "label": "blocker", "color": "fail" } ],
  "imageBase": ".",
  "sections": [
    { "heading": "Finding 1", "html": "<p>prose, tables, <code>inline</code> …</p>",
      "images": [ ["path/to/fig.svg", "caption"] ] }
  ]
}
```

- `html` is arbitrary self-contained content — prose, `<table>`, **inline SVG** (charts).
- `images` are embedded as base64 by the generator and open in a lightbox. No external
  `<img src>` — everything travels in the one file.
- The generator's `<head>` always carries charset + viewport; you never touch it.

## Step 3: Hand it off

Write the file into `project-documentation/` (durable) or `…/temporary/` (throwaway),
then deliver it with SendUserFile so the human can open or forward it.

## What this skill is not

App/UI reporting features — that's product code. This is analysis *you* author when asked.
