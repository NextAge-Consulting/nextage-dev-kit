// Security headers for a TanStack Start app: a Content-Security-Policy with a per-request
// nonce, nosniff, a referrer policy, and HSTS over HTTPS. Copied into the app by the
// security-headers reference (.claude/skills/mfing-bible-of-tanstack/references/
// security-headers.md), which also shows the three places it is wired in.

/** The hosts this app loads from beyond its own origin, per CSP directive. */
export type CspAllow = Partial<Record<"script" | "img" | "font" | "connect" | "frame" | "media" | "worker" | "form", string[]>>;

// One year, without includeSubDomains: a subdomain served over plain HTTP on purpose keeps working.
const HSTS = "max-age=31536000";

/** A fresh nonce for one response: 16 random bytes, base64. */
export function newNonce(): string {
  return btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
}

/** The policy: the app's own origin only, the nonce for scripts, and the hosts `allow` names. */
export function buildCsp(nonce: string, allow: CspAllow = {}): string {
  for (const [key, hosts] of Object.entries(allow))
    for (const host of hosts ?? [])
      if (host === "*" || /\s|;|'/.test(host)) throw new Error(`security headers: "${host}" in allow.${key} is not a host — name each origin, never a wildcard or a keyword`);
  const extra = (key: keyof CspAllow) => (allow[key] ?? []).map((h) => ` ${h}`).join("");
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}'${extra("script")}`,
    // Inline style attributes (Radix positioning, React style={}) need 'unsafe-inline'; a
    // nonce here would make browsers ignore it.
    "style-src 'self' 'unsafe-inline'",
    `img-src 'self' data:${extra("img")}`,
    // Vite inlines small font files as data: URIs.
    `font-src 'self' data:${extra("font")}`,
    `connect-src 'self'${extra("connect")}`,
    `frame-src 'self'${extra("frame")}`,
    `media-src 'self'${extra("media")}`,
    `worker-src 'self'${extra("worker")}`,
    `form-action 'self'${extra("form")}`,
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
  ].join("; ");
}

/** Whether the browser reached the app over HTTPS. Behind a load balancer the app sees plain
 * HTTP, so the balancer's X-Forwarded-Proto decides. */
export function isHttps(request: Request): boolean {
  const forwarded = request.headers.get("x-forwarded-proto");
  if (forwarded) return forwarded.split(",")[0].trim() === "https";
  return new URL(request.url).protocol === "https:";
}

/** The response with the security headers added. The policy goes on HTML pages only, and never
 * replaces one a route set itself (a download's sandbox, say). */
export function withSecurityHeaders(request: Request, response: Response, { nonce, allow }: { nonce: string; allow?: CspAllow }): Response {
  const headers = new Headers(response.headers);
  headers.set("X-Content-Type-Options", "nosniff");
  if (!headers.has("Referrer-Policy")) headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  if (isHttps(request)) headers.set("Strict-Transport-Security", HSTS);
  const html = (headers.get("content-type") ?? "").startsWith("text/html");
  if (html && !headers.has("Content-Security-Policy")) headers.set("Content-Security-Policy", buildCsp(nonce, allow));
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}
