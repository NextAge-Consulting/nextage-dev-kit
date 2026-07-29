---
name: mfing-bible-of-tanstack
description: The definitive TanStack guide covering Start, Router, and Query. Server functions with { data: params } pattern, route integration with loaderDeps, TanStack Query cache management with unified queryOptions, ServerOnly authentication, public API routes, webhooks. Use when creating routes, server functions, query hooks, mutations, implementing authentication, building webhooks, debugging data fetching, fixing loading spinners, or any TanStack Start/Router/Query work.
---

# The MF'ing Bible of TanStack

The definitive guide to TanStack Start, Router, and Query patterns. This skill provides indexed access to comprehensive documentation without consuming context when not needed.

## Version Reference

| Package | Version | Notes |
|---------|---------|-------|
| `@tanstack/react-start` | 1.145.x | fetch handler output (1.132+) |
| `@tanstack/react-router` | 1.144.x | |
| `@tanstack/react-query` | 5.80.x | |
| `@tanstack/router-plugin` | 1.145.x | |
| `hono` | 4.x | Recommended server runtime |
| `@hono/node-server` | 1.x | Node.js adapter |

---

## Quick Reference (Essential Patterns)

### The Three Critical Patterns

1. **Server Function Parameters**: `{ data: params }` destructuring
2. **Route Parameter Flow**: `loaderDeps` → `loader` → server function
3. **Unified QueryOptions**: Single source of truth for cache keys

### Server Function Template

```typescript
import { createServerFn } from '@tanstack/react-start'
import { getServerAuth } from '@/lib/auth/serverAuth'
import { db, yourTable } from '@your-org/shared/db'

export const functionName = createServerFn({
  method: 'GET', // or 'POST'
})
  .inputValidator((params: YourParamsType) => params)
  .handler(async ({ data: params }) => {
    // 1. Auth context (if needed)
    const authContext = await getServerAuth(['admin', 'manager'])

    // 2. CRITICAL: Safe parameter handling
    const safeParams = params || {}

    // 3. Database operations
    const results = await db.select().from(yourTable)
      .where(/* conditions */)
      .limit(safeParams.limit || 50)
      .offset(safeParams.offset || 0)

    return results
  })
```

### Route Template

```typescript
import { createFileRoute } from '@tanstack/react-router'
import { serverFunction } from '@/lib/serverFunctions/yourFn'

export const Route = createFileRoute('/your/route/')(({
  validateSearch: (search) => ({
    param1: search?.param1 || undefined,
    param2: search?.param2 || undefined,
  }),

  // loaderDeps: ONLY for search parameters (query strings)
  loaderDeps: ({ search }) => ({
    param1: search?.param1 || undefined,
    param2: search?.param2 || undefined,
  }),

  loader: async ({ deps }) => {
    const data = await serverFunction({ data: deps })
    return { data }
  },

  component: YourComponent,
}))
```

### Parameter Flow

```
URL: /route?search=test&status=active
    ↓
1. validateSearch → { search: 'test', status: 'active' }
    ↓
2. loaderDeps → { search: 'test', status: 'active' }
    ↓
3. loader → serverFunction({ data: deps })
    ↓
4. handler → ({ data: params }) where params = { search: 'test', status: 'active' }
```

### Path Parameters vs Search Parameters

```typescript
// PATH PARAMETERS: /users/$userId → automatically available
loader: async ({ params }) => {
  // params.userId is automatic - NO loaderDeps needed
  return getUserById({ data: { userId: params.userId } })
}

// SEARCH PARAMETERS: /users?search=test → requires loaderDeps
loaderDeps: ({ search }) => ({ search: search?.search }),
loader: async ({ deps }) => {
  return searchUsers({ data: deps })
}
```

---

## When to Consult Reference Files

| Task | Reference File |
|------|----------------|
| Creating server functions | `references/server-functions.md` |
| Server function composition/cross-domain | `references/server-functions.md` |
| Creating routes with loaderDeps | `references/routes-and-loaders.md` |
| Route file naming conventions | `references/routes-and-loaders.md` |
| Adding authentication/RBAC | `references/authentication.md` |
| ServerOnly pattern | `references/authentication.md` |
| Building webhooks/public API routes | `references/api-routes-webhooks.md` |
| Global middleware | `references/api-routes-webhooks.md` |
| TanStack Query integration | `references/tanstack-query.md` |
| Unified queryOptions pattern | `references/tanstack-query.md` |
| Cache invalidation/mutations | `references/tanstack-query.md` |
| Optimistic updates | `references/tanstack-query.md` |
| Fixing loading spinners | `references/loading-states.md` |
| SWR behavior configuration | `references/loading-states.md` |
| Debugging hydration issues | `references/debugging.md` |
| CJS/ESM problems | `references/debugging.md` |
| Testing server functions | `references/debugging.md` |
| Production deployment | `references/production-deployment.md` |
| Docker deployment | `references/production-deployment.md` |
| Static file serving | `references/production-deployment.md` |
| Hono server setup | `references/production-deployment.md` |
| Code review for mistakes | `references/anti-patterns.md` |
| Common errors to avoid | `references/anti-patterns.md` |
| Dependabot / security alerts, `overrides` safety | `references/dependency-management.md` |
| Transitive dep breaks SSR / `Cannot GET /` after override | `references/dependency-management.md` |

---

## Critical Rules Summary

### Server Functions

- **Always** use `{ data: params }` destructuring in handler
- **Always** handle undefined: `const safeParams = params || {}`
- **Use** shared database connection from `@/lib/db`
- **Use** `Fn` suffix for server function files: `prospectsFn.ts`
- See `references/server-functions.md` for composition patterns

### Routes

- `loaderDeps` is **ONLY** for search parameters (query strings)
- Path parameters (`$prospectId`) are **automatically** available in `params`
- **Never** use `loaderDeps` for path parameters
- Use **descriptive names** not `index.tsx`: `prospects-pipeline.tsx`
- See `references/routes-and-loaders.md` for complete patterns

### Authentication

- **Use** `createServerOnlyFn` - guarantees server-only execution
- **Never** put auth logic directly in handlers
- **Never** use middleware pattern for auth (tree-shaking issues)
- See `references/authentication.md` for ServerOnly pattern

### TanStack Query

- Use **singular** cache keys matching DB names: `['prospect', filters]`
- **Unified queryOptions** shared between routes and hooks
- **Never** duplicate query definitions
- See `references/tanstack-query.md` for cache management

### Public API Routes

- Use `createFileRoute` with `server.handlers` for webhooks
- Read raw body with `request.text()` for signature verification
- See `references/api-routes-webhooks.md` for webhook patterns

---

## File Structure Convention

```
apps/web/
├── src/
│   ├── lib/
│   │   ├── db.ts                    # Shared database connection
│   │   └── serverFunctions/
│   │       ├── prospectsFn.ts       # Server functions with Fn suffix
│   │       ├── authFn.ts
│   │       └── campaignFn.ts
│   ├── routes/
│   │   └── admin/prospects/
│   │       ├── prospects-pipeline.tsx    # Descriptive name (not index.tsx)
│   │       └── $prospectId/
│   │           └── prospect-details.tsx
│   └── hooks/
│       └── useProspects.ts
├── server.mjs                       # Hono production server wrapper
└── dist/                            # Build output (after vite build)
    ├── server/server.js             # TanStack fetch handler (NOT standalone!)
    └── client/                      # Static assets (JS, CSS, images)
```

---

## Production Server (Quick Reference)

**CRITICAL**: TanStack Start outputs a fetch handler, NOT a runnable server. Wrap with Hono:

```javascript
// server.mjs - Hono wrapper for TanStack Start
import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { serveStatic } from '@hono/node-server/serve-static'
import handler from './dist/server/server.js'

const app = new Hono()

// Static files FIRST (TanStack doesn't serve these!)
app.use('/assets/*', serveStatic({ root: './dist/client' }))
app.use('/images/*', serveStatic({ root: './dist/client' }))

// TanStack Start handles everything else
app.all('*', (c) => handler.fetch(c.req.raw))

serve({ fetch: app.fetch, port: 3001 })
```

See `references/production-deployment.md` for complete patterns.

---

## Common Patterns

### Cross-Domain Server Function Calls

```typescript
// ✅ CORRECT: Use server functions for cross-domain queries
const contact = await getContactFullProfile({ data: { contactid: input.contactid } })
const product = await getProductDetails({ data: { productid: input.productid } })

// ❌ WRONG: Direct database queries across domains
const contact = await db.query.contact.findFirst(...)  // Don't do this from invoiceFn
```

### Same-Domain Direct Queries

```typescript
// ✅ CORRECT: Direct queries within same domain
export const updateSubscription = createServerFn({ method: 'PUT' })
  .handler(async ({ data: input }) => {
    // Same-domain lookup - OK to use direct query
    const existing = await db.query.subscription.findFirst({
      where: eq(subscription.subscriptionid, input.subscriptionid)
    })
    // ...
  })
```

### Auth Patterns by Role

```typescript
// No authentication required
const authContext = undefined  // Skip getServerAuth

// Any authenticated user
const authContext = await getServerAuthAnyRole()

// Specific roles
const authContext = await getServerAuth(['admin'])
const authContext = await getServerAuth(['admin', 'manager'])
```

---

## Reference Files

### Detailed Documentation

- **`references/server-functions.md`** - Server function patterns, composition, cross-domain queries, database connection, input validation
- **`references/routes-and-loaders.md`** - Route integration, loaderDeps, file naming, path vs search parameters
- **`references/authentication.md`** - ServerOnly auth, RBAC middleware, createServerOnlyFn, auth patterns by role
- **`references/api-routes-webhooks.md`** - Public API routes, webhooks, raw body handling, global middleware
- **`references/tanstack-query.md`** - QueryOptions, cache keys, mutations, optimistic updates, prefetching
- **`references/loading-states.md`** - SWR behavior, pending components, spinner fixes, shouldReload
- **`references/debugging.md`** - Hydration issues, CJS/ESM problems, testing setup, Vite config
- **`references/anti-patterns.md`** - Common mistakes, what NOT to do, parameter safety
- **`references/dependency-management.md`** - Handling Dependabot/security alerts without breaking SSR; why `overrides`/`resolutions` on transitives under `@tanstack/*` or `vite` silently break SSR; how to test an override; bump-Start-instead guidance

### Finding Specific Patterns

Use grep to search reference files:

```bash
grep -i "optimistic" references/tanstack-query.md
grep -i "webhook" references/api-routes-webhooks.md
grep -i "hydration" references/debugging.md
grep -i "loaderDeps" references/routes-and-loaders.md
```

---

## Key Insight: Architecture

Our application is a **modern full-stack React solution** using:

- **TanStack Start**: Unified server/client routing with file-based routing
- **TanStack Query**: All client-side data fetching with SWR caching
- **Server Functions**: Type-safe RPC endpoints with middleware

This means:
- Single application (no separate backend)
- Automatic refetching on focus/reconnect
- Request deduplication
- SSR compatibility
- Type safety end-to-end

---

*Never learn these patterns again. This is the way.*
