# Server functions

Distilled from `@tanstack/start-client-core` skills `start-core/server-functions`
and `start-core/execution-model`, plus our own decisions. Scoped to what
business apps need — RPC from a component to the server, guarded and validated.

## The shape

```ts
export const getItemBrowse = createServerFn({ method: 'GET' })
  .validator(validateInput('getItemBrowse', browseSchema))
  .handler(
    logFailures('getItemBrowse', async ({ data }) => {
      await requireSession()        // the handler's first statement, always
      return browseItems(data)
    }),
  )
```

Call it as `getItemBrowse({ data: params })`. The `{ data }` wrapper is required
on both sides — the argument is `{ data }`, the handler destructures `{ data }`.

`GET` for reads, `POST` for writes. A `GET` server function can be cached and
prefetched by the router; a `POST` never is.

## Auth is a line in the handler, not middleware

**Every server function's handler calls `requireSession()` — or
`requireSession(roles)` where a role is required (`auth.md`) — as its first
statement.** No exceptions, including functions that "only read" — a reader is
still a data leak.

The validator runs before the handler, so it runs before `requireSession`: an
unauthenticated request with a malformed payload is refused by the validator
and logged as rejected input, never reaching the auth check. That is acceptable
because the validator only parses — it reads nothing and touches nothing — so
keep it that way: a validator never queries the database or calls another
service.

**We do not use `createMiddleware` for auth.** This is a settled position, not an
oversight:

- Middleware's only real capability over a plain call is that it can run code
  *after* the handler, including on error. The one thing we run there — failure
  logging — is a plain function (below). Everything else it offers is saved typing.
- It has cost real time. TanStack/router **#2783** — server-function middleware
  pulled server code into the client bundle — was open from Nov 2024 to Feb 2026.
- Open: **#7213** (a middleware calling a server function
  from another file throws `Server function info not found`; later reports say it
  hangs in production on Vite 8) and **#7459** (`createMiddleware is not a
  function` on cold-start SSR in vite dev, labelled `needs-upstream-fix`).

Upstream's own docs use `authMiddleware` as their headline example. That is not
a reason to adopt it — docs showing a pattern says nothing about whether it
breaks in a given setup.

Anything wrapped around every server function is a plain higher-order function
in our own code, as `logFailures` is: it runs before and after, composes fine, and
cannot be broken by a framework release.

## Every server function logs its own failure and redacts it

**Start logs neither a handler's throw nor a validator's refusal, and it sends
the error to the browser.** A handler's throw is caught by Start's middleware
runner, returned as a value and serialized into the response with no console
call (`start-server-core` `server-functions-handler.js`). The validator runs
first, in its own middleware step, and a rejected input becomes
`new Error(JSON.stringify(issues))` (`start-client-core` `createServerFn.js`,
`execValidator`), which takes the same path — field names, expected shapes and
offending keys, word for word. Unwrapped, a driver error, a constraint name or a
hostname is readable by anyone who calls the endpoint, and the server log is
empty.

**How it crosses the wire:** a thrown `Error` is serialized as its message and
nothing else (`router-core` `ShallowErrorPlugin`); any other thrown value is
serialized whole; a `UserFacingError` crosses as its message through its
adapter (below). So a wrapper replaces what was thrown rather than editing it.

**Wrap every handler in `logFailures(name, fn)` and every validator in
`validateInput(name, schema)`.** Each logs the failure with the operation name
and the error, then throws a generic `Error` in its place. Redirects,
not-founds, thrown `Response`s and `UserFacingError`s pass through the handler
wrapper unchanged and unlogged:

```ts
// src/lib/log-failures.server.ts
import { isNotFound, isRedirect } from '@tanstack/react-router'
import type { z } from 'zod'
import { logger } from './logger'                 // the app's pino instance
import { UserFacingError } from './user-facing-error'

const GENERIC_FAILURE = 'Something went wrong. Please try again.'

export function logFailures<A extends unknown[], R>(
  op: string,
  fn: (...args: A) => Promise<R>,
): (...args: A) => Promise<R> {
  return async (...args) => {
    try {
      return await fn(...args)
    } catch (err) {
      if (isOutcome(err)) throw err
      logger.error({ err, op }, 'server function failed')
      throw new Error(GENERIC_FAILURE)
    }
  }
}

// A Standard Schema object, so Start types the caller's `data` from the schema's
// input and the handler's from its output. It throws before returning issues,
// because Start would otherwise ship them.
export function validateInput<S extends z.ZodType>(op: string, schema: S) {
  return {
    '~standard': {
      version: 1 as const,
      vendor: 'app',
      types: undefined as unknown as { input: z.input<S>; output: z.output<S> },
      validate: async (raw: unknown): Promise<{ value: z.output<S> }> => {
        const result = await schema.safeParseAsync(raw)
        if (result.success) return { value: result.data }
        logger.error({ err: result.error, op }, 'server function input rejected')
        throw new Error(GENERIC_FAILURE)
      },
    },
  }
}

// A redirect, a not-found, a thrown status and a deliberate refusal are answers,
// not failures: the client needs them intact, and logging them buries the real ones.
function isOutcome(err: unknown): boolean {
  return isRedirect(err) || isNotFound(err) || err instanceof Response
    || err instanceof UserFacingError
}
```

`validateInput` is an object, not a function, because Start types a function
validator's output as its return type un-awaited — an async function would type
`data` as a `Promise` (`router-core` `validators.d.ts`,
`ResolveValidatorOutputFn`). The `types` field exists only for the type checker,
as the Standard Schema contract allows; `validate` is what runs.

**The file keeps its `.server` suffix and lives beside the server functions that
use it.** The suffix makes import protection fail the build if the logger ever
reaches the client bundle, and it never does from a server-function module: the
client build replaces the handler with a fetch stub, strips the `.validator(…)`
call (`start-plugin-core` `handleCreateServerFn.js`, `stripMethodCall`), and
then removes every import left unreferenced (`compiler.js`,
`deadCodeElimination`) — `logFailures` and `validateInput` included.

**Pass the error object under `err`, never `err.message`.** Pino's `err`
serializer writes the type, the message and stack with every `cause` appended; a
string loses the cause, which is usually the part that names the real fault.

The names and the call shapes `.handler(logFailures('opName', fn))` and
`.validator(validateInput('opName', schema))` are fixed: the kit's Biome plugin
`biome-plugins/server-fn-logging.grit` fails lint on any
`createServerFn(…).handler(x)` or `.validator(x)` whose `x` is not that call. One
that genuinely must not be wrapped — and so is neither logged nor redacted —
carries the suppression on the line above, with the reason:

```ts
  // biome-ignore lint/plugin/server-fn-logging: <why this one must not log>
  .handler(async () => …)
```

## A server function's error message is never shown to the user

**Only a `UserFacingError`'s message is written for the user.** Every other error
reaching the client is the wrappers' generic replacement — a handler failure or a
rejected input — or a framework error.
A caller never renders `error.message` from those: it shows its own general
statement naming the system and the impact (constitution §X), and the detail
lives in the server log `logFailures` wrote.

**A message written for the user is a `UserFacingError`, and the caller checks
for that type.** Start rebuilds every other error as a plain `Error`, so the
subclass survives the wire only through a serialization adapter registered in
`src/start.ts`:

```ts
// src/lib/user-facing-error.ts — client-safe; the server throws it, the client checks it
import { createSerializationAdapter } from '@tanstack/react-router'

export class UserFacingError extends Error {
  override name = 'UserFacingError'
}

export const userFacingErrorAdapter = createSerializationAdapter({
  key: 'user-facing-error',
  test: (v): v is UserFacingError => v instanceof UserFacingError,
  toSerializable: (e) => e.message,
  fromSerializable: (message) => new UserFacingError(message),
})
```

```ts
// src/start.ts — defining this file removes Start's default CSRF middleware,
// so it is added back here (see "The CSRF middleware is not authentication")
import { createCsrfMiddleware, createMiddleware, createStart } from '@tanstack/react-start'
import { setResponseHeader } from '@tanstack/react-start/server'
import { userFacingErrorAdapter } from './lib/user-facing-error'

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS'])

// Every response Start builds depends on who is asking (see below).
const noStore = createMiddleware().server(({ next }) => {
  setResponseHeader('cache-control', 'no-store')
  return next()
})

export const startInstance = createStart(() => ({
  serializationAdapters: [userFacingErrorAdapter],
  requestMiddleware: [
    createCsrfMiddleware({
      // Server functions, and any state-changing server route except the
      // webhooks, whose callers send no Origin (webhooks.md).
      filter: (ctx) =>
        ctx.handlerType === 'serverFn'
        || (!SAFE_METHODS.has(ctx.request.method) && !ctx.pathname.startsWith('/api/webhooks/')),
    }),
    noStore,
  ],
}))
```

**A request middleware logs its own failure and answers with a `Response`.**
During a server-function call, an error it throws is serialized to the browser
with its message, and Start's only record of it is a bare `console.error`
(`start-server-core` `createStartHandler.js` → `createServerFnErrorResponse`);
on any other request it reaches the server entry (`deployment.md`). Neither
wrapper is in its path. Wrap the middleware's own work, not `next()`:

```ts
const tenant = createMiddleware().server(async ({ next, request }) => {
  let tenantId: string
  try {
    tenantId = await resolveTenant(request)
  } catch (err) {
    logger.error({ err }, 'tenant middleware failed')
    throw new Response('Something went wrong. Please try again.', { status: 500 })
  }
  return next({ context: { tenantId } })
})
```

A thrown `Response` is sent as it is, with no logging and no serialization of
anything else.

```ts
// the caller
const message = error instanceof UserFacingError
  ? error.message
  : "Couldn't save your changes — nothing was changed."
```

## The route guard is not the security boundary

**A server function is an HTTP endpoint that exists whether or not any route
renders it.** The client call compiles to a `fetch` addressed by a generated
function id embedded in the client bundle, so the handler is reachable directly —
by anything that can read that id out of the shipped JS — with no route involved
and no `beforeLoad` in the path. This is the fact the rest of this section rests
on, and it is the part that gets missed: "the guard is weak" and "the endpoint is
exposed" are different claims, and only the second explains why an app whose
guard could never be bypassed still needs the check.

Upstream says it in its own guide: *"Server functions are API endpoints reachable
independently of whichever route renders the calling UI … `beforeLoad` is useful
route UX, but it is not the data boundary."*

A `beforeLoad` redirect protects *navigation*. It runs on the client during a
client-side navigation and can be bypassed. **Data protection is `requireSession()`
inside each server function, independently, every time.** Both exist; only one
is a boundary.

### The CSRF middleware is not authentication

Start installs `createCsrfMiddleware()` for server functions by default; an app
that defines `src/start.ts` adds it explicitly, and the filter above extends it
to state-changing server routes, which a session cookie authenticates just as it
does a server function. It rejects a request
carrying none of `Sec-Fetch-Site`, `Origin`, or `Referer`, so a bare `curl` gets
a 403 — which reads, wrongly, as the endpoint being protected.

It compares those headers against the request origin and does nothing else. A
caller sets its own headers, so any scripted client passes. It stops a browser
sitting on another site from spending a victim's cookies; it establishes no
identity. Never let its presence stand in for the in-handler check.

## One session implementation, shared; one resolver per app

**The helpers are named `getSession` and `requireSession`, in every app, in
`lib/auth/session.ts`.** `getSession` returns the context or null and never
throws; `requireSession` returns it or refuses. A per-app name
(`requireCustomer`, `getServerAuth`, `requireDealerUser`) buys nothing and costs
a reader having to learn which of five near-identical functions this app calls.

**They are built from one shared factory, never hand-copied per app.** Copying
is how five apps end up with five subtly different session reads, and how a fix
to one of them silently fails to reach the other four.

`createSessionHelpers` lives in the project's shared server package — the one
the apps already import their database client from — never in an app. What it
holds is the *security semantics*: read the session, re-read the role from the
user table, refuse. It hands the fresh `role` to `resolve`. What each app
supplies is only its identity mapping:

```ts
export const { getSession, requireSession } = createSessionHelpers<AppContext>({
  auth,                                  // this app's auth instance
  getHeaders: () => getRequestHeaders(), // see the note below
  resolve: ({ user, sessionId, role }) => {
    if (!permittedInThisApp(user)) return null   // null === refused
    return { userId: user.id, /* app's own entity fields */ }
  },
  onDenied: () => { throw redirect({ to: '/login' }) },
})
```

These are load-bearing:

**A resolver returns null to refuse.** "Authenticated, but has no business in
this app" and "not signed in" land on the same `onDenied`, so a signed-in
stranger cannot tell the two apart by probing.

**`onDenied` is typed `() => never`.** A policy that forgets to throw is then a
compile error rather than a silent auth bypass. (TS only applies never-returning
narrowing when the call target has an explicit type annotation — if the factory
destructures the config, annotate the local: `const onDenied: () => never =
config.onDenied`.)

**The factory takes `getHeaders`, it does not import `getRequestHeaders`.** The
shared module is usually consumed by non-TanStack workspaces too (a queue worker,
an ingest service). Reaching for `@tanstack/react-start/server` inside it drags a
dependency into builds that have no business carrying one.

### Re-read the role from the database, not the session cookie

Better Auth caches the user row in the session cookie (`cookieCache`, commonly 5
minutes). A role read off the cached session is stale by up to that long, so a
capability **revoked** still works for five minutes. The factory reads the role
column from the user table on every call instead, before `resolve` sees it. Authorization is the one thing not worth
serving stale.

The extra query is a single indexed primary-key lookup. An app whose context
exposes no role at all can skip it — and only that app.

### The denial policy is per-app, deliberately

A browser SPA usually wants `throw redirect({ to: '/login' })`, so a session that
dies while the app is mounted bounces to login instead of leaving stale authed UI
on screen. A redirect thrown from a server function reached through the query
client navigates because `setupRouterSsrQueryIntegration` handles it
(`queries-and-mutations.md`); one called directly from a component goes through
`useServerFn`, which wires the throw into the router.

Anything non-browser throws `Response` with a real status instead. Use **401**
for "not signed in" and **403** for "signed in, not allowed" — sending an
authenticated-but-unauthorized caller to sign in again loops them through a fix
that cannot work.

## Validation

Pass `.validator()` `validateInput(name, schema)` with the same Zod schema the
client form validates with — export it so there is one definition, not two that
drift. The schema's input type is what the caller must send, so it must be
serializable: `z.number()`, not `z.coerce.number()`, whose input is `unknown`.

Validating the *shape* of a client-sent id is not authorization. A well-formed
`clientid` is still not one this user may read. Re-check ownership against the
session before using any client-supplied identifier as a query filter.

## What runs where

Server functions are **server-only**. The handler and the validator are stripped
from the client bundle, and the imports only they used go with them; only a
fetch stub remains (`start-plugin-core` `handleCreateServerFn.js`). That is why
database imports inside them are safe and the same import in a component is
not.

A module that must never reach the client and cannot take a `.server` name —
`lib/auth/session.ts`, say — starts with `import '@tanstack/react-start/server-only'`,
which import protection treats as the same marker. Import protection only warns
in dev and fails the build, so a violation surfaces at `vite build`
(upstream `start-core/execution-model`, § Marking Whole Files).

Route **loaders are isomorphic** — they run on the server during SSR and on the
client during navigation. Anything a loader touches directly must be safe in
both. In practice a loader should only call server functions and the query
client, never a database module.

## Responses that depend on who is asking

**Every response Start builds is `Cache-Control: no-store`, set once by the
`noStore` request middleware above.** Every server function calls
`requireSession`, and every page behind sign-in renders one user's data, so
none of them may be kept: `private` still lets a browser keep one account's
response after sign-out, and `public` lets a shared cache hand it to the next
account (upstream `guide/production-checklist.md`). The header reaches page,
server-function and server-route responses alike, because Start merges the
response helpers' headers into every response it builds
(`start-server-core` `internal-request-response.js`). Static files are served
by the app's server entry, not by Start, and keep their own cache headers
(`deployment.md`).

## Where they live

**A server function is defined in `apps/<app>/src/lib/serverFunctions/<domain>Fn.ts`,
one module per domain, or in the web tier package when two apps share it.** It
is defined nowhere else — never in a route file, so a route file can be read for
what it renders.

It is called from three places: a route's loader or `beforeLoad`, a query or
mutation definition (`queries-and-mutations.md`), and a component through
`useServerFn` when the call throws a redirect or not-found the router must act
on.

## Server routes the app calls

A server route the app's own pages call — a file download, an upload, an export
— follows the same rules as a server function:

- **Its handler calls `requireSession()` first.** The route's URL is public.
- **It logs its own failure and returns a `Response`** (`webhooks.md`). What it
  throws is caught by the server entry, logged there, and answered by
  `handleStartError` with a generic JSON body that carries neither the message
  nor the stack (upstream `guide/server-entry-point.md`, § Error handling).
- **A state-changing one is covered by the CSRF filter above.**
