# Loading States Reference

## Contents

- [The Loading Spinner Problem](#the-loading-spinner-problem)
- [Root Causes](#root-causes)
- [The Complete SWR Solution](#the-complete-swr-solution)
- [Testing Your Fix](#testing-your-fix)

---

## The Loading Spinner Problem

**Symptom**: Loading spinner appears when changing search parameters (filters, pagination, etc.) even though you want SWR behavior.

**Expected Behavior**: Show cached data instantly, fetch fresh data in background, smooth transition when new data arrives.

**Actual Behavior**: Full-page loading spinner appears, blocking UI.

---

## Root Causes

Check ALL of these:

### 1. Global `defaultPendingComponent` in router.tsx

```typescript
// ❌ WRONG: Shows loader for ALL navigations including search params
const router = createTanStackRouter({
  defaultPendingComponent: () => <Loader />,
})

// ✅ CORRECT: Let routes control their own loading
const router = createTanStackRouter({
  // No defaultPendingComponent
})
```

### 2. Global Loading Check in `__root.tsx`

```typescript
// ❌ WRONG: Shows loader for any router state change
function RootDocument() {
  const isFetching = useRouterState({ select: (s) => s.isLoading })
  return (
    <main>
      {isFetching ? <Loader /> : <Outlet />}
    </main>
  )
}

// ✅ CORRECT: Just render the outlet
function RootDocument() {
  return (
    <main>
      <Outlet />
    </main>
  )
}
```

### 3. Route Configuration for SWR

```typescript
// ✅ CORRECT: The three essential settings for SWR on search param changes
export const Route = createFileRoute("/admin/prospects/")({
  // 1. Prevent loader re-execution on search param changes
  shouldReload: false,

  // 2. Disable route-level pending UI
  pendingComponent: () => null,
  pendingMs: Infinity,

  // Your loader and component...
})
```

### 4. Query Configuration

```typescript
// In your component's useQuery:
const { data } = useQuery({
  ...queryOptions,
  // 3. Keep previous data visible while fetching new data
  placeholderData: keepPreviousData,
})
```

### 5. Navigation Configuration

```typescript
// In navigation handlers:
router.navigate({
  search: newSearchParams,
  // 4. Replace history entry instead of pushing
  replace: true,
})
```

---

## The Complete SWR Solution

### Why This Happens

TanStack Router's navigation lifecycle ALWAYS runs for any navigation (including search param changes). Without proper configuration:
1. Router sets `pendingLocation` state
2. Global pending components check this state
3. Loading UI appears even though data is cached

### Step-by-Step Fix

**Step 1: Remove all global loading handlers**

```typescript
// router.tsx - Remove defaultPendingComponent
const router = createTanStackRouter({
  routeTree,
  context: { queryClient },
  // No defaultPendingComponent
})

// __root.tsx - Remove isLoading check
function RootDocument() {
  return (
    <main>
      <Outlet />
    </main>
  )
}
```

**Step 2: Configure route with `shouldReload: false`**

```typescript
export const Route = createFileRoute("/admin/prospects/")({
  shouldReload: false,
  pendingComponent: () => null,
  pendingMs: Infinity,
  // ...
})
```

**Step 3: Use `placeholderData: keepPreviousData` in queries**

```typescript
import { keepPreviousData } from '@tanstack/react-query'

const { data } = useQuery({
  ...prospectQueryOptions.list(filters),
  placeholderData: keepPreviousData,
})
```

**Step 4: Navigate with `replace: true`**

```typescript
const handleFilterChange = (newFilters) => {
  router.navigate({
    search: newFilters,
    replace: true,
  })
}
```

**Step 5: Set route's `pendingComponent: () => null`**

```typescript
export const Route = createFileRoute("/admin/prospects/")({
  pendingComponent: () => null,
  // ...
})
```

---

## Testing Your Fix

1. Open Network tab in DevTools
2. Change a filter/search param
3. You should see:
   - NO loading spinner
   - Previous data stays visible
   - New data loads in background
   - Smooth transition when new data arrives
4. Network request should still be made (background revalidation)

---

## Complete Route Example

```typescript
import { createFileRoute } from '@tanstack/react-router'
import { useSuspenseQuery } from '@tanstack/react-query'
import { keepPreviousData } from '@tanstack/react-query'
import { prospectQueryOptions } from '@/lib/queryOptions/prospects'

export const Route = createFileRoute('/admin/prospects/')({
  validateSearch: (search) => ({
    search: search?.search || undefined,
    status: search?.status || undefined,
  }),

  loaderDeps: ({ search }) => ({
    search: search?.search,
    prospectstatus: search?.status,
  }),

  // Prevent loader re-execution on search changes
  shouldReload: false,

  // Disable route-level pending UI
  pendingComponent: () => null,
  pendingMs: Infinity,

  loader: async ({ deps, context: { queryClient } }) => {
    await queryClient.ensureQueryData(prospectQueryOptions.list(deps))
    return {}
  },

  component: ProspectList,
})

function ProspectList() {
  const search = Route.useSearch()
  const router = useRouter()

  const { data: prospects } = useSuspenseQuery({
    ...prospectQueryOptions.list({
      search: search.search,
      prospectstatus: search.status,
    }),
    // Keep previous data while fetching
    placeholderData: keepPreviousData,
  })

  const handleFilterChange = (newFilters) => {
    router.navigate({
      search: newFilters,
      replace: true,  // Replace instead of push
    })
  }

  return (
    // Your component JSX
  )
}
```
