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

## The atoms must be in the FORCED read, not just in `design.md`

`design.md` is the authority for what the design system contains, and it is not
auto-loaded — this rule is. So the same failure applies here as to patterns: a
component can exist, be specified, and still be hand-rolled, because nothing put
its NAME in front of the person writing the screen.

The project's UI inventory rule (`rules/project/ui-inventory.md`, path-targeted
to the same globs as this file) therefore carries **the list of components that
exist** — atoms, display components, app composites — one line each on what they
are for. `design.md` keeps the spec; the inventory answers "does this already
exist", which is the question actually being got wrong.

Adding a component means adding it to BOTH, in the same change as the component
(`design-system` skill, reconciliation pass).

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

**Keep the server-shared package browser-free even with no headless app today.** A future REST service or worker must be able to consume shared business logic with no path that reaches a React import. Enforcing it from the start costs nothing; retrofitting it after the fact is a refactor. A headless consumer does not create this rule — it only removes the option of ignoring it.

### The third tier — only when something needs it

Two tiers (server-shared + UI home) cover most projects. A third appears when a project has shared code that is **neither**: client-side, used by more than one front-end app, and not presentational — a Stripe browser integration, a shared serverFn, a shipping-API client.

It cannot go in the server-shared package (that stays browser-free, above), and it must not go in the UI home (which stays clean presentation so the design feed has nothing server-side to sanitize). So it earns its own workspace — conventionally `packages/web`, holding integrations and shared serverFns, and never touching the database.

**Do not create this tier speculatively.** With nothing to put in it, an empty third package is pure overhead: another manifest, another path alias, and a "where does this go?" decision on every future change. Create it when the code that belongs in it actually exists — not before. Most projects never need it.

### The one sanctioned crossing: contract types

Row and param shapes produced by server loaders and rendered by UI components are defined **once**, in the UI home under `contracts/`, and `import type`d back by the server module that produces them. Types erase at compile, so nothing crosses at runtime.

This is the only way the server-shared package may reference the UI home, and it is types-only — a runtime import is a violation. Contract modules import nothing but sibling contract modules. The alternative (declaring the shape twice, or putting it in the server tier and importing it from UI) either drifts or breaches the wall.

### The guard

`scripts/check-workspace-tiers.mjs` (CI job `workspace-tiers`) enforces all of the above. It **detects** which tiers a repo has — server-shared, UI home, web tier, and headless apps (an app workspace with no `react` dependency and no `.tsx`) — and checks only the walls that exist. A repo with no shared workspace is a guaranteed pass, so it runs unconditionally. Its success line names what it actually enforced; a pass with fewer tiers listed than you expect means a tier was not detected, not that it was checked and found clean.

## When this rule is wrong

Almost never. The one carve-out: if the user explicitly authorizes ad-hoc styling for a single one-shot task (e.g. a debugging UI), you may proceed without the skill — but document the exception in the change and treat it as tech debt to be reconciled.
