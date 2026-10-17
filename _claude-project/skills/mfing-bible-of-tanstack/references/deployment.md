# Deployment

Ours. The build output and the server that runs it — the parts that only show up
in production, where getting them wrong means a container that starts and then
404s everything.

## The build does not produce a server

`dist/server/server.js` is a **fetch handler**, not a runnable HTTP server.
`node dist/server/server.js` starts nothing. Something has to import it and serve
it.

We use a small Hono entry, `apps/<app>/server-start.mjs`:

```js
import { serve } from '@hono/node-server'
import { serveStatic } from '@hono/node-server/serve-static'
import { Hono } from 'hono'
import handler from './dist/server/server.js'

const app = new Hono()

// Answered before SSR, so a load-balancer probe never depends on the app rendering.
app.get('/health', (c) => c.text('ok'))

// Hashed build assets never change under their name; everything else revalidates.
app.use('/assets/*', serveStatic({
  root: './dist/client',
  onFound: (_path, c) => { c.header('Cache-Control', 'public, max-age=31536000, immutable') },
}))
app.use('*', serveStatic({
  root: './dist/client',
  onFound: (_path, c) => { c.header('Cache-Control', 'no-cache') },
}))

app.all('*', (c) => handler.fetch(c.req.raw))

const server = serve({ fetch: app.fetch, port: Number(process.env.PORT ?? 3000) })

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => server.close(() => process.exit(0)))
}
```

That file is **ours, not build output**. It is not bundled, it is not generated,
and it must be copied into the image. It is not `src/server.ts`: that file is
Start's server entry (below), and the build compiles it into the
`dist/server/server.js` this one imports.

**Name the file the deploy runs in the package's `start` script** —
`"start": "node server-start.mjs"` — whether a Dockerfile `CMD` or a process
manager starts it. Nothing imports a server entry, and knip reads package scripts
but never a Dockerfile or service unit; an entry named nowhere else is reported
as an unused file.

## Errors that escape Start go to the app's log

**Every app has a `src/server.ts` that catches what escapes Start, logs it through
the app's logger, and returns `handleStartError(error)`.** Start picks up
`src/server.ts` as its server entry and builds it into `dist/server/server.js`
(`start-plugin-core` `planning.js`, `defaultEntry: "server"`). Without the catch,
a failure in SSR or a server route reaches only `console.error`, outside the
structured log (upstream `guide/server-entry-point.md`, § Error handling):

```ts
// src/server.ts
import { createStartHandler, defaultStreamHandler, handleStartError } from '@tanstack/react-start/server'
import { createServerEntry } from '@tanstack/react-start/server-entry'
import { logger } from './lib/logger'

const startHandler = createStartHandler(defaultStreamHandler)

export default createServerEntry({
  async fetch(request, opts) {
    try {
      return await startHandler(request, opts)
    } catch (err) {
      logger.error({ err, url: request.url }, 'request failed')
      return handleStartError(err)
    }
  },
})
```

Call the handler `createStartHandler` returns, never the default export of
`@tanstack/react-start/server-entry`: the default export converts the error
before this catch can see it. Server-function failures, and request-middleware
failures during a server-function call, take their own path and never reach this
catch — the wrappers and the middleware's own catch cover them
(`server-functions.md`).

## Static files are not served for you

Nothing serves `dist/client` unless you write it. The failure looks like the app
working in dev and returning 404s for every CSS and JS asset in production — the
HTML renders, the page is unstyled, the console is full of missing chunks.

## Pin Tailwind's scan root, or production ships unstyled

**The Tailwind entry must name its own scan root:**

```css
@import "tailwindcss" source("./");
```

A bare `@import "tailwindcss"` leaves Tailwind v4 to find the root by walking the
filesystem. The generated CSS then depends on what surrounds the source tree
rather than on the source tree alone — so the same commit yields different CSS in
a container than on a developer machine.

**The damage is that the client and SSR passes each generate and hash their own
stylesheet.** The client emits `styles-<a>.css`; the server bundle inlines
`const styles = "/assets/styles-<b>.css"` from the `?url` import. Two hashes, one
file on disk.

Nothing fails. The build is green, both passes report success, SSR renders, every
JS chunk loads with a 200. The page arrives **unstyled**, with a single 404 on the
stylesheet.

**It cannot be caught locally.** A local build resolves the root the same way
twice, so the hashes agree and everything looks correct — including a container
run on the developer's own machine if the image is built from that same tree. It
appears the first time the image is built somewhere else, which is the deploy.

The check that actually proves it, run against the built image rather than the
working tree:

```bash
docker run --rm --entrypoint sh <image> -c \
  'ls  dist/client/assets/ | grep css
   grep -rhoE "styles-[A-Za-z0-9_-]+\.css" dist/server/ | sort -u'
```

Two different names is the bug. They must be one.

Diagnosing this from the symptom is expensive, because the misleading answers are
all plausible: a stale build cache, a `dist` leaking into the build context via a
missing `.dockerignore` entry, plugin order, a missing `.git` changing what
Tailwind ignores. Each can be disproved in turn and none is the cause. Check the
CSS entry file first — it is one line.

## Bundle what npm layout would otherwise decide

Vite inlines a dependency's own code into the SSR output but leaves its
dependencies as bare imports resolved at runtime. When npm nests a package under
`some-dep/node_modules` — because a different major is hoisted to the root — Node
resolving from `dist/` cannot see it. Dev never shows this, because Vite resolves
through the real module graph; the container fails on the first request with
`ERR_MODULE_NOT_FOUND`.

`ssr.noExternal` bundles a package into the server build, so its resolution no
longer depends on the install layout. The packages that need it are listed in
`.claude/stack-manifest.json` under `ssr_no_external`; a package that fails this
way goes into that list, never into one app's config alone, with the reason
beside it.

## A resolvable WRONG major is worse than a missing one

The nastier version is a package Node finds easily and which is the wrong major:
there is no import error — the process starts, then dies inside a call with
`X is not a function`.

The shape, every time: an app depends on a package that needs `dep@4`, npm nests
`dep@4` under it because something unrelated pulled `dep@3` to the root, Vite
inlines the package's code into `dist/server/server.js`, and that inlined code's
bare `import 'dep'` resolves from the APP's directory rather than the package's.
It gets the root's `dep@3`. Dev resolves through the real module graph, where
the nested copy is still the nearest one, so dev never shows it.

**The concrete case: `better-auth` needs `zod@4`.** A dependency on `zod@3`
elsewhere in the tree hoists it to the root, `zod@4` lands under
`better-auth/node_modules`, and the bundled auth code calls a Zod 4 method that
does not exist on Zod 3:

```
TypeError: sessionSchema.loose is not a function
```

**An app declares, in its own `package.json`, the major its bundled code
needs.** npm then places that major in `apps/<app>/node_modules`, the first place
resolution looks from `apps/<app>/dist/server/`, whatever the root hoist is.
This is the half that protects the app: `scripts/check-stack.mjs` fails an app
that uses `better-auth` without declaring `zod@4` (`ssr_no_external.requireDeclared`
in the manifest).

**`ssr.noExternal` with the manifest's list is the second half**, which removes
the runtime resolution entirely; the check advises when an app's config does not
cover it (`adviseSsrNoExternal`):

```ts
ssr: { noExternal: [/better-auth/, "@noble/ciphers", "@noble/hashes", "zod"] }
```

The `@noble/*` entries are the same failure — `managedNonce is not exported`
(better-auth#7494) and a bare `ERR_MODULE_NOT_FOUND`, both a hoisted major
winning over a nested one.

## Version has to be read at runtime, from the right file

Reading the version from a workspace `package.json` gives you the workspace's
version, not the release's. The Dockerfile writes the release's version to
`server-assets/version.json`, and the app reads it at runtime like any other
runtime asset (below).

## Runtime assets live outside `src/`

Anything read from disk at runtime — email templates, PDFs, certificates — goes
in `server-assets/` and is resolved via `process.cwd()`, never `import.meta.url`.
Bundlers rewrite `import.meta.url` and do not copy the referenced file, so it
resolves to a path that does not exist in the image. The Dockerfile must copy
`server-assets/` explicitly.

## Before a release goes to production

Run the checks from upstream's `guide/production-checklist.md` that a
back-office app can fail:

- call each server function and server route directly — signed out, and as an
  account that may not see the record;
- request the same URL as two accounts at once and compare what comes back;
- read the `Cache-Control` the host actually serves on an authenticated page;
- trigger a controlled failure and find it in the logs;
- rehearse the rollback.

## Where the framework's own deployment guidance applies

Start builds through Vite, and upstream documents targets for Cloudflare
Workers, Vercel, Netlify, Bun and plain Node, most of them through Nitro. We deploy the Node/
Docker path with our own Hono entry, so most of that is not our concern — read
it from `node_modules/@tanstack/start-client-core/skills/start-core/deployment/`
in the session that needs a different target.
