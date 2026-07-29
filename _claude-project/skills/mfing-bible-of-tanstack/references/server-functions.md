# Server Functions Reference

## Contents

- [Key Distinction: Server Functions vs API Routes vs Production Server](#key-distinction-server-functions-vs-api-routes-vs-production-server)
- [Shared Database Connection](#shared-database-connection)
- [Server Function Pattern](#server-function-pattern)
- [Input Validation](#input-validation)
- [Server Function Composition](#server-function-composition)
- [Cross-Domain vs Same-Domain](#cross-domain-vs-same-domain)
- [Complete Example](#complete-example)

---

## Key Distinction: Server Functions vs API Routes vs Production Server

TanStack Start has three distinct server-side concepts that are often confused:

### 1. Server Functions (RPC Endpoints)

**What**: Type-safe functions that run on the server, callable from client code.

**Created with**: `createServerFn()`

**Purpose**: Internal app logic - database queries, auth checks, business logic.

**Bundled**: YES - Included in the TanStack Start build output.

```typescript
// Type-safe RPC - client calls like a function
const data = await getProspects({ data: { search: 'test' } })
```

### 2. API Routes (Public HTTP Endpoints)

**What**: Public HTTP endpoints for external systems (webhooks, third-party integrations).

**Created with**: `createFileRoute()` with `server.handlers` in `routes/api/`

**Purpose**: External access - Stripe webhooks, GitHub callbacks, public APIs.

**Bundled**: YES - Included in the TanStack Start build output.

```typescript
// Public endpoint: POST /api/webhooks/stripe
export const Route = createFileRoute('/api/webhooks/stripe')({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const body = await request.text() // Raw for signature
        // Handle webhook...
      }
    }
  }
})
```

### 3. Production Server Runtime

**What**: HTTP server that wraps TanStack Start's fetch handler AND serves static files.

**Created with**: Hono (recommended), Express, or other Node.js server.

**Purpose**: Run the application in production.

**NOT bundled**: This is YOUR code, separate from TanStack Start build.

```javascript
// server.mjs - Wraps TanStack Start handler
import handler from './dist/server/server.js'
app.all('*', (c) => handler.fetch(c.req.raw))
```

### Summary Table

| Concept | Built with | Bundled? | Purpose |
|---------|------------|----------|---------|
| Server Functions | `createServerFn()` | Yes | Internal RPC |
| API Routes | `createFileRoute()` + `server.handlers` | Yes | External webhooks |
| Production Server | Hono/Express | No | Run the app |

See `references/api-routes-webhooks.md` for API route patterns.
See `references/production-deployment.md` for production server setup.

---

## Shared Database Connection

Create a single shared database connection for all server functions:

```typescript
// apps/web/src/lib/db.ts
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'

// Import all schemas
import * as authSchema from '@/db/schema/auth'
import * as prospectSchema from '@/db/schema/prospect'
import * as campaignSchema from '@/db/schema/campaign'
import * as importManagementSchema from '@/db/schema/importManagement'
import * as websiteProjectSchema from '@/db/schema/websiteProject'
import * as sessionSchema from '@/db/schema/session'

if (!process.env.DATABASE_URL) {
  throw new Error('DATABASE_URL environment variable is required')
}

// Create connection outside of functions for reuse
const sql = neon(process.env.DATABASE_URL)

// Combine all schemas
const schema = {
  ...authSchema,
  ...prospectSchema,
  ...campaignSchema,
  ...importManagementSchema,
  ...websiteProjectSchema,
  ...sessionSchema,
}

// Export the shared database connection
export const db = drizzle(sql, { schema })

// Re-export everything for convenience
export * from '@/db/schema/auth'
export * from '@/db/schema/prospect'
export * from '@/db/schema/campaign'
export * from '@/db/schema/importManagement'
export * from '@/db/schema/websiteProject'
export * from '@/db/schema/session'
```

**Critical**: Never create new database connections inside server function handlers.

---

## Server Function Pattern

### Basic Structure

```typescript
// apps/web/src/lib/serverFunctions/prospectsFn.ts
import { createServerFn } from '@tanstack/react-start'
import { getServerAuth } from '@/lib/auth/serverAuth'
import { eq, and, or, ilike, inArray, desc } from 'drizzle-orm'
import { db, prospect } from '@your-org/shared/db'
import { createLogger, LogNamespace } from '@your-org/shared/logger'

const logger = createLogger(LogNamespace.PROSPECTS)

export const getProspects = createServerFn({
  method: 'GET',
})
  .inputValidator((params: {
    search?: string
    prospectstatus?: string[]
    assignedtoclerkuserid?: string
    limit?: number
    offset?: number
  }) => params)
  .handler(async ({ data: params }) => {
    // 1. Authentication (if required)
    const authContext = await getServerAuth(['admin', 'manager'])

    // 2. CRITICAL: Always handle undefined params
    const safeParams = params || {}

    // 3. Logging
    logger.info('Fetching prospects', {
      userId: authContext.userId,
      role: authContext.role,
      params: safeParams
    })

    // 4. Build query with conditions
    let query = db.select().from(prospect)
    const conditions = []

    if (safeParams.prospectstatus?.length) {
      conditions.push(inArray(prospect.prospectstatus, safeParams.prospectstatus))
    }

    if (safeParams.assignedtoclerkuserid) {
      conditions.push(eq(prospect.assignedtoclerkuserid, safeParams.assignedtoclerkuserid))
    }

    if (safeParams.search) {
      conditions.push(
        or(
          ilike(prospect.businessname, `%${safeParams.search}%`),
          ilike(prospect.ownername, `%${safeParams.search}%`),
          ilike(prospect.phonenumber, `%${safeParams.search}%`),
          ilike(prospect.emailbusiness, `%${safeParams.search}%`)
        )
      )
    }

    if (conditions.length > 0) {
      query = query.where(and(...conditions))
    }

    // 5. Execute with error handling
    try {
      const results = await query
        .limit(safeParams.limit || 50)
        .offset(safeParams.offset || 0)
        .orderBy(desc(prospect.updatedat))

      logger.info('Query completed successfully', {
        resultCount: results.length
      })

      return results
    } catch (error) {
      logger.error('Database query failed', { error })
      throw error
    }
  })
```

---

## Input Validation

### Using inputValidator

```typescript
export const createProspect = createServerFn({
  method: 'POST',
})
  .inputValidator((input: {
    businessname: string
    email: string
    phone?: string
    prospectstatus?: string
    managerclerkuserid?: string
  }) => input)
  .handler(async ({ data: input }) => {
    // input is now typed and validated
    const [newProspect] = await db.insert(prospect)
      .values({
        ...input,
        managerclerkuserid: input.managerclerkuserid || authContext.userId,
      })
      .returning()

    return newProspect
  })
```

### Safe Parameter Handling

```typescript
// ✅ CORRECT: Always handle undefined
.handler(async ({ data: params }) => {
  const safeParams = params || {}
  if (safeParams.search) { /* Safe */ }
})

// ❌ WRONG: Can crash if params is undefined
.handler(async ({ data: params }) => {
  if (params.search) { /* Will throw if params is undefined */ }
})
```

---

## Server Function Composition

### When to Use Server Functions vs Direct Database Queries

**Core Principle**: Use server functions for cross-domain operations, direct queries for same-domain internal operations.

### Cross-Domain Queries (Use Server Functions)

```typescript
// ✅ CORRECT: Cross-domain via server function
export const createSubscription = createServerFn({
  method: "POST",
})
  .handler(async ({ data: input }) => {
    // Use server function for contact data (cross-domain)
    const contact = await getContactFullProfile({
      data: { contactid: input.contactid }
    })

    // Use server function for product data (cross-domain)
    const product = await getProductDetails({
      data: { productid: input.productid }
    })

    // Direct query for subscription creation (same-domain)
    const [newSubscription] = await db.insert(subscription).values({
      contactid: input.contactid,
      productid: input.productid,
      // ... other fields
    }).returning()

    return newSubscription
  })
```

### Same-Domain Queries (Use Direct Database)

```typescript
// ✅ CORRECT: Same-domain direct query
export const updateSubscription = createServerFn({
  method: "PUT",
})
  .handler(async ({ data: input }) => {
    // Direct query within same domain - no circular dependency
    const existingSubscription = await db.query.subscription.findFirst({
      where: eq(subscription.subscriptionid, input.subscriptionid)
    })

    if (!existingSubscription) {
      throw new Error("Subscription not found")
    }

    // ... update logic
  })
```

### What NOT to Do

```typescript
// ❌ WRONG: Cross-domain direct queries
export const createInvoice = createServerFn({
  method: "POST",
})
  .handler(async ({ data: input }) => {
    // DON'T: Direct contact query from invoice domain
    const contact = await db.query.contact.findFirst({
      where: eq(contact.contactid, input.contactid)
    })

    // DON'T: Direct product query from invoice domain
    const product = await db.query.product.findFirst({
      where: eq(product.productid, input.productid)
    })
  })
```

---

## Cross-Domain vs Same-Domain

### Use Server Functions For

- **Cross-domain queries**: subscription → contact, invoice → product, contact → product
- **External API integrations**: All Stripe operations, external service calls
- **Complex business logic**: Multi-step operations with validation and error handling
- **Reusable operations**: Logic that multiple modules need to access

### Use Direct Database Queries For

- **Same-domain internal operations**: contact → contact, subscription → subscription
- **Performance-critical simple lookups**: Single table primary key lookups within same module
- **Avoiding circular dependencies**: When server function composition would create import cycles
- **Module-internal validation**: Checking existence before updates/deletes within same domain

### Circular Dependency Prevention

```typescript
// ✅ CORRECT: Avoid circular dependencies
// subscriptionFn.ts
import { getContactFullProfile } from "./contactFn"  // OK: subscription → contact

// contactFn.ts
// DON'T import from subscriptionFn to avoid: contact → subscription → contact

// Instead, use direct queries within contactFn for subscription data:
const subscription = await db.query.subscription.findFirst({
  where: eq(subscription.contactid, contactId)
})
```

### Architecture Benefits

- **Separation of Concerns**: Each domain owns its data access patterns
- **Consistent APIs**: Cross-domain access through established interfaces
- **Maintainability**: Changes to contact/product logic automatically benefit dependent modules
- **Testing**: Server function mocks work consistently across modules
- **Error Handling**: Leverages existing validation and error handling
- **Performance**: Avoids unnecessary overhead for same-domain operations

---

## Complete Example

```typescript
// apps/web/src/lib/serverFunctions/prospectsFn.ts
import { createServerFn } from '@tanstack/react-start'
import { getServerAuth } from '@/lib/auth/serverAuth'
import { eq, and, or, ilike, inArray, desc } from 'drizzle-orm'
import { db, prospect } from '@your-org/shared/db'
import { createLogger, LogNamespace } from '@your-org/shared/logger'

const logger = createLogger(LogNamespace.PROSPECTS)

// GET: List with filtering
export const getProspects = createServerFn({
  method: 'GET',
})
  .inputValidator((params: {
    search?: string
    prospectstatus?: string[]
    assignedtoclerkuserid?: string
    limit?: number
    offset?: number
  }) => params)
  .handler(async ({ data: params }) => {
    const authContext = await getServerAuth(['admin', 'manager'])
    const safeParams = params || {}

    logger.info('Fetching prospects', {
      userId: authContext.userId,
      params: safeParams
    })

    let query = db.select().from(prospect)
    const conditions = []

    if (safeParams.prospectstatus?.length) {
      conditions.push(inArray(prospect.prospectstatus, safeParams.prospectstatus))
    }

    if (safeParams.search) {
      conditions.push(
        or(
          ilike(prospect.businessname, `%${safeParams.search}%`),
          ilike(prospect.ownername, `%${safeParams.search}%`)
        )
      )
    }

    if (conditions.length > 0) {
      query = query.where(and(...conditions))
    }

    const results = await query
      .limit(safeParams.limit || 50)
      .offset(safeParams.offset || 0)
      .orderBy(desc(prospect.updatedat))

    return results
  })

// POST: Create
export const createProspect = createServerFn({
  method: 'POST',
})
  .inputValidator((input: {
    businessname: string
    email: string
    phone?: string
  }) => input)
  .handler(async ({ data: input }) => {
    const authContext = await getServerAuth(['admin', 'manager'])

    const [newProspect] = await db.insert(prospect)
      .values({
        ...input,
        managerclerkuserid: authContext.userId,
      })
      .returning()

    return newProspect
  })

// POST: Delete (use POST for mutations)
export const deleteProspect = createServerFn({
  method: 'POST',
})
  .inputValidator((input: { prospectid: string }) => input)
  .handler(async ({ data: input }) => {
    const authContext = await getServerAuth(['admin'])

    await db.delete(prospect)
      .where(eq(prospect.prospectid, input.prospectid))

    return { success: true }
  })
```

---

## File Naming Convention

Server function files use the `Fn` suffix:

```
apps/web/src/lib/serverFunctions/
├── prospectsFn.ts
├── authFn.ts
├── campaignFn.ts
├── contactFn.ts
├── invoiceFn.ts
├── subscriptionFn.ts
└── stripeFn.ts
```
