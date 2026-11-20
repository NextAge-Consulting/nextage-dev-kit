---
paths:
  - "changelog.md"
  - "CHANGELOG.md"
---

# Changelog

**This project's changelog is public-facing: write every entry for a customer, an end user or a non-technical stakeholder.** `/deploy` writes one entry per release, from the commits since the last tag, by this rule.

## What goes in

- **Include** `feat` (✨), `fix` (🐛), `perf` (⚡) and any breaking change (💥) — what a user would notice.
- **Leave out** `refactor`, `style`, `test`, `docs` and `chore`, dependency and tooling updates included, unless the change is one a user would notice.
- **A release with nothing to include gets no entry.** It still ships; `/deploy` passes no patch.
- **Group related commits** into one bullet where that reads naturally — several fixes to the same screen are one line. Every distinct user-facing change gets its own bullet.

**Never name what only someone reading the source would understand:** API routes, function or module names, file paths, table names, schema changes, server or pipeline configuration, auth mechanisms, vulnerability details, secret names. Say what changed for the user instead; a security fix reads "Improved security".

## How an entry reads

```markdown
### November 17, 2026 · v1.4.0

- **✨ Saved Searches** - Keep a search and run it again from the sidebar.
- **🐛 Upload Retries** - A large upload that dropped now resumes instead of starting over.
```

- **Header:** `### <Month Day, Year> · v<version>` — the local date `/deploy` runs on, and the version it is releasing. Every release gets its own header, a second release on the same day included.
- **Bullets:** `- **<emoji> <Short Title Case>** - <one line on what the user sees>`.
- **Placement:** newest first — the new header goes directly below the file's opening lines (`# Changelog`, a blank line, its one-sentence description, a blank line), above the previous release.
- **No file yet:** create it with those opening lines, the description reading `All notable changes to this project will be documented in this file.`
