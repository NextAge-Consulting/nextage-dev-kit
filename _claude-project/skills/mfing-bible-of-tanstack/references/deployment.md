# Deployment

Ours. The build output and the server that runs it — the parts that only show up
in production, where getting them wrong means a container that starts and then
404s everything.

## The build does not produce a server

`dist/server/server.js` is a **fetch handler**, not a runnable HTTP server.
`node dist/server/server.js` starts nothing. Something has to import it and serve
it.

We use a small Hono entry (`apps/<app>/server-start.mjs`) that:

- serves static files from `dist/client` with cache headers,
- answers `/health` before reaching SSR, so a load-balancer probe never depends
  on the app rendering,
- forwards everything else to the fetch handler,
- handles graceful shutdown.

That file is **ours, not build output**. It is not bundled, it is not generated,
and it must be copied into the image.

## Static files are not served for you

Nothing serves `dist/client` unless you write it. The failure looks like the app
working in dev and returning 404s for every CSS and JS asset in production — the
HTML renders, the page is unstyled, the console is full of missing chunks.

## Bundle what npm layout would otherwise decide

Vite inlines a dependency's own code into the SSR output but leaves its
dependencies as bare imports resolved at runtime. When npm nests a package under
`some-dep/node_modules` — because a different major is hoisted to the root — Node
resolving from `dist/` cannot see it.

Dev never shows this, because Vite resolves through the real module graph. The
container fails on the first request with `ERR_MODULE_NOT_FOUND`.

Fix it by bundling those into the server build via `ssr.noExternal`, which makes
the output self-contained and immune to hoisting changes. Add packages there when
this bites, not preemptively — and comment *why* each entry is listed, because
the reason is invisible from the package name.

## Version has to be read at runtime, from the right file

Reading the version from a workspace `package.json` gives you the workspace's
version, not the release's. Read it at runtime from a known absolute path in the
image, and have the Dockerfile put the right one there.

## Runtime assets live outside `src/`

Anything read from disk at runtime — email templates, PDFs, certificates — goes
in `server-assets/` and is resolved via `process.cwd()`, never `import.meta.url`.
Bundlers rewrite `import.meta.url` and do not copy the referenced file, so it
resolves to a path that does not exist in the image. The Dockerfile must copy
`server-assets/` explicitly.

## Where the framework's own deployment guidance applies

Start builds through Vite and Nitro/h3, and upstream documents targets for
Cloudflare Workers, Vercel, Netlify, Bun and plain Node. We deploy the Node/
Docker path with our own Hono entry, so most of that is not our concern — read
it from `node_modules/@tanstack/start-client-core/skills/start-core/deployment/`
in the session that needs a different target.
