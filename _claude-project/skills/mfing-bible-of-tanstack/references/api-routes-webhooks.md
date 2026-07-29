# API Routes & Webhooks Reference

## Contents

- [Public API Route Pattern](#public-api-route-pattern)
- [Webhook Implementation](#webhook-implementation)
- [Global Middleware](#global-middleware)
- [Raw Body Handling](#raw-body-handling)
- [Complete Examples](#complete-examples)

---

## Public API Route Pattern

### Use Case

External requests from third-party services (Stripe webhooks, health checks, version endpoints, etc.)

### Pattern

Use `createFileRoute` with `server.handlers`:

```typescript
// File: apps/web/src/routes/api/webhooks/stripe.ts
import { createFileRoute } from '@tanstack/react-router'
import { handleStripeWebhook } from '@/lib/serverFunctions/stripeFn'

export const Route = createFileRoute('/api/webhooks/stripe')({
  server: {
    handlers: {
      POST: async ({ request }) => {
        try {
          // Read raw body (critical for webhook signature verification)
          const rawBody = await request.text()
          const signature = request.headers.get('stripe-signature')

          if (!signature) {
            return new Response(
              JSON.stringify({ error: 'Missing signature header' }),
              { status: 400, headers: { 'Content-Type': 'application/json' } }
            )
          }

          // Process webhook (signature verification happens in handler)
          const result = await handleStripeWebhook(signature, rawBody)

          return new Response(JSON.stringify(result), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          })
        } catch (error: any) {
          console.error('Webhook error:', error)
          return new Response(
            JSON.stringify({ error: 'Webhook processing failed' }),
            { status: 500, headers: { 'Content-Type': 'application/json' } }
          )
        }
      },
    },
  },
})
```

### Key Requirements

1. **Import**: `createFileRoute` from `@tanstack/react-router`
2. **Export**: `Route` (standard file route export)
3. **Method Definition**: `server: { handlers: { GET/POST: async ({ request }) => {...} } }`
4. **Raw Body Access**: Use `request.text()` for webhook signatures
   - NOT `request.json()` if you need to verify signatures
5. **No Authentication**: Public routes don't use auth middleware
   - Verification happens via signatures (Stripe, Clerk, etc.)

---

## Webhook Implementation

### Stripe Webhook Example

```typescript
// File: apps/web/src/routes/api/webhooks/stripe.ts
import { createFileRoute } from '@tanstack/react-router'
import { handleStripeWebhook } from '@/lib/serverFunctions/stripeFn'

export const Route = createFileRoute('/api/webhooks/stripe')({
  server: {
    handlers: {
      POST: async ({ request }) => {
        try {
          const rawBody = await request.text()
          const signature = request.headers.get('stripe-signature')

          if (!signature) {
            return new Response(
              JSON.stringify({ error: 'Missing signature header' }),
              { status: 400, headers: { 'Content-Type': 'application/json' } }
            )
          }

          const result = await handleStripeWebhook(signature, rawBody)

          return new Response(JSON.stringify(result), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          })
        } catch (error: any) {
          console.error('Webhook error:', error)
          return new Response(
            JSON.stringify({ error: 'Webhook processing failed' }),
            { status: 500, headers: { 'Content-Type': 'application/json' } }
          )
        }
      },
    },
  },
})
```

### Version Endpoint Example

```typescript
// File: apps/web/src/routes/api/version.ts
import { createFileRoute } from '@tanstack/react-router'

// Get version from root package.json - handles dev and Docker environments
async function getAppVersion(): Promise<string> {
  try {
    const { resolve } = await import('node:path')
    const { readFileSync, existsSync } = await import('node:fs')

    const cwd = process.cwd()
    const possiblePaths = [
      resolve(cwd, 'package.json'),        // If cwd is repo root
      resolve(cwd, '../../package.json'),  // If cwd is apps/web
      '/app/package.json',                  // Absolute Docker path
    ]

    for (const pkgPath of possiblePaths) {
      if (existsSync(pkgPath)) {
        const pkg = JSON.parse(readFileSync(pkgPath, 'utf-8'))
        if (pkg.version) return pkg.version
      }
    }
    return 'UNKNOWN'
  } catch {
    return 'UNKNOWN'
  }
}

export const Route = createFileRoute('/api/version')({
  server: {
    handlers: {
      GET: async () => {
        const version = await getAppVersion()
        return new Response(
          JSON.stringify({ version }),
          { status: 200, headers: { 'Content-Type': 'application/json' } }
        )
      },
    },
  },
})
```

### Test Commands

```bash
# Version check
curl http://localhost:3001/api/version
# Response: {"version":"1.0.0"}

# POST webhook test
curl -X POST http://localhost:3001/api/webhooks/stripe \
  -H "Content-Type: text/plain" \
  -H "stripe-signature: test_sig" \
  -d '{"type":"test"}'
```

---

## Global Middleware

### Configuration in start.ts

Global middleware runs automatically for every request in your application. Configure it in `src/start.ts`:

```typescript
// src/start.ts
import { createStart, createMiddleware } from '@tanstack/react-start'
import { createLogger, LogNamespace } from '@your-org/shared/logger'

const logger = createLogger(LogNamespace.REQUESTS)

/**
 * Global Request Logging Middleware
 *
 * Logs all incoming requests (SSR, routes, server functions) with timing info.
 * Provides centralized observability for the application.
 */
const requestLoggingMiddleware = createMiddleware().server(
  async ({ next, request }) => {
    const start = Date.now()
    const url = new URL(request.url)
    const path = url.pathname

    // Skip logging for static assets and internal routes
    const skipPaths = ['/_build', '/assets', '/favicon']
    const shouldSkip = skipPaths.some((skip) => path.startsWith(skip))

    if (shouldSkip) {
      return next()
    }

    try {
      const result = await next()
      const duration = Date.now() - start

      logger.info(`${request.method} ${path}`, {
        method: request.method,
        path,
        duration: `${duration}ms`,
      })

      return result
    } catch (error) {
      const duration = Date.now() - start

      logger.error(`${request.method} ${path} FAILED`, {
        method: request.method,
        path,
        duration: `${duration}ms`,
        error: error instanceof Error ? error.message : 'Unknown error',
      })

      throw error
    }
  },
)

/**
 * TanStack Start Instance
 *
 * Configures global middleware for all server requests.
 */
export const startInstance = createStart(() => {
  return {
    requestMiddleware: [requestLoggingMiddleware],
  }
})
```

### What Request Middleware Covers

Request Middleware runs for ALL server requests:
- Server routes (API endpoints, webhooks)
- SSR requests (page rendering)
- Server functions

### Multiple Middleware

```typescript
export const startInstance = createStart(() => ({
  requestMiddleware: [
    requestLoggingMiddleware,
    securityHeadersMiddleware,
    rateLimitingMiddleware,
  ],
}))
```

---

## Raw Body Handling

### Why Raw Body Matters

For webhook signature verification, you MUST read the raw body before parsing:

```typescript
// ✅ CORRECT: Read raw body for signature verification
const rawBody = await request.text()
const signature = request.headers.get('stripe-signature')

// Verify signature against raw body
const event = stripe.webhooks.constructEvent(rawBody, signature, webhookSecret)

// ❌ WRONG: Parsing first destroys signature verification
const body = await request.json()  // This breaks signature verification
```

### Pattern for Webhook Handlers

```typescript
POST: async ({ request }) => {
  // 1. Get raw body and signature
  const rawBody = await request.text()
  const signature = request.headers.get('your-signature-header')

  // 2. Validate signature exists
  if (!signature) {
    return new Response(
      JSON.stringify({ error: 'Missing signature' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    )
  }

  // 3. Verify signature and parse
  try {
    const event = verifyAndParse(rawBody, signature)  // Your verification logic
    // 4. Process the verified event
    await processEvent(event)
    return new Response(JSON.stringify({ received: true }), { status: 200 })
  } catch (error) {
    return new Response(
      JSON.stringify({ error: 'Invalid signature' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

---

## Complete Examples

### File Placement

- **Public API routes**: `apps/web/src/routes/api/**/*.ts`
- **Example**: `apps/web/src/routes/api/version.ts` → URL: `/api/version`
- **Example**: `apps/web/src/routes/api/webhooks/stripe.ts` → URL: `/api/webhooks/stripe`

### What NOT to Use for Public API Routes

```typescript
// ❌ WRONG - createServerFileRoute doesn't exist in v1.143+
import { createServerFileRoute } from '@tanstack/react-start/server'
export const ServerRoute = createServerFileRoute().methods({ ... })

// ❌ WRONG - This is for server functions called from the client
import { createServerFn } from '@tanstack/react-start'
export const processWebhook = createServerFn({ method: 'POST' })
  .handler(async ({ data }) => { /* External services can't call this */ })
```

### Complete Webhook Handler

```typescript
// apps/web/src/routes/api/webhooks/outscraper.ts
import { createFileRoute } from '@tanstack/react-router'
import { processOutscraperWebhook } from '@/lib/serverFunctions/outscraperFn'

export const Route = createFileRoute('/api/webhooks/outscraper')({
  server: {
    handlers: {
      POST: async ({ request }) => {
        try {
          const rawBody = await request.text()
          const authToken = request.headers.get('authorization')

          // Validate auth token
          if (!authToken || authToken !== `Bearer ${process.env.WEBHOOK_SECRET}`) {
            return new Response(
              JSON.stringify({ error: 'Unauthorized' }),
              { status: 401, headers: { 'Content-Type': 'application/json' } }
            )
          }

          // Parse and process
          const payload = JSON.parse(rawBody)
          const result = await processOutscraperWebhook(payload)

          return new Response(JSON.stringify(result), {
            status: 200,
            headers: { 'Content-Type': 'application/json' }
          })
        } catch (error: any) {
          console.error('Outscraper webhook error:', error)
          return new Response(
            JSON.stringify({ error: 'Processing failed', message: error.message }),
            { status: 500, headers: { 'Content-Type': 'application/json' } }
          )
        }
      },
    },
  },
})
```
