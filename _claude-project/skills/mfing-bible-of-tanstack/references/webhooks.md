# Server routes and webhooks

Distilled from `@tanstack/start-client-core` skill `start-core/server-routes`,
plus our decisions. This is how an outside system reaches us — payment
providers, accounting integrations, device callbacks.

## Server route, not server function

A server function is internal RPC: it is called by our own client, and its wire
format is ours. A **server route** is a public HTTP endpoint with a URL an
external system posts to.

```ts
export const Route = createFileRoute('/api/webhooks/<provider>')({
  server: {
    handlers: {
      POST: async ({ request }) => { /* … */ },
    },
  },
})
```

Both are bundled into the app. The difference is who calls them and whether the
URL is a contract you cannot change.

## Read the raw body before anything parses it

Signature verification hashes the **exact bytes** the provider sent. Any JSON
parse-and-restringify changes whitespace or key order and the signature fails —
intermittently and unreproducibly, which is the worst possible failure shape.

Read `await request.text()` first, verify against it, and only then parse.

## Verify the signature before doing any work

A webhook URL is public. Treat every request as hostile until the signature
checks out, and do that before touching the database, enqueuing anything, or
logging the payload.

Signature verification failure is a `401`, logged with enough detail to
diagnose, and nothing else happens.

## Every outcome is a `Response` the handler returns

**A server route handler logs its own failure through the app's logger and
returns a generic `Response`; it never lets an error escape.** A thrown error
becomes Start's generic JSON `500` and a bare `console.error`, outside the app's
structured log (upstream `guide/server-entry-point.md`, § Error handling). The
server entry's catch (`deployment.md`) is the net for what slips through, not the
plan.

## Answer fast, work afterwards

Providers retry on timeout, so slow processing produces duplicate deliveries.
Acknowledge with a `2xx` as soon as the payload is verified and recorded, then do
the real work — a job, a queue, or a background task.

## Assume redelivery

Every provider retries, and some deliver the same event more than once even on
success. Handlers must be idempotent: key on the provider's event id and ignore
one already processed. "It only happens under load" is the signature of a handler
that assumed exactly-once.

## Do not put auth middleware in front of them

A webhook has no session. Its authentication *is* the signature check inside the
handler. Its caller is a server, which sends no `Origin`, so the CSRF middleware
would refuse it: webhooks live under `/api/webhooks/`, the path the CSRF filter
skips (`server-functions.md`).
