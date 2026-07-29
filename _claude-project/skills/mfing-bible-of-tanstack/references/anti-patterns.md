# Anti-Patterns Reference

## Contents

- [Generic Names](#generic-names)
- [Parameter Safety](#parameter-safety)
- [loaderDeps Mistakes](#loaderdeps-mistakes)
- [Auth Logic Mistakes](#auth-logic-mistakes)
- [Database Connection Mistakes](#database-connection-mistakes)
- [Production Deployment Mistakes](#production-deployment-mistakes)
- [Quick Reference Table](#quick-reference-table)

---

## Generic Names

### Don't Use Generic Route Names

```typescript
// ❌ WRONG: Multiple index.tsx files are confusing
src/routes/admin/prospects/index.tsx  // Which view is this?
src/routes/admin/campaigns/index.tsx  // Hard to distinguish in tabs

// ✅ CORRECT: Descriptive names
src/routes/admin/prospects/prospects-pipeline.tsx
src/routes/admin/campaigns/campaigns-dashboard.tsx
```

### Don't Use Inconsistent Naming

```typescript
// ❌ WRONG: Inconsistent naming
src/lib/serverFunctions/prospects.ts     // Missing Fn suffix
src/lib/serverFunctions/campaignsFn.ts   // Has Fn suffix

// ✅ CORRECT: Consistent naming
src/lib/serverFunctions/prospectsFn.ts
src/lib/serverFunctions/campaignsFn.ts
```

---

## Parameter Safety

### Don't Skip Parameter Safety

```typescript
// ❌ WRONG: Can crash if params is undefined
.handler(async ({ data: params }) => {
  if (params.search) { /* Will throw if params is undefined */ }
})

// ✅ CORRECT: Always handle undefined
.handler(async ({ data: params }) => {
  const safeParams = params || {}
  if (safeParams.search) { /* Safe */ }
})
```

### Don't Assume Optional Properties Exist

```typescript
// ❌ WRONG: Assumes all properties exist
const results = await db.select()
  .where(eq(table.field, params.filter))  // params.filter might be undefined

// ✅ CORRECT: Check before using
const safeParams = params || {}
let query = db.select().from(table)

if (safeParams.filter) {
  query = query.where(eq(table.field, safeParams.filter))
}
```

---

## loaderDeps Mistakes

### Don't Skip loaderDeps for Search Parameters

```typescript
// ❌ WRONG: Loader won't have access to search parameters
export const Route = createFileRoute('/route/')({
  loader: async ({ deps }) => {
    // deps will be undefined - no search parameters available
    return serverFunction({ data: deps })
  }
})

// ✅ CORRECT: Use loaderDeps to expose search parameters
export const Route = createFileRoute('/route/')({
  loaderDeps: ({ search }) => ({ param: search?.param }),
  loader: async ({ deps }) => {
    return serverFunction({ data: deps }) // deps now has parameters
  }
})
```

### Don't Use loaderDeps for Path Parameters

```typescript
// ❌ WRONG: loaderDeps is not needed for path parameters
export const Route = createFileRoute('/users/$userId/')({
  loaderDeps: ({ params }) => ({ userId: params.userId }), // WRONG!
  loader: async ({ deps }) => {
    return getUserById({ data: { userId: deps.userId } })
  }
})

// ✅ CORRECT: Path parameters are automatically available
export const Route = createFileRoute('/users/$userId/')({
  // No loaderDeps needed for path parameters
  loader: async ({ params }) => {
    return getUserById({ data: { userId: params.userId } }) // Direct access
  }
})
```

---

## Auth Logic Mistakes

### Don't Put Auth Logic in Handlers

```typescript
// ❌ WRONG: Auth logic in every handler
.handler(async ({ data: params }) => {
  const authResult = await auth()  // New API: auth() not getAuth(getRequest())
  if (!authResult.userId) throw new Error('Not authenticated')
  // Business logic...
})

// ✅ CORRECT: Use getServerAuth wrapper
.handler(async ({ data: params }) => {
  const authContext = await getServerAuth(['admin'])  // Handles auth + role check
  // Auth guaranteed, focus on business logic
})
```

### Don't Use Middleware for Auth

```typescript
// ❌ WRONG: Middleware pattern (tree-shaking issues)
.middleware([authMiddleware, requireRoles(['admin'])])
.handler(async ({ context }) => {
  const { authContext } = context as { authContext: AuthContext }
  // ...
})

// ✅ CORRECT: Use serverOnly auth
.handler(async ({ data: params }) => {
  const authContext = await getServerAuth(['admin'])
  // ...
})
```

### Don't Use onSuccess/onError Callbacks for Login

```typescript
// ❌ WRONG: Callbacks don't work reliably in production
const result = await signIn.email(
  { email, password },
  {
    onSuccess: () => { navigate({ to: "/dashboard" }) },
    onError: (ctx) => { setError(ctx.error.message) },
  },
)

// ❌ WRONG: Importing server functions into login components
import { warmCache } from "@/lib/serverFunctions/cacheFn"
// Server function imports can break entire module in production

// ❌ WRONG: Using useRouter instead of useNavigate
const router = useRouter()
await router.navigate({ to: "/dashboard" })

// ✅ CORRECT: Result-based with useNavigate
const navigate = useNavigate()
const result = await signIn.email({ email, password })
if (result.error) { setError(result.error.message) }
else { await navigate({ to: "/dashboard" }) }
```

### Don't Use Native Node.js HTTP Server for TanStack Start

```typescript
// ❌ WRONG: Native http.createServer loses Set-Cookie headers
// Headers.forEach + res.setHeader collapses multiple Set-Cookie into one
response.headers.forEach((value, key) => {
  res.setHeader(key, value);  // DESTROYS multiple Set-Cookie headers
});

// ✅ CORRECT: Use Hono
// Hono handles Set-Cookie headers correctly via Fetch API
app.all("*", async (c) => {
  return await handler.fetch(c.req.raw);
});
```

**Why:** The native Node.js `http.createServer` approach manually converts Fetch API Response headers to Node.js headers. `Headers.forEach()` iterates unique header names, and `res.setHeader()` overwrites previous values for the same key. Multiple `Set-Cookie` headers (session_token + session_data) get collapsed into one malformed header that browsers reject. Hono returns the Fetch Response directly, preserving all headers.

See `references/authentication.md` → "Client-Side Login (Better Auth)" for full login pattern.

### Don't Let Authed Server Fns Poison the Query Cache

```typescript
// ❌ WRONG: an authed server fn that throws redirect, called inside a queryFn
export const getData = createServerFn().handler(async () => {
  const user = await requireUser()  // throws redirect({ to: "/login" }) on a dead session
  return db.query
})
useQuery({ queryKey: ["data"], queryFn: getData })
// The redirect does NOT navigate — TanStack Query catches it and stores it in the
// cache AS DATA, poisoning the query.

// ✅ CORRECT: re-issue the redirect client-side
// 1. the server-fn auth resolver throws a router redirect({ to: "/login" }), not a plain Error
// 2. wire a QueryCache / MutationCache onError that detects a serialized redirect and re-issues it
```

**Why:** A route guard only re-checks on navigation, so an already-mounted screen keeps
showing stale authed UI while every query quietly returns the redirect-as-data. Honor the
serialized redirect in the QueryClient's error handling so a dead session always bounces
to `/login`, even with no user interaction.

### Don't Wrap betterAuth in a Shared Factory

```typescript
// ❌ WRONG: a shared factory that returns/exports the betterAuth instance type
export function makeAuth(db) { return betterAuth({ /* ... */ }) }  // OOMs tsc
export type Auth = ReturnType<typeof makeAuth>

// ✅ CORRECT: keep betterAuth({...}) inline in each app
// apps/<app>/src/lib/auth/auth.ts — per-app config; share only reusable hook/helper bodies
export const auth = betterAuth({ /* ... */ })
```

**Why:** better-auth's instance type is enormous. Exporting it from a factory forces tsc to
infer and propagate that type across every consumer, exhausting memory. Keep `betterAuth({...})`
inline per app and share the reusable bodies, not the instance type.

---

## Database Connection Mistakes

### Don't Create New Database Connections

```typescript
// ❌ WRONG: New connection per request
.handler(async () => {
  const sql = neon(process.env.DATABASE_URL)
  const db = drizzle(sql)
  // ...
})

// ✅ CORRECT: Use shared connection
import { db } from '@/lib/db'
.handler(async () => {
  const results = await db.select()
  // ...
})
```

### Don't Import Database Directly in Routes

```typescript
// ❌ WRONG: Database in route file
// src/routes/admin/prospects.tsx
import { db } from '@/lib/db'
// This can cause tree-shaking issues

// ✅ CORRECT: Database only in server functions
// src/lib/serverFunctions/prospectsFn.ts
import { db } from '@/lib/db'
```

---

## Production Deployment Mistakes

### Don't Assume dist/server/server.js Is a Runnable Server

```javascript
// ❌ WRONG: Trying to run TanStack output directly
node dist/server/server.js  // This doesn't work!

// ✅ CORRECT: TanStack outputs a fetch handler, wrap with Hono
// server.mjs
import handler from './dist/server/server.js'
app.all('*', (c) => handler.fetch(c.req.raw))
```

**Why**: TanStack Start 1.132+ outputs a Web-standard fetch handler, NOT a standalone HTTP server. You must wrap it with Hono, Express, or similar.

### Don't Forget Static File Serving

```javascript
// ❌ WRONG: Only TanStack handler (CSS/JS return 404)
app.all('*', (c) => handler.fetch(c.req.raw))

// ✅ CORRECT: Static files BEFORE catch-all
app.use('/assets/*', serveStatic({ root: './dist/client' }))
app.use('/images/*', serveStatic({ root: './dist/client' }))
app.all('*', (c) => handler.fetch(c.req.raw))  // Last!
```

**Why**: TanStack Start handler processes SSR and server functions. It does NOT serve static files from `dist/client/`.

### Don't Pass Arguments to tanstackStart()

```typescript
// ❌ WRONG: These options were removed in 1.132+
tanstackStart({
  target: 'node-server',
  customViteReactPlugin: true,
})

// ✅ CORRECT: No arguments needed
tanstackStart()
```

### Don't Forget seroval in ssr.noExternal

```typescript
// ❌ WRONG: Missing seroval (will crash in production)
ssr: {
  noExternal: [/use-sync-external-store/, /cookie/],
}

// ✅ CORRECT: Include seroval for TanStack Start runtime
ssr: {
  noExternal: [/use-sync-external-store/, /cookie/, /seroval/],
}
```

**Why**: seroval is used by TanStack Start for data serialization between server and client.

### Don't Read Version from Workspace package.json

```typescript
// ❌ WRONG: In Docker, cwd is apps/web, finds stale workspace version
const pkg = JSON.parse(readFileSync('package.json'))

// ✅ CORRECT: Check root paths FIRST
const possiblePaths = [
  '/app/package.json',               // Docker root (highest priority)
  resolve(cwd, '../../package.json'), // From apps/web to root
  resolve(cwd, 'package.json'),       // Fallback
]
```

**Why**: npm workspaces change cwd to the workspace directory. Root package.json should be single source of truth for version.

---

## Quick Reference Table

| Pattern | Wrong | Correct |
|---------|-------|---------|
| Route files | `index.tsx` | `prospects-pipeline.tsx` |
| Server function files | `prospects.ts` | `prospectsFn.ts` |
| Parameter safety | `params.field` | `safeParams?.field` |
| Search params | Skip loaderDeps | Use loaderDeps |
| Path params | Use loaderDeps | Use params directly |
| Auth in handlers | Inline auth logic | getServerAuth() |
| Auth middleware | .middleware([auth]) | getServerAuth() |
| DB connections | Create per request | Shared connection |
| Cache keys | `['prospects']` | `['prospect']` (singular) |
| Server fn params | `fn({ search })` | `fn({ data: { search } })` |
| Production server | Run server.js directly | Wrap with Hono |
| Static files | TanStack handler only | Serve before catch-all |
| tanstackStart() | Pass config options | No arguments |
| ssr.noExternal | Missing seroval | Include seroval |
| Version source | Workspace package.json | Root package.json |

---

## Common Error Messages

### "Cannot read properties of undefined"

Usually means `params` is undefined:

```typescript
// Fix: Add safe parameter handling
const safeParams = params || {}
```

### "User not authenticated"

Usually means auth wasn't called or failed:

```typescript
// Fix: Check auth context
const authContext = await getServerAuth(['admin'])
// If this throws, user isn't authenticated or lacks role
```

### "loaderDeps is undefined"

Usually means you're accessing `deps` but didn't define `loaderDeps`:

```typescript
// Fix: Add loaderDeps for search parameters
loaderDeps: ({ search }) => ({
  param: search?.param,
}),
```

### Hydration Mismatch

Usually means CJS/ESM issues:

```typescript
// Fix: Add to vite.config.ts optimizeDeps.include
// See debugging.md for details
```

### 404 for CSS/JS in Production

TanStack Start handler doesn't serve static files:

```javascript
// Fix: Add static file routes BEFORE catch-all in server.mjs
app.use('/assets/*', serveStatic({ root: './dist/client' }))
```

### "Cannot find module 'seroval'"

Missing from ssr.noExternal:

```typescript
// Fix: Add seroval to vite.config.ts
ssr: {
  noExternal: [/seroval/],
}
```

### Wrong Version Displayed

Reading from workspace package.json instead of root:

```typescript
// Fix: Check root paths first, Docker cwd is apps/web
// See production-deployment.md for correct path order
```
