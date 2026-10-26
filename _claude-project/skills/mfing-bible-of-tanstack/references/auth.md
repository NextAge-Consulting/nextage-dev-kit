# Auth

Ours, with the framework mechanics distilled from `router-core/auth-and-guards`
and `start-core/auth-server-primitives`.

## Two layers, only one of them is a boundary

**Navigation guard** — a `beforeLoad` on a pathless layout route (`_authed.tsx`)
that redirects an anonymous visitor to `/login`. Every screen lives under it, so
protection is the default and a route added outside it is public. That is almost
never what anyone intends, so treat a top-level route as a red flag in review.

**Data protection** — `requireSession()` as the first line of every server
function, independently, every time.

The guard runs on the client during navigation and can be bypassed. It exists for
user experience, not security. If only one of the two is present, it must be the
second.

## Never a shared betterAuth factory

Export the configured instance per app; do not wrap `betterAuth({...})` in a
factory and export its return type.

better-auth's instance type is enormous. Exporting it from a factory makes
TypeScript infer and propagate that type into every consumer, and the type-check
exhausts memory. The symptom is `tsc` OOMing with no useful error, which is a
miserable afternoon.

Share reusable helper *bodies* between apps. Keep `betterAuth({...})` itself
inline in each app's `lib/auth/`.

## A dead session must not leave a screen sitting there

Guards only fire on navigation, so an open screen with an expired session shows
authed UI indefinitely while its queries fail. `requireSession()` throws a
redirect, and the SSR Query integration navigates on it — see
`queries-and-mutations.md`. Signing out clears the query cache
(`data-loading.md`).

## Cookies

**Add a cookie with `setCookie` or `appendResponseHeader('set-cookie', …)`,
never `setResponseHeader('set-cookie', …)`.** The last replaces every cookie on
the outgoing response, including the session cookie better-auth set a moment
earlier (upstream *Migrate from the Release Candidate*, § Response helpers).

## Better Auth checks its schema

**Better Auth compares the Drizzle schema it is given against its own model and
rejects auth requests when they disagree** — a missing table or column, or a
column it never writes that is `NOT NULL` with no default (`@better-auth/core`
`db/schema-check.mjs`; the mismatch error names each column). A legacy column on
a shared user or account table is the usual cause: every sign-up fails until the
column is nullable or has a default. Run `npx auth check schema` before
deploying an auth-table change or a better-auth upgrade; it reports the same
findings and changes nothing. Turning the check off
(`advanced.database.validateSchema: false`) is a decision recorded in a comment
beside it, never a fix.

## Roles

Where a role check exists, it belongs in the same call that establishes the
session, so there is one thing to forget rather than two:

```ts
const session = await requireSession(['admin', 'manager'])
```

Per `design.md`: a control the *role* cannot use is removed from the DOM; a
control blocked by *record status* stays visible, disabled, with a tooltip saying
why. Both are UI conveniences — the server re-checks regardless.

## Organizations

Better Auth's `organization` plugin lets a signed-in user accept an invitation
whose email matches theirs, whether or not that email is verified
(GHSA-fmh4-wcc4-5jm3). Configure it with
`organization({ requireEmailVerificationOnInvitation: true })`, unless sign-in
already requires a verified email (`emailAndPassword.requireEmailVerification: true`).

## Passwords

Where a legacy application shares the database, the password write path is
whatever keeps both applications working — typically a dual-write inside one
transaction, with the framework's own change-password endpoint disabled so there
is exactly one path. Verify the current password explicitly; there is no
framework check to lean on once that endpoint is off.

Do not impose password rules the legacy application does not enforce. A rule only
one app applies is a rule users route around by changing their password in the
other one.
