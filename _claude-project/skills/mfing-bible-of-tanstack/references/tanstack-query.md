# TanStack Query Reference

## Contents

- [Unified QueryOptions Pattern](#unified-queryoptions-pattern)
- [Cache Key Strategy](#cache-key-strategy)
- [Route Integration](#route-integration)
- [Mutations](#mutations)
- [Optimistic Updates](#optimistic-updates)
- [Cache Invalidation](#cache-invalidation)
- [Prefetching](#prefetching)
- [Performance Debugging](#performance-debugging)
- [Complete Integration Example](#complete-integration-example)

---

## Unified QueryOptions Pattern

### Single Source of Truth (Required)

Create a single file for all query options per domain:

```typescript
// apps/web/src/lib/queryOptions/prospects.ts - SINGLE SOURCE OF TRUTH
import { queryOptions } from '@tanstack/react-query'
import { getProspects, getProspectDetails, getProspectAnalytics } from '@/lib/serverFunctions/prospectsFn'

// Unified cache keys - singular "prospect" (matches DB table name)
export const prospectQueryOptions = {
  // Lists: ["prospect", filters] - All prospect list data
  list: (filters = {}) => queryOptions({
    queryKey: ['prospect', filters] as const,
    queryFn: () => getProspects({ data: filters }),
    staleTime: 1000 * 60 * 5, // 5 minutes
  }),

  // Details: ["prospect", "detail", id] - Individual prospect details
  detail: (prospectId: string) => queryOptions({
    queryKey: ['prospect', 'detail', prospectId] as const,
    queryFn: () => getProspectDetails({ data: { prospectid: prospectId } }),
    staleTime: 1000 * 60 * 5, // 5 minutes
  }),

  // Analytics: ["prospect-analytics"] - Aggregated data (plural OK - not DB entity)
  analytics: () => queryOptions({
    queryKey: ['prospect-analytics'] as const,
    queryFn: () => getProspectAnalytics({ data: {} }),
    staleTime: 1000 * 60 * 10, // 10 minutes
  }),
}
```

### Using QueryOptions in Hooks

```typescript
// apps/web/src/hooks/useProspects.ts - REUSE SHARED OPTIONS
import { useQuery } from '@tanstack/react-query'
import { prospectQueryOptions, ProspectListParams } from '@/lib/queryOptions/prospects'

export function useProspects(params: ProspectListParams = {}) {
  return useQuery(prospectQueryOptions.list(params))
  // TanStack Query automatically:
  // - Shows cached data instantly (SWR)
  // - Refetches on window focus
  // - Refetches on reconnect
  // - Background revalidation when stale
  // - SHARES CACHE with route loaders using same queryOptions
}
```

---

## Cache Key Strategy

### Correct Keys (Singular, Matching DB Names)

```typescript
// ✅ CORRECT - Singular cache keys (matches DB table names)
['prospect', filters]           // Lists
['prospect', 'detail', id]      // Details
['prospect-analytics']          // Analytics (plural OK - aggregated data)

// ❌ WRONG - Inconsistent plural/singular
['prospects', filters]          // Breaks cache sharing
['prospect', id]               // Conflicts with list keys
['prospects', 'detail', id]    // Mixed singular/plural
```

### Key Structure Pattern

| Query Type | Key Pattern | Example |
|------------|-------------|---------|
| List (with filters) | `[entity, filters]` | `['prospect', { status: 'active' }]` |
| Detail | `[entity, 'detail', id]` | `['prospect', 'detail', 'abc-123']` |
| Analytics/Aggregates | `[entity-analytics]` | `['prospect-analytics']` |
| Related data | `[entity, 'related', parentId]` | `['prospect', 'campaigns', 'abc-123']` |

---

## Route Integration

### Using Unified QueryOptions in Routes

```typescript
// apps/web/src/routes/admin/prospects/index.tsx - REUSE SAME OPTIONS
import { createFileRoute } from '@tanstack/react-router'
import { useSuspenseQuery } from '@tanstack/react-query'
import { prospectQueryOptions } from '@/lib/queryOptions/prospects'

export const Route = createFileRoute('/admin/prospects/')({
  loaderDeps: ({ search }) => ({
    search: search?.search || undefined,
    prospectstatus: search?.status || undefined,
    managerclerkuserid: search?.assignedTo || undefined,
  }),

  // Route loader uses SAME queryOptions as hooks
  loader: async ({ deps, context: { queryClient } }) => {
    await Promise.all([
      queryClient.ensureQueryData(prospectQueryOptions.list(deps)),
      queryClient.ensureQueryData(prospectQueryOptions.analytics()),
    ])
    return {}
  },

  component: () => {
    const deps = /* derived from search params */
    // Component uses SAME queryOptions - NO duplicate requests!
    const { data: prospects } = useSuspenseQuery(prospectQueryOptions.list(deps))
    const { data: analytics } = useSuspenseQuery(prospectQueryOptions.analytics())
    // Data is instantly available from cache populated by loader
  }
})
```

### Cache Sharing Between Routes and Components

```typescript
// Multiple components using same query = ONE network request
// Component A in Dashboard - using shared queryOptions
const { data } = useQuery(prospectQueryOptions.list({ prospectstatus: ['new-lead'] }))

// Component B in Sidebar - using same queryOptions
const { data } = useQuery(prospectQueryOptions.list({ prospectstatus: ['new-lead'] }))

// Route loader - using same queryOptions
queryClient.ensureQueryData(prospectQueryOptions.list({ prospectstatus: ['new-lead'] }))

// Result: Only ONE request made, data shared via cache across:
// - Route loaders (SSR)
// - Client hooks (SWR)
// - Component queries
// TanStack Query automatically deduplicates identical queryOptions
```

---

## Mutations

### Basic Mutation Pattern

```typescript
// CREATE mutations
export function useCreateProspect() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: createProspect,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['prospect'] })
      queryClient.invalidateQueries({ queryKey: ['prospect-analytics'] })
    },
  })
}

// UPDATE mutations
export function useUpdateProspectStatus() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ prospectid, status }) =>
      updateProspectStatus({ data: { prospectid, prospectstatus: status } }),

    onSuccess: (_, variables) => {
      // Invalidate using unified cache keys
      queryClient.invalidateQueries({ queryKey: ['prospect'] }) // All lists
      queryClient.invalidateQueries({
        queryKey: ['prospect', 'detail', variables.prospectid]
      }) // Specific detail
      queryClient.invalidateQueries({ queryKey: ['prospect-analytics'] })
    },
  })
}

// DELETE mutations
export function useDeleteProspect() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: deleteProspect,
    onSuccess: (_, variables) => {
      // Remove specific prospect from cache
      queryClient.removeQueries({
        queryKey: ['prospect', 'detail', variables.data.prospectid]
      })
      // Invalidate lists and analytics
      queryClient.invalidateQueries({ queryKey: ['prospect'] })
      queryClient.invalidateQueries({ queryKey: ['prospect-analytics'] })
    },
  })
}
```

---

## Optimistic Updates

### When to Use

**Use Optimistic Updates For:**
- Drag-and-drop operations (status changes, reordering)
- Toggle states (status updates, feature flags)
- Mutations where UI change is immediate and predictable
- High-frequency user interactions requiring instant feedback

**Use Simple Invalidation For:**
- Create operations (new records)
- Delete operations (complex side effects)
- Complex mutations with unpredictable server responses
- Operations that modify multiple unrelated data structures

### Complete Optimistic Update Pattern

```typescript
// ✅ OPTIMISTIC UPDATE PATTERN - Multiple cache queries
export function useUpdateProspectStatusOptimistic() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ prospectid, prospectstatus }) =>
      updateProspectStatus({ data: { prospectid, prospectstatus } }),

    onMutate: async ({ prospectid, prospectstatus }) => {
      // Cancel outgoing refetches for all prospect queries
      await queryClient.cancelQueries({ queryKey: ["prospect"] })

      // Get all matching prospect queries in the cache
      const queries = queryClient.getQueriesData({ queryKey: ["prospect"] })
      const previousData = new Map(queries)

      // Update all matching prospect list queries
      queries.forEach(([queryKey, data]) => {
        // Skip non-list queries (detail, analytics)
        if (queryKey.includes('detail') || queryKey.includes('analytics')) {
          return;
        }

        if (!Array.isArray(data)) return;

        const targetProspect = data.find(p => p.prospectid === prospectid)
        if (!targetProspect) return;

        const updated = data.map((prospect) =>
          prospect.prospectid === prospectid
            ? {
                ...prospect,
                prospectstatus,
                updatedat: new Date().toISOString(),
              }
            : prospect,
        )

        queryClient.setQueryData(queryKey, updated)
      })

      return { previousData }
    },

    onError: (error, variables, context) => {
      // Rollback all optimistic updates
      if (context?.previousData) {
        context.previousData.forEach(([queryKey, data]) => {
          queryClient.setQueryData(queryKey, data)
        })
      }
      toast.error("Failed to update prospect status")
    },

    onSuccess: (data, variables) => {
      // Update all prospect list caches with server response
      const queries = queryClient.getQueriesData({ queryKey: ["prospect"] })
      queries.forEach(([queryKey, cachedData]) => {
        // Skip non-list queries
        if (queryKey.includes('detail') || queryKey.includes('analytics')) {
          return
        }

        if (Array.isArray(cachedData)) {
          const updated = cachedData.map((prospect) =>
            prospect.prospectid === variables.prospectid
              ? {
                  ...prospect,
                  ...data, // Spread server response
                  prospectstatus: variables.prospectstatus,
                }
              : prospect,
          )
          queryClient.setQueryData(queryKey, updated)
        }
      })

      toast.success(`Status updated successfully`)
    },
  })
}
```

### Cache Key Challenge

```typescript
// ✅ CRITICAL: Cache Key Strategy for Optimistic Updates
// The pattern handles the key challenge:

// Route uses: ['prospect', { search: 'acme', prospectstatus: ['identified'] }]
// But we can't know the exact filters from a mutation component
// Solution: Find ALL prospect queries and update each one

// ❌ WRONG - Assumes specific cache key
queryClient.setQueryData(['prospects'], updatedData) // Hard-coded key

// ✅ CORRECT - Updates all matching queries
const queries = queryClient.getQueriesData({ queryKey: ["prospect"] })
queries.forEach(([queryKey, data]) => {
  // Update each prospect list query regardless of filters
  if (!queryKey.includes('detail')) {
    queryClient.setQueryData(queryKey, updateFunction(data))
  }
})
```

---

## Cache Invalidation

### Pattern with Unified Keys

```typescript
// Invalidate all lists
queryClient.invalidateQueries({ queryKey: ['prospect'] })

// Invalidate specific detail
queryClient.invalidateQueries({ queryKey: ['prospect', 'detail', prospectId] })

// Invalidate analytics
queryClient.invalidateQueries({ queryKey: ['prospect-analytics'] })

// Remove specific query entirely
queryClient.removeQueries({ queryKey: ['prospect', 'detail', prospectId] })
```

---

## Prefetching

### Hover-based Prefetching

```typescript
import { useQueryClient } from '@tanstack/react-query'
import { prospectQueryOptions } from '@/lib/queryOptions/prospects'

function ProspectCard({ prospect }) {
  const queryClient = useQueryClient()

  const handleMouseEnter = () => {
    // Prefetch detail data on hover
    queryClient.prefetchQuery(prospectQueryOptions.detail(prospect.prospectid))
  }

  return (
    <div onMouseEnter={handleMouseEnter} className="cursor-pointer">
      {/* Card content */}
    </div>
  )
}
```

### Click-time Prefetching

```typescript
const handleNavigateToDetail = async (e: React.MouseEvent) => {
  e.preventDefault()

  const cacheKey = ['prospect', 'detail', prospect.prospectid]
  const cachedData = queryClient.getQueryData(cacheKey)

  if (!cachedData) {
    // Cache miss - prefetch before navigation
    await queryClient.prefetchQuery(prospectQueryOptions.detail(prospect.prospectid))
  }

  // Navigate with instant data availability
  router.navigate({ to: `/admin/prospects/${prospect.prospectid}` })
}
```

### Route-level Prefetching

```typescript
export const Route = createFileRoute('/admin/prospects/$prospectId/')({
  loader: async ({ params, context: { queryClient } }) => {
    // Prefetch all related data in parallel
    await Promise.all([
      queryClient.ensureQueryData(prospectQueryOptions.detail(params.prospectId)),
      queryClient.ensureQueryData(campaignQueryOptions.forProspect(params.prospectId)),
      queryClient.ensureQueryData(activityQueryOptions.forProspect(params.prospectId))
    ])

    return {}
  },
  component: ProspectDetail,
})
```

### Debounced Hover Prefetching

```typescript
import { useCallback } from 'react'
import { debounce } from 'lodash'

const debouncedPrefetch = useCallback(
  debounce((prospectId: string) => {
    queryClient.prefetchQuery(prospectQueryOptions.detail(prospectId))
  }, 200),
  [queryClient]
)

const handleMouseEnter = () => debouncedPrefetch(prospect.prospectid)
```

### Prefetching Best Practices

**DO:**
- Use hover prefetching for list → detail patterns
- Prefetch critical path data in route loaders
- Limit bulk prefetching to visible items only
- Use unified queryOptions for all prefetch calls
- Check cache before prefetching to avoid duplicate requests
- Use `prefetchQuery` (not `fetchQuery`) to respect stale data

**DON'T:**
- Prefetch all list items on page load
- Prefetch without user intent signals
- Use `fetchQuery` for prefetching (ignores cache)
- Prefetch heavy data without user interaction

### The Prefetching Challenge

Different data structures naturally require different cache keys:

```typescript
// Different cache keys serve different purposes (this is CORRECT architecture)
['prospect', filters]           // List data: Prospect[]
['prospect', 'detail', id]      // Detail data: { prospect, campaigns, activities }
['prospect-analytics']          // Analytics: { totalCount, conversionRate }
```

**Result**: No automatic cache sharing between list → detail navigation, causing loading spinners on first visit.

**Solution**: Smart prefetching strategies that maintain architectural correctness while delivering instant UX.

### Bulk Prefetching for Visible Items

For high-performance list views using intersection observer:

```typescript
import { useEffect } from 'react'
import { useInView } from 'react-intersection-observer'
import { useQueryClient } from '@tanstack/react-query'
import { prospectQueryOptions } from '@/lib/queryOptions/prospects'

function ProspectList({ prospects }) {
  const queryClient = useQueryClient()
  const { ref, inView } = useInView({ threshold: 0.1 })

  useEffect(() => {
    if (inView && prospects.length > 0) {
      // Prefetch details for all visible prospects
      const visibleProspects = prospects.slice(0, 10) // Limit to prevent overload

      visibleProspects.forEach(prospect => {
        queryClient.prefetchQuery(prospectQueryOptions.detail(prospect.prospectid))
      })
    }
  }, [inView, prospects, queryClient])

  return (
    <div ref={ref}>
      {prospects.map(prospect => (
        <ProspectCard key={prospect.prospectid} prospect={prospect} />
      ))}
    </div>
  )
}
```

---

## Performance Debugging

### Debug Prefetching Behavior

```typescript
const handleMouseEnter = () => {
  const cacheKey = ['prospect', 'detail', prospect.prospectid]
  const cachedData = queryClient.getQueryData(cacheKey)

  if (cachedData) {
    console.log(`⚡ Already cached: ${prospect.businessname}`)
  } else {
    console.log(`🔄 Prefetching: ${prospect.businessname}`)
    queryClient.prefetchQuery(prospectQueryOptions.detail(prospect.prospectid))
  }
}
```

### Monitor Cache Performance in Route Loaders

```typescript
loader: async ({ params, context: { queryClient } }) => {
  const cacheKey = ['prospect', 'detail', params.prospectId]
  const cachedData = queryClient.getQueryData(cacheKey)

  if (cachedData) {
    console.log(`📦 Route Loader Cache status: HIT - instant load!`)
  } else {
    console.log(`📦 Route Loader Cache status: MISS - fetching data`)
  }

  const prospectData = await queryClient.ensureQueryData(
    prospectQueryOptions.detail(params.prospectId)
  )

  return prospectData
}
```

---

## Complete Integration Example

All patterns together in one component:

```typescript
import { useQueryClient } from '@tanstack/react-query'
import { useRouter } from '@tanstack/react-router'
import { prospectQueryOptions } from '@/lib/queryOptions/prospects'
import { Card } from '@/components/ui/card'

function ProspectCard({ prospect }) {
  const queryClient = useQueryClient()
  const router = useRouter()

  // Hover prefetching
  const handleMouseEnter = () => {
    queryClient.prefetchQuery(prospectQueryOptions.detail(prospect.prospectid))
  }

  // Smart navigation with cache check
  const handleClick = async () => {
    const cached = queryClient.getQueryData(['prospect', 'detail', prospect.prospectid])
    if (!cached) {
      await queryClient.prefetchQuery(prospectQueryOptions.detail(prospect.prospectid))
    }
    router.navigate({ to: `/admin/prospects/${prospect.prospectid}` })
  }

  return (
    <Card onMouseEnter={handleMouseEnter} onClick={handleClick}>
      {/* Card content */}
    </Card>
  )
}

// Route uses same unified queryOptions
export const Route = createFileRoute('/admin/prospects/$prospectId/')({
  loader: async ({ params, context: { queryClient } }) => {
    await queryClient.ensureQueryData(prospectQueryOptions.detail(params.prospectId))
    return {}
  },
  component: ProspectDetail,
})
```

---

### Expected Results

With proper prefetching:
- **First hover**: 0ms perceived delay for subsequent clicks
- **Repeat visits**: 0ms load time (cache hits)
- **Navigation feels**: Native app-like instant transitions
- **Network efficiency**: Only fetches when needed
- **Cache consistency**: Unified queryOptions maintain single source of truth

**Remember**: Different cache keys are architecturally correct. Prefetching bridges the UX gap without compromising the data architecture.
