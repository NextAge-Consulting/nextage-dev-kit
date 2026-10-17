# Security headers

Read when a project asks for a Content-Security-Policy or security headers, or when an app that has them adds a third-party service.

Security headers are opt-in. An app adopts them by copying `security-headers.ts`, beside this file, into its server code and wiring it in the three places below. In production it sends:

- a Content-Security-Policy with a fresh nonce per response, on HTML pages only, never replacing a policy a route set itself;
- `X-Content-Type-Options: nosniff` and `Referrer-Policy: strict-origin-when-cross-origin`;
- `Strict-Transport-Security` when the browser came over HTTPS, read from the load balancer's `X-Forwarded-Proto`, without `includeSubDomains`.

## Before wiring it in

**List every other origin the app uses, in the module's `CspAllow` under its directive:** scripts and the scripts they load (`script`), images (`img`), browser-side fetch, XHR and uploads (`connect`), embedded iframes (`frame`), video and audio (`media`), workers (`worker`), and form posts, including a login form whose server answer redirects to an identity provider (`form`). Put `blob:` previews under `img` and `media`. Name each origin, never a wildcard.

**Move every inline `<script>` written in JSX into the route's `head().scripts`, or `ScriptOnce`.** Only those receive the nonce.

**Make every inline head script safe to run twice**, with a window flag where running twice would repeat an effect, such as an analytics page view. TanStack Router runs each inline `head().scripts` entry again after hydration under a header-delivered policy (TanStack/router#8550).

## Wire it in

**1. The request middleware, first in `src/start.ts`:**

```ts
import { createMiddleware, createStart } from '@tanstack/react-start'
import { type CspAllow, newNonce, withSecurityHeaders } from './lib/security-headers'

const allow: CspAllow = { connect: ['https://api.example.com'] }

const securityHeaders = createMiddleware().server(async ({ next, request }) => {
  const nonce = newNonce()
  const result = await next({ context: { nonce } })
  if (process.env.NODE_ENV !== 'production') return result
  return { ...result, response: withSecurityHeaders(request, result.response, { nonce, allow }) }
})

export const startInstance = createStart(() => ({
  requestMiddleware: [securityHeaders, /* the CSRF middleware and the rest */],
}))
```

**2. The nonce into the router**, where the router is created:

```ts
import { createIsomorphicFn, getGlobalStartContext } from '@tanstack/react-start'

const cspNonce = createIsomorphicFn()
  .server(() => {
    try {
      return (getGlobalStartContext() as { nonce?: string } | undefined)?.nonce
    } catch {
      return undefined // a request that ran no global middleware
    }
  })
  .client(() => undefined)

const router = createRouter({ routeTree, ssr: { nonce: cspNonce() } })
```

The middleware throws nothing. An error a request middleware throws during a server-function call reaches the browser with its message (`server-functions.md`), so anything added here that can fail answers with a `Response` instead.

The client needs nothing more: it reads the nonce from the `<meta property="csp-nonce">` the server renders.

**3. `nosniff` on static files**, in the app's server wrapper, on every static response it serves.

**The module sets no `Cache-Control`.** `no-store` comes from the `noStore` request middleware (`server-functions.md`, "Responses that depend on who is asking").

**A proxy in front of the app sends none of the headers the module sets** — nosniff, the
referrer policy, HSTS. It may add `X-Frame-Options`, as `DENY` only, matching the policy's
`frame-ancestors 'none'`.

## Check it

Run the built app with `NODE_ENV=production`, load each kind of screen, and read the browser console. Each blocked load names its directive and host: add the hosts the app needs, and nothing else.
