# MFing Bible of TanStack - Claude Code Skill

A comprehensive TanStack guide implemented as a Claude Code skill using progressive disclosure architecture.

## Purpose

This skill provides TanStack documentation (Start, Router, Query) to Claude Code sessions without consuming context when not needed. It uses Anthropic's three-level progressive disclosure:

1. **Discovery (~100 tokens)**: Name + description always loaded
2. **Activation (~2,500 tokens)**: SKILL.md loaded when working on TanStack
3. **On-Demand (variable)**: Reference files loaded as needed

## Directory Structure

```
~/.claude/skills/mfing-bible-of-tanstack/
├── SKILL.md                       # Core patterns + navigation (activated)
├── references/
│   ├── server-functions.md        # Server function patterns
│   ├── routes-and-loaders.md      # Route integration, loaderDeps
│   ├── authentication.md          # ServerOnly auth pattern
│   ├── api-routes-webhooks.md     # Public API routes, webhooks
│   ├── tanstack-query.md          # QueryOptions, cache, mutations
│   ├── loading-states.md          # SWR behavior, spinners
│   ├── debugging.md               # Hydration, CJS/ESM, testing
│   └── anti-patterns.md           # Common mistakes
└── README.md                      # This file
```

## How It Works

### Discovery (Always Active)

The `description` field in SKILL.md frontmatter contains trigger phrases:

```yaml
description: The definitive TanStack guide covering Start, Router, and Query.
Server functions with { data: params } pattern, route integration with loaderDeps,
TanStack Query cache management...
```

Claude sees these phrases at session start and knows to activate this skill when working on TanStack features.

### Activation

When triggered, Claude reads SKILL.md which contains:
- Quick reference patterns (copy-paste ready)
- Navigation table pointing to reference files
- Critical rules summary

This handles 60-80% of TanStack questions without loading reference files.

### Reference Loading

For deep dives, Claude loads specific reference files based on the navigation table:

| Task | Reference File |
|------|---------------|
| Creating server functions | `references/server-functions.md` |
| Creating routes with loaderDeps | `references/routes-and-loaders.md` |
| Adding authentication/RBAC | `references/authentication.md` |
| Building webhooks/API routes | `references/api-routes-webhooks.md` |
| TanStack Query integration | `references/tanstack-query.md` |
| Fixing loading spinners | `references/loading-states.md` |
| Debugging hydration/CJS issues | `references/debugging.md` |
| Code review for mistakes | `references/anti-patterns.md` |

## Token Budget

| Scenario | Tokens Used |
|----------|-------------|
| Non-TanStack work | ~100 (discovery only) |
| Simple TanStack question | ~2,500 (SKILL.md) |
| Deep dive (1 reference) | ~3,500-4,000 |
| Full investigation (2-3 refs) | ~5,000-6,000 |

Compare to loading entire Bible: ~8,000 tokens every session.

## Maintenance

### Updating Patterns

1. Edit the relevant reference file
2. If it's a critical pattern, also update SKILL.md quick reference
3. Keep SKILL.md under 500 lines

### Adding New Sections

1. Create new file in `references/`
2. Add entry to navigation table in SKILL.md
3. Add to Additional Resources section in SKILL.md

### Trigger Phrase Updates

If Claude isn't discovering the skill for certain queries, add relevant phrases to the `description` field in SKILL.md frontmatter.

## Source Material

This skill was extracted from:
- `project-documentation/MFing-Bible-of-TanStack-Start.md` (canonical source)

The original Bible remains as the authoritative reference. This skill is a reorganization for progressive disclosure.

## Architecture Decisions

### Why Global User-Level?

Most projects use TanStack. Global placement (`~/.claude/skills/`) provides:
- Cross-project availability
- Minimal overhead (~100 tokens) when not triggered
- Single source of truth to maintain

### Why 8 Reference Files?

Organized by task type (what the developer is trying to do):
- Creating server functions
- Creating routes
- Implementing authentication
- Building webhooks
- Managing data fetching
- Fixing loading issues
- Debugging problems
- Reviewing for mistakes

This matches how developers approach TanStack work.

### Why Flat Hierarchy?

Per Anthropic's best practices:
- References one level deep
- No nested references
- Simple navigation from SKILL.md to any reference

## Troubleshooting

### Skill Not Triggering

Check that SKILL.md frontmatter `description` contains relevant phrases. Add more trigger phrases if needed.

### Claude Not Finding Information

1. Check navigation table in SKILL.md points to correct reference
2. Verify content exists in the reference file
3. Consider if content should be in quick reference (SKILL.md) instead

### Token Usage Higher Than Expected

1. Check SKILL.md line count (should be <500)
2. Consider if reference files can be trimmed
3. Verify Claude isn't loading multiple references unnecessarily
