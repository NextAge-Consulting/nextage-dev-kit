# Server functions

Distilled from `@tanstack/start-client-core` skills `start-core/server-functions`
and `start-core/execution-model`, plus our own decisions. Scoped to what
business apps need — RPC from a component to the server, guarded and validated.

## The shape

```ts
export const getItemBrowse = createServerFn({ method: 'GET' })
  .validator((raw: unknown) => browseSchema.parse(raw))
  .handler(async ({ data }) => {
    await requireSession()          // auth FIRST, always
    return browseItems(data)
  })
```

Call it as `getItemBrowse({ data: params })`. The `{ data }` wrapper is required
on both sides — the argument is `{ data }`, the handler destructures `{ data }`.

`GET` for reads, `POST` for writes. A `GET` server function can be cached and
prefetched by the router; a `POST` never is.

## Auth is a line in the handler, not middleware

**Every server function calls `requireSession()` (or the role-checking variant)
as its first statement.** No exceptions, including functions that "only read"
— a reader is still a data leak.

**We do not use `createMiddleware` for auth.** This is a settled position, not an
oversight:

- Middleware's only real capability over a plain call is that it can run code
  *after* the handler, including on error. We have nothing that needs wrapping.
  Everything else it offers is saved typing.
- It has cost real time. TanStack/router **#2783** — server-function middleware
  pulled server code into the client bundle — was open from Nov 2024 to Feb 2026.
- Still open as of Aug 2026: **#7213** (a middleware calling a server function
  from another file throws `Server function info not found`) and **#7459**
  (`createMiddleware is not a function` on cold-start SSR in vite dev).

Upstream's own docs use `authMiddleware` as their headline example. That is not
a reason to adopt it — docs showing a pattern says nothing about whether it
breaks in a given setup.

If we ever genuinely need something wrapped around every server function, the
answer is a plain higher-order function in our own code (`withAuth(handler)`),
which runs before and after, composes fine, and cannot be broken by a framework
release.

## The route guard is not the security boundary

A `beforeLoad` redirect protects *navigation*. It runs on the client during a
client-side navigation and can be bypassed. **Data protection is `requireSession()`
inside each server function, independently, every time.** Both exist; only one
is a boundary.

## Validation

`.validator()` receives the raw input and must return the parsed value. Use the
same Zod schema the client form validates with — export it so there is one
definition, not two that drift.

Validating the *shape* of a client-sent id is not authorization. A well-formed
`clientid` is still not one this user may read. Re-check ownership against the
session before using any client-supplied identifier as a query filter.

## What runs where

Server functions are **server-only**. Their body is stripped from the client
bundle; only a fetch stub remains. That is why database imports inside them are
safe and the same import in a component is not.

Route **loaders are isomorphic** — they run on the server during SSR and on the
client during navigation. Anything a loader touches directly must be safe in
both. In practice a loader should only call server functions and the query
client, never a database module.

## Where they live

`apps/<app>/src/lib/serverFunctions/<domain>Fn.ts`, one module per domain. Routes
import from there; nothing else does. Keeping them out of route files means a
route file can be read for what it renders.
