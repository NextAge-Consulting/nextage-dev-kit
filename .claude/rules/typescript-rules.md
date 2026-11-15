---
paths: "**/*.{ts,tsx,mts,cts}"
---

# TypeScript Rules

Loaded when editing TypeScript. Universal rules live in `constitution.md`; UI rules live in `ui-design.md`, `ui-patterns.md` and `a11y-baseline.md`.

## I. TypeScript Quality (Zero Tolerance)

**Commit no TypeScript errors.** The commit gate enforces it, LSP diagnostics are authoritative (constitution §IX), and a TS error is a compilation failure rather than a suggestion.

Delete dead code rather than renaming it `_unusedVar`. Give values real types rather than `: any` or `as any`, and fix the underlying issue rather than writing `// @ts-ignore`.

TS6133 and TS6192 mean an unused declaration — delete it, after checking for indirect usage. TS7006 needs a type. TS2339 needs the type definition fixed. TS2322 needs fixing at the source of the mismatch.

## II. Logging

**Use Pino.** A PreToolUse hook blocks `console.log`, `.error`, `.warn`, `.info` and `.debug` everywhere except the files `biome.base.json` exempts from `noConsole` — command-line scripts under a `scripts/` folder, tests, config files and the server entry.

**A command-line script's report to the person running it uses `console`.** It lives under a `scripts/` folder, never in application source.

```typescript
import { logger } from '~/lib/logger';
logger.info('message');
logger.error({ err }, 'error message');
logger.debug({ data }, 'debug context');
```

Watch it with `tail -f logs/server.log`. Server lifecycle is governed by `dev-server.md`.

**The logger detects its own environment, once, so one import works on both tiers.** The hook blocks `console.*` in React components and browser hooks too, so a server-only logger strands the first client-side error handler — and every way out from there is wrong. Pino has a browser build.

```typescript
import pino from 'pino';

const isServer = typeof (globalThis as Record<string, unknown>).window === 'undefined';

function buildTransport() {
  if (!isServer) return undefined;   // browser: no transport, falls back to console
  if (process.env.NODE_ENV === 'production') return undefined;   // prod: JSON to stdout
  return { target: prettyPath(), options: { colorize: true, translateTime: 'SYS:HH:MM:ss' } };
}

// getBuiltinModule rather than an import: the browser loads this file too.
function prettyPath(): string {
  const { createRequire } = process.getBuiltinModule('node:module');
  return createRequire(`${process.cwd()}/`).resolve('pino-pretty');
}

export const logger = pino({ level: process.env.LOG_LEVEL ?? 'info', transport: buildTransport() });
```

**Give pino every transport target as an absolute path, never a package name.**

A bare `pino({ level })` inside an app is not enough — imported from a component it tries to build a server transport in the browser. Put the environment check in the logger.

Client-side logging is not optional. A browser `catch` that neither surfaces to the user nor logs is a swallowed error (constitution §X). A logger that client code cannot reach is a defect in the logger.

Where the logger lives is a project choice — usually a shared workspace, since both tiers import it.

## III. Naming

`camelCase` for variables, `PascalCase` for types and classes. Underscores never separate words.

## IV. Timezone-Aware Code — TS Patterns

Constitution §VI carries the principle. In TypeScript:

Use a timezone-aware library (date-fns-tz, Luxon, Temporal once stable) rather than a bare `new Date()` in user-facing logic. Format display through a timezone-aware formatter with the user's timezone rather than `.toISOString()` or `.toLocaleDateString()`. Normalize to one timezone before comparing dates via `getTime()`.

The carve-out mirrors §VI: `new Date()` is right for columns capturing the absolute instant a row was written — `createdat`, `updatedat`, session bookkeeping — that are never displayed and never filtered by local-timezone ranges. If a change starts displaying such a column or filtering it by a local date range, that change migrates the column onto a timezone-aware path.

## V. Server-Side Static Assets

**Resolve runtime file reads through `process.cwd()`**, e.g. `resolve(process.cwd(), 'server-assets/email/template.html')`. Bundlers rewrite `import.meta.url` and do not copy the referenced files into the build, so it fails silently in production.

Runtime-loaded assets — templates, images, PDFs — go in `server-assets/` at the app root, never inside `src/`. Add a `COPY` for `server-assets/` to the Dockerfile if one is not already there, or the files are absent from the production image.

## VI. Boolean Assignment

Wrap a chained `&&` assignment in `!!()` so it stores `true` or `false` rather than the last truthy value:

```typescript
const isValid = !!(user && user.email && user.verified);
```

## VII. Code Standards

Write TypeScript, and write components as functions with hooks rather than classes.

## VIII. Setup and Commands

TypeScript LSP needs both Claude Code's official plugin and the language server binary (constitution §IX). One-time per machine:

```bash
/plugin install typescript-lsp@claude-plugins-official
npm install -g typescript typescript-language-server
```

Verify with `which typescript-language-server` returning a path and `/plugin list` showing `typescript-lsp`. With either missing, LSP for TS is dead — fall back to `tsc`.

The CLI always works: `npm run check-types` (typecheck via local `tsc`), `tsc --noEmit` directly, and `npm run dev` for the development server.

## IX. Workspace Imports

**One workspace reaches another by package name, declared as a dependency.** The consuming workspace lists the package with `"*"` (`"@acme/shared": "*"`) and imports `@acme/shared/billing/invoice` — never a relative path out of its own directory, and never a tsconfig `paths` alias that resolves outside it. `check-workspace-tiers.mjs` fails both.

**The package's `exports` map points at TypeScript source**, so nothing is built before it is imported:

```json
"exports": {
  "./billing": "./src/billing/index.ts",
  "./styles.css": "./src/styles.css",
  "./components/*": "./src/components/*.tsx",
  "./*": "./src/*.ts"
}
```

Give each barrel an explicit entry — a pattern maps `./billing` to `src/billing.ts`, never to its `index.ts`. Give each folder holding `.tsx` its own pattern, since one pattern carries one extension, and a `.ts` module inside that folder its own entry. A package imports its own modules by relative path or by its own name, never by an alias.

**`@/*` stays the in-app alias**, mapped to the workspace's own `./src/*`.

**A config module shared across workspaces resolves its paths from `import.meta.dirname`.** Vite loads a workspace package's module as native ESM, where `__dirname` is undefined, and `process.cwd()` is whichever app is building.

**shadcn's `components.json` in a shared UI package names the package**: `"components": "@acme/ui/components"`, `"utils": "@acme/ui/lib/utils"`.

## X. The client/server wall

The design system's UI — tokens, atoms, blocks, `cn()`, display components — lives in a home with client dependencies only (react, radix, cva) and no server or DB imports. One front-end app puts it in that app's `src/components/ui/`; more than one puts it in a dedicated client-only workspace (`packages/ui`) they all consume.

The wall is bidirectional. **The UI home holds no server code**, so a UI atom can never drag pg or drizzle into the client bundle. **The server-shared package holds no UI**, so a headless app — a REST API, a worker — can consume shared business logic with no path reaching a React import. Keep that true even with no headless app today.

A component needing server data is an app-level composite wiring a server function to a UI atom, not the UI home reaching into the server.

A project that cannot yet satisfy the wall — UI still living in its server-shared package — records the exception in a file under `rules/project/`, naming the migration path.

### A third tier, only when something needs it

Server-shared plus UI home covers most projects. A third appears when a project has shared code that is neither: reachable from browser code, used by more than one front-end app, and not presentational — a Stripe browser integration, a shared serverFn, a shipping-API client.

"Reachable from browser code" is the test, not "executes in the browser". A serverFn runs on the server, but the client imports its reference to call it, so it cannot live in the browser-free server-shared package. It must not go in the UI home either, which stays clean presentation. So it earns its own workspace, conventionally `packages/web`, holding integrations and shared serverFns and never touching the database.

Any front-end may import it — apps, and extension apps too.

Create it when the code that belongs in it exists, never speculatively.

### Browser extensions are all browser

A browser-extension app is client code end to end. There is no server half, so nothing in it can justify a data-tier import — a stray one ships drizzle into the extension bundle.

An extension app may consume the UI home like any other front-end. It must never import the server-shared package, and never import database code (`drizzle-orm`, `pg`, `postgres`, `@neondatabase/*`) directly.

The guard identifies an extension app by a browser-extension builder in its dependencies — `wxt`, `plasmo`, `@plasmohq/parcel-config`, or `@crxjs/vite-plugin` — so a new extension is covered the moment its `package.json` names one, with nothing to configure. It is also excluded from headless-app detection: an extension has no `react` dependency and may have no `.tsx`, which would otherwise read as a server-only service, and the two have opposite rules about reaching the database.

### The one sanctioned crossing: contract types

Row and param shapes produced by server loaders and rendered by UI components are defined once, in the UI home under `contracts/`, and `import type`d back by the server module that produces them. Types erase at compile, so nothing crosses at runtime.

This is the only way the server-shared package may reference the UI home, and it is types-only — a runtime import is a violation. Contract modules import nothing but sibling contract modules. Declaring the shape twice drifts; putting it in the server tier and importing it from UI breaches the wall.

### The guard

`scripts/check-workspace-tiers.mjs` (CI job `workspace-tiers`) enforces all of the above. It detects which tiers a repo has — server-shared, UI home, web tier, headless apps (an app workspace with no `react` dependency and no `.tsx`), and extension apps (an app workspace whose dependencies name an extension builder) — and checks only the walls that exist, so a repo with no shared workspace passes unconditionally.

It also holds the rule every wall depends on: a tier is recognised by its package name, so a workspace reaches another only by that name, declared as a dependency (§IX). A relative import out of a workspace, or a tsconfig `paths` alias resolving outside one, fails.

Read its success line: it names what it actually enforced. Fewer tiers listed than you expect means a tier was not detected, not that it was checked and found clean.

It detects the UI home as the `packages/ui` workspace. A single-app UI home living in `apps/<app>/src/components/ui/` is a directory, not a workspace, so the guard does not see it and that wall is yours to hold by hand until the project grows a second front-end.
