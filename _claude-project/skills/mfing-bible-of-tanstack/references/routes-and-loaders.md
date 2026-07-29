# Routes and Loaders Reference

## Contents

- [Route File Naming](#route-file-naming)
- [Path Parameters vs Search Parameters](#path-parameters-vs-search-parameters)
- [loaderDeps Pattern](#loaderdeps-pattern)
- [Route Integration Examples](#route-integration-examples)
- [Parameter Flow Architecture](#parameter-flow-architecture)

---

## Route File Naming

### Descriptive Names (Required Pattern)

Use **descriptive file names** instead of `index.tsx`:

**Benefits:**
- Instant file identification in IDE tabs
- Clear purpose from filename alone
- Better debugging with descriptive stack traces
- Easier navigation in file searches

### Implementation

```typescript
// ❌ OLD PATTERN - Avoid this:
// src/routes/admin/prospects/index.tsx
export const Route = createFileRoute('/admin/prospects/')({...})

// ✅ NEW PATTERN - Use descriptive names:
// src/routes/admin/prospects/prospects-pipeline.tsx
export const Route = createFileRoute('/admin/prospects/prospects-pipeline')({...})

// ✅ For nested routes:
// src/routes/admin/prospects/$prospectId/prospect-details.tsx
export const Route = createFileRoute('/admin/prospects/$prospectId/prospect-details')({...})
```

### Key Rules

1. **Include the filename in the route path** when not using index.tsx
2. **Use kebab-case** for consistency (e.g., `prospects-pipeline.tsx`)
3. **Be descriptive** - the filename should indicate the view's purpose
4. **Match the route path** - the filename should align with the URL structure

### Examples

| File | Route Path |
|------|------------|
| `prospects-pipeline.tsx` | `/admin/prospects/prospects-pipeline` |
| `prospect-details.tsx` | `/admin/prospects/$prospectId/prospect-details` |
| `google-places-import.tsx` | `/admin/prospects/import/google-places-import` |

---

## Path Parameters vs Search Parameters

### Critical Distinction

- **`loaderDeps`** is ONLY for **search parameters** (query strings like `?search=test`)
- **Path parameters** (like `$prospectId`) are **automatically available** in the `loader` function

### Path Parameters (Automatic)

```typescript
// URL: /admin/prospects/$prospectId/prospect-details
// e.g., /admin/prospects/abc-123/prospect-details

export const Route = createFileRoute('/admin/prospects/$prospectId/prospect-details')({
  // ❌ DO NOT USE loaderDeps for path parameters - they're automatic!
  // loaderDeps: ({ params }) => ({ prospectId: params.prospectId }), // WRONG!

  // ✅ CORRECT: Path parameters are automatically available
  loader: async ({ params }) => {
    // params.prospectId is automatically available from the $prospectId route
    const prospect = await getProspectById({
      data: { prospectId: params.prospectId }
    })

    return { prospect }
  },

  component: ProspectDetail,
})
```

### Search Parameters (Requires loaderDeps)

```typescript
// URL: /admin/prospects/prospects-pipeline?search=test&status=new

export const Route = createFileRoute('/admin/prospects/prospects-pipeline')({
  validateSearch: (search) => ({
    search: search?.search || undefined,
    status: search?.status || undefined,
    assignedTo: search?.assignedTo || undefined,
  }),

  // ✅ CRITICAL: loaderDeps exposes search parameters to loader
  loaderDeps: ({ search }) => ({
    search: search?.search || undefined,
    prospectstatus: search?.status || undefined,
    assignedtoclerkuserid: search?.assignedTo || undefined,
  }),

  // ✅ CRITICAL: loader receives deps and calls server functions
  loader: async ({ deps }) => {
    const [prospectsResult, analyticsResult] = await Promise.all([
      getProspects({
        data: {
          search: deps?.search || undefined,
          prospectstatus: deps?.prospectstatus || undefined,
          assignedtoclerkuserid: deps?.assignedtoclerkuserid || undefined,
        }
      }),
      getProspectAnalytics()
    ])

    return {
      prospects: prospectsResult,
      analytics: analyticsResult,
    }
  },

  component: ProspectPipeline,
})
```

---

## loaderDeps Pattern

### When to Use loaderDeps

Use `loaderDeps` ONLY when you need to:
1. Pass **search/query parameters** to the loader
2. Transform search parameters before passing to loader
3. Rename parameters (e.g., `status` → `prospectstatus`)

### When NOT to Use loaderDeps

- Path parameters (`$id`, `$prospectId`) - these are automatic
- Static data - just call in loader directly
- Data that doesn't come from the URL

### Pattern Structure

```typescript
export const Route = createFileRoute('/route/path')({
  // 1. Validate and provide defaults for search params
  validateSearch: (search) => ({
    param1: search?.param1 || undefined,
    param2: search?.param2 || undefined,
  }),

  // 2. Transform/map search params to loader deps
  loaderDeps: ({ search }) => ({
    param1: search?.param1 || undefined,
    param2: search?.param2 || undefined,
  }),

  // 3. Receive deps in loader
  loader: async ({ deps }) => {
    return serverFunction({ data: deps })
  },
})
```

---

## Route Integration Examples

### List View with Search and Filters

```typescript
// apps/web/src/routes/admin/prospects/prospects-pipeline.tsx
import { createFileRoute } from '@tanstack/react-router'
import { getProspects, getProspectAnalytics } from '@/lib/serverFunctions/prospectsFn'

export const Route = createFileRoute('/admin/prospects/prospects-pipeline')({
  validateSearch: (search) => {
    return {
      search: search?.search || undefined,
      status: search?.status || undefined,
      assignedTo: search?.assignedTo || undefined,
    }
  },

  loaderDeps: ({ search }) => ({
    search: search?.search || undefined,
    prospectstatus: search?.status || undefined,
    assignedtoclerkuserid: search?.assignedTo || undefined,
  }),

  loader: async ({ deps }) => {
    logger.label('ROUTE_LOADER').info('Route loader executing', { deps })

    try {
      const [prospectsResult, analyticsResult] = await Promise.all([
        getProspects({
          data: {
            search: deps?.search || undefined,
            prospectstatus: deps?.prospectstatus || undefined,
            assignedtoclerkuserid: deps?.assignedtoclerkuserid || undefined,
          }
        }),
        getProspectAnalytics()
      ])

      return {
        prospects: prospectsResult,
        analytics: analyticsResult,
      }
    } catch (error) {
      logger.label('ROUTE_LOADER').error('Route loader failed', { error })
      throw error
    }
  },

  component: ProspectPipeline,
})
```

### Detail View with Path Parameter

```typescript
// apps/web/src/routes/admin/prospects/$prospectId/prospect-details.tsx
import { createFileRoute } from '@tanstack/react-router'
import { getProspectById } from '@/lib/serverFunctions/prospectsFn'

export const Route = createFileRoute('/admin/prospects/$prospectId/prospect-details')({
  // No loaderDeps needed - path params are automatic
  loader: async ({ params }) => {
    const prospect = await getProspectById({
      data: { prospectId: params.prospectId }
    })

    return { prospect }
  },

  component: ProspectDetail,
})
```

### Combined Path and Search Parameters

```typescript
// URL: /admin/campaigns/$campaignId/contacts?status=active&page=2

export const Route = createFileRoute('/admin/campaigns/$campaignId/contacts')({
  validateSearch: (search) => ({
    status: search?.status || undefined,
    page: search?.page || 1,
  }),

  loaderDeps: ({ search }) => ({
    status: search?.status,
    page: search?.page,
  }),

  loader: async ({ params, deps }) => {
    // params.campaignId - from path (automatic)
    // deps.status, deps.page - from search (via loaderDeps)
    const contacts = await getCampaignContacts({
      data: {
        campaignId: params.campaignId,
        status: deps.status,
        page: deps.page,
      }
    })

    return { contacts }
  },
})
```

---

## Parameter Flow Architecture

### Complete Flow Diagram

```
URL: /admin/prospects?search=acme&status=identified
    ↓
1. validateSearch → { search: 'acme', status: 'identified' }
    ↓
2. loaderDeps → { search: 'acme', prospectstatus: 'identified' }
    ↓
3. loader → getProspects({ data: { search: 'acme', prospectstatus: 'identified' } })
    ↓
4. server function → handler({ data: params })
   where params = { search: 'acme', prospectstatus: 'identified' }
```

### Path Parameter Flow

```
URL: /admin/prospects/abc-123/prospect-details
    ↓
1. Route matches $prospectId → params.prospectId = 'abc-123'
    ↓
2. loader → ({ params }) where params.prospectId = 'abc-123'
    ↓
3. server function → getProspectById({ data: { prospectId: 'abc-123' } })
```

---

## Route Template

```typescript
import { createFileRoute } from '@tanstack/react-router'
import { serverFunction } from '@/lib/serverFunctions/yourFn'

export const Route = createFileRoute('/your/route/route-name')({
  // Optional: Validate search params
  validateSearch: (search) => ({
    param1: search?.param1 || undefined,
    param2: search?.param2 || undefined,
  }),

  // Optional: Map search params to loader deps (ONLY for search params)
  loaderDeps: ({ search }) => ({
    param1: search?.param1 || undefined,
    param2: search?.param2 || undefined,
  }),

  // Required: Loader function
  loader: async ({ deps, params }) => {
    // deps = from loaderDeps (search params)
    // params = from path (automatic)
    const data = await serverFunction({ data: deps })
    return { data }
  },

  // Required: Component
  component: YourComponent,
})
```

---

## Common Mistakes

### Using loaderDeps for Path Parameters

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
  loader: async ({ params }) => {
    return getUserById({ data: { userId: params.userId } }) // Direct access
  }
})
```

### Skipping loaderDeps for Search Parameters

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
