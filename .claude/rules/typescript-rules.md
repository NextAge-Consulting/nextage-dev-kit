---
paths: "**/*.{ts,tsx,mts,cts}"
---

# TypeScript Rules

<!--
Loaded only when editing TypeScript files. Universal rules in constitution.md.
Frontend-only rules (toasts, Tailwind, shadcn, responsive) live here because
the current stack uses TanStack + Astro — frontend = TS.
-->

## I. TypeScript Quality (Zero Tolerance)

**No TypeScript errors in committed code.** Enforced by git pre-commit hook.

LSP diagnostics are authoritative (constitution §IX). TS errors are NOT suggestions — they are compilation failures.

| Forbidden Pattern | Why | Fix |
|-------------------|-----|-----|
| `_unusedVar` | Hides dead code | DELETE the code |
| `: any` | Disables type checking | Use proper types |
| `// @ts-ignore` | Hides errors | Fix the issue |
| `as any` | Bypasses checking | Type narrowing |

| Error | Fix |
|-------|-----|
| TS6133 (unused) | DELETE |
| TS6192 (all imports unused) | DELETE |
| TS7006 (implicit any) | Add type |
| TS2339 (property missing) | Fix type def |
| TS2322 (type mismatch) | Fix at source |

## II. No Console.log

**console.log is FORBIDDEN.** Enforced by PreToolUse hook — which blocks
`console.log|error|warn|info|debug`, not just `log`.

Use Pino structured logging with namespaced loggers.

```typescript
import { logger } from '~/lib/logger';
logger.info('message');
logger.error({ err }, 'error message');
logger.debug({ data }, 'debug context');
```

**Log monitoring**: `tail -f logs/server.log`. Server lifecycle (start / never-kill / leave-running) is governed by `.claude/rules/dev-server.md`.

### The logger must be isomorphic — this is where the rule gets worked around

The hook blocks `console.*` **everywhere**, including React components and
browser-side hooks. If the project's logger only works server-side, the first
client-side error handler hits a wall, and every tempting way out is wrong:
bypass the hook, leave the `catch` empty, or conclude "Pino is server-only" and
give up. It is not — Pino has a browser build.

**The logger must detect its environment and degrade**, so one import works in
both places and no call site needs an exception:

```typescript
import pino from 'pino';

const isServer = typeof (globalThis as Record<string, unknown>).window === 'undefined';

function buildTransport() {
  if (!isServer) return undefined;   // browser: no transport, falls back to console
  // …server transports (pino-pretty in dev, file/stdout in prod)…
}

export const logger = pino({ level: process.env.LOG_LEVEL ?? 'info', transport: buildTransport() });
```

Two consequences, both of which have been got wrong in practice:

- **A bare `pino({ level })` inside an app is not enough.** With no `isServer`
  branch, importing it from a component tries to build a server transport in the
  browser. The environment check belongs in the logger, once.
- **Client-side logging is not optional.** A browser `catch` that neither
  surfaces to the user nor logs is a swallowed error (constitution §X). If the
  logger cannot be reached from client code, that is a defect in the logger — not
  a licence to leave the handler empty.

Where the logger lives is a project choice (a shared workspace is the usual
answer, since both tiers import it). That it works in both is not.

## III. Naming

| Convention | Rule |
|------------|------|
| TS variables | `camelCase` |
| Underscores | **FORBIDDEN** for word separation |
| Types / classes | `PascalCase` |

## IV. Timezone-Aware Code — TS Patterns

See constitution §VI for the principle. TS-specific forbidden patterns:

| Forbidden | Fix |
|-----------|-----|
| `new Date()` without tz handling in user-facing logic | Use tz-aware lib (date-fns-tz, Luxon, Temporal when stable) |
| `.toISOString()` / `.toLocaleDateString()` for display without explicit tz | Format through tz-aware formatter with user's tz |
| Comparing dates via `getTime()` across tz boundaries | Normalize to same tz first |

**Carve-out — absolute-instant audit fields (mirrors constitution §VI).** `new Date()` is ALLOWED for fields that capture the absolute instant a database row was created/updated and are never displayed or filtered by local-tz boundaries. Examples: `authuser.createdat`, `authuser.updatedat`, `authaccount.createdat` / `updatedat`, session-table bookkeeping columns. These columns store "what time was it when this row was written" with no semantics beyond ordering — converting through `date-fns-tz` would imply user-facing display semantics that don't exist. If a future change starts displaying such a column to a user OR filtering by local-tz date ranges, that change MUST migrate the column off `new Date()` and onto a tz-aware path.

## V. Server-Side Static Assets

**Never use `import.meta.url` for runtime file reads.** Bundlers (Vite, Rollup, esbuild) rewrite the path and do not copy referenced files into the build output. This causes silent production failures.

| Pattern | Result |
|---------|--------|
| `readFileSync` + `import.meta.url` | **BROKEN** — file not found in production |
| `readFileSync` + `process.cwd()` | **CORRECT** — predictable path in all environments |

**Rules:**
- Static assets loaded at runtime (templates, images, PDFs) go in `server-assets/` at the app root
- Resolve paths via `process.cwd()` (e.g., `resolve(process.cwd(), 'server-assets/email/template.html')`)
- The Dockerfile must `COPY` `server-assets/` into the production image
- Never place runtime-loaded files inside `src/` — bundlers will not include them

## VI. Boolean Assignment

When assigning to boolean variables using chained `&&` operators, use strict boolean conversion:

```typescript
// ❌ WRONG - assigns truthy/falsy values
const isValid = user && user.email && user.verified;

// ✅ CORRECT - always assigns true or false
const isValid = !!(user && user.email && user.verified);
```

## VII. No Toast Messages

Toasts are deprecated. Use contextual feedback instead.

| Instead of | Use |
|------------|-----|
| `toast.success()` | Inline state change, optimistic UI |
| `toast.error()` | Inline error message, form-level error, or modal |
| `toast.warning()` | Inline warning indicator |
| `toast.loading()` | Loading spinner in component |

**Exception**: Clipboard copy confirmation only.

**Cleanup**: When editing files with toasts, migrate them.

## VIII. Web Development Standards

### Frontend Policy
- All icon-only buttons should include tooltips on hover

### Responsive Design
Consider responsive impact across mobile, tablet, and desktop breakpoints when making UI changes.

Evaluate:
- Mobile horizontal space constraints
- Text overflow/wrapping potential
- Touch target accessibility (minimum 44px)
- Grid/flex layout behavior changes
- Breakpoint classes: `sm:`, `md:`, `lg:`, `xl:`

### Web Styling & UI
- Use Tailwind CSS for styling
- Build from `shadcn/ui` primitives
- Semantic naming (ButtonActive not ButtonRed)
- Prefer semantic classes (`text-foreground`) over manual dark mode
- Use `cn()` utility for conditional CSS classes
- Follow shadcn skill rules (`.claude/skills/shadcn/`) for component patterns

## IX. Mobile Development Standards

### Mobile Design Principles
- Touch targets: minimum 44px for accessibility
- Optimize for mobile performance and battery life
- Ensure cross-platform consistency (iOS/Android)

### Mobile Component Architecture
- Use React.memo and memoized callbacks for complex components
- Include proper ARIA labels and keyboard navigation
- Comprehensive error handling for external APIs

## X. Code Standards

- TypeScript required. Functional components with hooks.

## XI. LSP & CLI Setup

**LSP for TypeScript requires Claude Code's official plugin + the language server binary.** See constitution §IX. One-time machine setup:

```bash
# 1. Install the Claude Code plugin
/plugin install typescript-lsp@claude-plugins-official

# 2. Install the language server binary
npm install -g typescript typescript-language-server
```

**Verify:** `which typescript-language-server` must return a path. `/plugin list` must show `typescript-lsp`. If either is missing, LSP for TS is dead — fall back to `tsc`.

**CLI (always works):**
- `npm run check-types` — typecheck via local `tsc`
- `tsc --noEmit` — same, directly

## XII. Development Commands

- `npm run dev` — Start development server
- `npm run check-types` — TypeScript validation

## XIII. Code Health

- TS6133 / TS6192 detect unused declarations
- Check for indirect usage before deleting flagged code
