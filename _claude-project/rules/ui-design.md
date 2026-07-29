---
paths: "{design.md,**/*.tsx,**/*.jsx,**/*.css,**/*.scss}"
---

# UI / Design System Rule

**Before writing or editing ANY UI / styling code OR the project's `design.md`, invoke the `design-system` skill.**

```
Skill({skill: "design-system"})
```

The skill enforces "read the project's `design.md` first, then apply universal styling discipline." It will hard-stop if `design.md` is missing at the project root.

## Why this rule is path-targeted

- **JSX/TSX files** contain component styling that consumes tokens.
- **CSS/SCSS files** contain the `@theme` token definitions and any global styles.
- **`design.md`** is the documented spec itself — edits to it should always pass through the skill so the spec-compliance + lint-step expectations are surfaced.

Anything else (server functions, tests, config, prose docs other than design.md) doesn't touch the design system and doesn't need this rule loaded.

When the file being edited IS `design.md`, the skill's **Step 4 — Validate** is the critical concern: run `npm run lint:design` (the declared design.md spec linter) before declaring the change done. The skill instructs this; the rule's job is just to ensure the skill loads.

## Authority chain

1. **Runtime source of truth**: the CSS `@theme` block (typically `src/styles.css` or `apps/shared/src/styles.css`) — what the browser actually sees.
2. **Documented spec**: the project's `design.md` (at project root) — google-labs-code spec compliant, machine-readable + human-readable.
3. **Universal discipline**: the `design-system` skill — project-agnostic rules about how to consume any design system spec.

If runtime and documented spec diverge, runtime wins; update `design.md` to match.

## The client/server wall (hard rule)

The design system's UI — tokens, atoms, `cn()`, display components — lives in a **client-clean** home: client dependencies only (react, radix, cva, tokens), **no** server/DB imports (no drizzle/pg, no server functions). Two placements are valid — per-app `src/components/ui/`, or a dedicated client-only UI workspace (`packages/ui`) consumed by every front-end app — but the wall is the same, and it is **bidirectional**:

- **The UI home holds no server code** → a UI atom can never drag server deps (pg, drizzle) into the client bundle.
- **The server-shared package holds no UI** → a headless app (REST API, worker) can consume shared business logic with no path that reaches a React import.

Never add server/DB deps to the UI home, and never add React/UI to the server-shared package. If a component needs server data, that is an app-level composite wiring a server function to a UI atom — not the UI home reaching into the server.

A project that cannot yet satisfy the wall (UI still living in its server-shared package) MUST record the exception in a project-local rule that names the migration path — never silently ignore it.

## When this rule is wrong

Almost never. The one carve-out: if the user explicitly authorizes ad-hoc styling for a single one-shot task (e.g. a debugging UI), you may proceed without the skill — but document the exception in the change and treat it as tech debt to be reconciled.
