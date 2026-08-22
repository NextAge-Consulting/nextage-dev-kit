# Development Guidelines

<!--
WHAT BELONGS HERE: Language-agnostic implementation tips, how-to guidance, soft recommendations.
WHAT DOESN'T: Critical rules with enforcement (constitution.md).
WHAT DOESN'T: Language-specific guidance (typescript-rules.md / python-rules.md).
Rule of thumb: If violation is a CRITICAL ERROR, it's constitution. If it's language-specific, it's the language file. Otherwise here.
-->

**Note**: Critical rules in `constitution.md`. Language-specific patterns in `typescript-rules.md` and `python-rules.md` (auto-loaded via path targeting).

## Documentation Standards

**Location priority:**
1. Follow specific instructions in prompt or user request
2. Special files (`changelog.md`, `README.md`, `CLAUDE.md`) follow predefined locations
3. Temporary documents (disposable) go in `project-documentation/temporary`
4. Permanent documentation goes in `project-documentation`

**Plans are temporary — by definition, with no exceptions.**

A plan file is written to `project-documentation/temporary` and nowhere else. A plan
describes work that has not happened yet, so from the moment implementation starts it
drifts from what was actually built — and a stale plan skimmed as if it were reference
documentation is worse than having no documentation at all.

When the work is done, the plan is **replaced, not kept**:

1. Write the permanent doc — present-tense, describing what now exists, not what was
   intended.
2. File it in its proper home under `project-documentation`.
3. **Delete the plan file.** It is not the deliverable and is not kept "for reference";
   git holds the history.

A plan surviving past its own implementation is a defect, not an archive.

**Content rules:**
- Only include current state, not historical decisions — reference/operational docs are present-tense; **scrub removed things to zero, never leave a "was deleted/replaced" tombstone.** Zero tolerance: see `constitution.md` §XV.
- Follow existing file structure and style
- Check existing subfolders for suitable location

## Environment Configuration

- Preserve existing configuration when adding env vars
- Check for existing `.env` files before creating
- Read current values first, add only new variables

## Database Query Access (psql)

For read-only queries and exports, use psql directly:

```bash
DATABASE_URL=$(grep "^DATABASE_URL=" .env | cut -d'=' -f2- | cut -d'#' -f1 | xargs)
psql "$DATABASE_URL" -c "SELECT * FROM tablename;"
```

## Code Health

- Run language diagnostics before claiming work done (LSP is primary — see constitution §IX)
- Check for indirect usage before deleting code flagged as unused
- Language-specific unused-code error codes (TS6133, F401, etc.) live in the respective rule files
