# Production Deployment Reference

## Contents

- [Build Output Structure](#build-output-structure)
- [Server Runtime Requirements](#server-runtime-requirements)
- [Hono Server Setup](#hono-server-setup)
- [Static File Serving](#static-file-serving)
- [Docker Deployment](#docker-deployment)
- [Working Directory Considerations](#working-directory-considerations)
- [Version Reading in Production](#version-reading-in-production)

---

## Build Output Structure

After `vite build`, TanStack Start 1.132+ outputs:

```
dist/
├── server/
│   └── server.js        # TanStack Start fetch handler (NOT a standalone server!)
└── client/
    ├── assets/          # Hashed JS/CSS bundles (immutable)
    │   ├── index-[hash].js
    │   └── index-[hash].css
    ├── images/          # Static images from public folder
    ├── favicon.ico
    ├── robots.txt
    └── site.webmanifest
```

**CRITICAL**: `dist/server/server.js` is a **Web-standard fetch handler**, NOT a runnable server. It exports a `fetch` function that must be wrapped by a server runtime.

```javascript
// What server.js exports (conceptually)
export default {
  fetch: async (request: Request) => Response
}
```

---

## Server Runtime Requirements

TanStack Start's fetch handler needs a runtime to:

1. **Listen on a port** - Accept incoming HTTP requests
2. **Serve static files** - Serve `dist/client/` assets (CSS, JS, images)
3. **Forward other requests** - Pass non-static requests to TanStack handler

### Why Static Files Must Be Handled Separately

The TanStack Start handler processes:
- Server-side rendering (SSR)
- Server functions
- API routes (via `server.handlers`)

It does **NOT** serve static files. Without explicit static file handling, CSS/JS requests return 404 in production.

---

## Hono Server Setup

### Dependencies

```bash
npm add hono @hono/node-server
```

### server.mjs

```javascript
#!/usr/bin/env node

/**
 * Hono Server for TanStack Start 1.132+
 *
 * TanStack Start outputs a fetch handler (dist/server/server.js) that handles
 * SSR and server functions. This Hono server wraps it and adds static file
 * serving from dist/client.
 */

import { Hono } from 'hono'
import { serve } from '@hono/node-server'
import { serveStatic } from '@hono/node-server/serve-static'
import handler from './dist/server/server.js'

const app = new Hono()

const PORT = Number(process.env.PORT) || 3001
const HOST = process.env.HOST || '0.0.0.0'

// Serve static assets with aggressive caching (hashed filenames = immutable)
app.use(
  '/assets/*',
  serveStatic({
    root: './dist/client',
    onFound: (_path, c) => {
      c.header('Cache-Control', 'public, max-age=31536000, immutable')
    },
  })
)

// Serve images
app.use('/images/*', serveStatic({ root: './dist/client' }))

// Serve other static files from public folder
app.use('/favicon.ico', serveStatic({ root: './dist/client' }))
app.use('/favicon.svg', serveStatic({ root: './dist/client' }))
app.use('/robots.txt', serveStatic({ root: './dist/client' }))
app.use('/site.webmanifest', serveStatic({ root: './dist/client' }))

// Let TanStack Start handle everything else (SSR, server functions, API routes)
app.all('*', async (c) => {
  try {
    return await handler.fetch(c.req.raw)
  } catch (error) {
    console.error('Server error:', error)
    return c.text('Internal Server Error', 500)
  }
})

// Start server
console.log(`Server starting on http://${HOST}:${PORT}`)

serve({
  fetch: app.fetch,
  port: PORT,
  hostname: HOST,
})

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down...')
  process.exit(0)
})

process.on('SIGINT', () => {
  console.log('SIGINT received, shutting down...')
  process.exit(0)
})
```

### package.json Scripts

```json
{
  "scripts": {
    "build": "vite build",
    "serve": "node server.mjs",
    "dev": "vite dev --port=3001"
  }
}
```

---

## Static File Serving

### Caching Strategy

| Path Pattern | Description | Cache-Control |
|--------------|-------------|---------------|
| `/assets/*` | Hashed bundles (JS, CSS) | `public, max-age=31536000, immutable` |
| `/images/*` | Static images | Default (browser heuristics) |
| `/favicon.ico`, etc. | Root static files | Default |
| `/*` (catch-all) | TanStack Start handler | No caching header |

### Why Hashed Assets Are Immutable

Vite generates content-hashed filenames for JS/CSS:
- `index-a1b2c3d4.js`
- `index-e5f6g7h8.css`

When file content changes, the hash changes. This means:
- Old URLs never change content
- Safe to cache forever (1 year)
- Browser always gets fresh content on deploy

### Adding New Static Files

If you add new static files to `public/`:

```javascript
// Add to server.mjs
app.use('/new-file.json', serveStatic({ root: './dist/client' }))

// Or use wildcard for directories
app.use('/data/*', serveStatic({ root: './dist/client' }))
```

---

## Docker Deployment

### Dockerfile.web

```dockerfile
# ============================================
# Stage 1: Base - Common setup for all stages
# ============================================
FROM node:24-bookworm-slim AS base

WORKDIR /app

# Install dumb-init (proper PID 1 for Node.js in containers)
RUN apt-get update && apt-get install -y --no-install-recommends dumb-init && rm -rf /var/lib/apt/lists/*


# ============================================
# Stage 2: Dependencies - Install all packages
# ============================================
FROM base AS dependencies

# Copy ALL workspace directories for proper npm workspace resolution
COPY package.json package-lock.json ./
COPY packages ./packages
COPY apps ./apps

# Install ALL dependencies (including devDependencies needed for build)
RUN npm ci


# ============================================
# Stage 3: Build - Compile the application
# ============================================
FROM dependencies AS build

# Accept VITE_ variables as build arguments
ARG VITE_BETTER_AUTH_URL
ARG VITE_PUBLIC_STRIPE_PUBLISHABLE_KEY

# Make them available as environment variables during build
ENV VITE_BETTER_AUTH_URL=$VITE_BETTER_AUTH_URL
ENV VITE_PUBLIC_STRIPE_PUBLISHABLE_KEY=$VITE_PUBLIC_STRIPE_PUBLISHABLE_KEY

# Run the build
RUN npm run build:web


# ============================================
# Stage 4: Production - Minimal runtime image
# ============================================
FROM base AS production

ENV NODE_ENV=production

# Copy package files for workspace resolution
COPY package.json package-lock.json ./
COPY packages/shared/package.json ./packages/shared/
COPY apps/web/package.json ./apps/web/

# Install ONLY production dependencies
RUN npm ci --omit=dev

# Copy built application from build stage
COPY --from=build /app/apps/web/dist ./apps/web/dist

# Copy server wrapper
COPY --from=build /app/apps/web/server.mjs ./apps/web/server.mjs

# Copy shared package source (needed for npm workspace resolution at runtime)
COPY --from=build /app/packages/shared/src ./packages/shared/src

# Copy root package.json for version reading
# (already copied above, but mentioning for clarity)

EXPOSE 3001

ENTRYPOINT ["dumb-init", "--"]
CMD ["npm", "run", "serve", "--workspace=web"]
```

### Key Docker Considerations

1. **Multi-stage build** - Separates build dependencies from runtime
2. **dumb-init** - Proper signal handling for Node.js
3. **Workspace structure** - npm workspaces need proper package.json structure
4. **dist/client copied** - Static files must be in the image
5. **server.mjs copied** - The Hono wrapper is NOT in dist/

---

## Working Directory Considerations

### In Docker with npm Workspaces

When running `npm run serve --workspace=web`:

| Context | Value |
|---------|-------|
| Docker WORKDIR | `/app` |
| Actual cwd | `/app/apps/web` (npm changes to workspace) |
| `./dist/client` resolves to | `/app/apps/web/dist/client` |
| Root package.json | `/app/package.json` or `../../package.json` |

### File Paths in server.mjs

All paths in server.mjs are relative to where the server runs:

```javascript
// These are relative to /app/apps/web (the workspace directory)
import handler from './dist/server/server.js'  // OK
serveStatic({ root: './dist/client' })          // OK

// To access root package.json
const rootPkg = '../../package.json'            // From apps/web
const dockerPkg = '/app/package.json'           // Absolute Docker path
```

---

## Version Reading in Production

### The Problem

Version needs to be read from ROOT package.json (single source of truth), but:
- In dev: cwd is repo root
- In Docker: cwd is `/app/apps/web` (npm workspace mode)

### Solution: Multiple Path Fallbacks

```javascript
async function getAppVersion() {
  try {
    const { resolve } = await import('node:path')
    const { readFileSync, existsSync } = await import('node:fs')

    const cwd = process.cwd()

    // Check root paths FIRST to avoid finding stale workspace package.json
    const possiblePaths = [
      '/app/package.json',                    // Absolute Docker path (root) - highest priority
      resolve(cwd, '../../package.json'),     // If cwd is apps/web - go to root
      resolve(cwd, 'package.json'),           // If cwd is repo root
    ]

    for (const pkgPath of possiblePaths) {
      if (existsSync(pkgPath)) {
        const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8'))
        if (pkg.version) return pkg.version
      }
    }

    return 'VERSION_ERROR'
  } catch (error) {
    return 'VERSION_ERROR'
  }
}
```

### Key Points

1. **Check root paths first** - Docker cwd is `/app/apps/web`, so `cwd/package.json` finds workspace package.json (wrong)
2. **Use VERSION_ERROR not UNKNOWN** - Makes misconfiguration obvious
3. **Remove version from workspace package.json** - Only root should have version

---

## Vite Configuration for Production

### Required ssr.noExternal

```typescript
// vite.config.ts
export default defineConfig({
  plugins: [
    tsconfigPaths(),
    tailwindcss(),
    tanstackStart(),  // No arguments in 1.132+
    react(),
  ],
  ssr: {
    // CRITICAL: seroval is required for TanStack Start server runtime
    noExternal: [/use-sync-external-store/, /cookie/, /better-auth/, /seroval/],
  },
})
```

### Why seroval?

`seroval` is used by TanStack Start for serializing data between server and client. Without it in `noExternal`, you'll get module resolution errors in production.

---

## Troubleshooting

### 404 for CSS/JS in Production

**Symptom:** App loads but is unstyled, console shows 404 for `/assets/*.js`

**Cause:** Static files not being served

**Fix:** Verify server.mjs has static file routes:
```javascript
app.use('/assets/*', serveStatic({ root: './dist/client' }))
```

### "Cannot find module 'seroval'"

**Symptom:** SSR errors about seroval module

**Fix:** Add to vite.config.ts:
```typescript
ssr: {
  noExternal: [/seroval/],
}
```

### Wrong Version Displayed

**Symptom:** Version shows old number or "UNKNOWN"

**Cause:** Reading from workspace package.json instead of root

**Fix:** Check path priority in version reading function, ensure root paths checked first

### Server Starts But Requests Timeout

**Symptom:** Server logs "listening" but requests hang

**Cause:** Handler import failing silently

**Fix:** Verify dist/server/server.js exists and is valid:
```bash
node -e "import('./dist/server/server.js').then(m => console.log(Object.keys(m)))"
```
