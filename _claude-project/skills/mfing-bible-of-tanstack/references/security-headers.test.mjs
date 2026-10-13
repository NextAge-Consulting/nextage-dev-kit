// node --test .claude/skills/mfing-bible-of-tanstack/references/security-headers.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { buildCsp, isHttps, newNonce, withSecurityHeaders } from './security-headers.ts'

const html = (headers = {}) => new Response('<!doctype html>', { headers: { 'content-type': 'text/html; charset=utf-8', ...headers } })
const req = (url = 'http://app.example.com/', headers = {}) => new Request(url, { headers })

test('a nonce is fresh per call and 16 random bytes', () => {
  const a = newNonce()
  assert.notEqual(a, newNonce())
  assert.equal(Buffer.from(a, 'base64').length, 16)
})

test('the policy allows the own origin, the nonce for scripts, and the named hosts in their directive', () => {
  const csp = buildCsp('abc', { connect: ['https://api.example.com'], form: ['https://login.example.com'] })
  const d = Object.fromEntries(csp.split('; ').map((p) => [p.split(' ')[0], p]))
  assert.equal(d['script-src'], "script-src 'self' 'nonce-abc'")
  assert.equal(d['style-src'], "style-src 'self' 'unsafe-inline'")
  assert.equal(d['font-src'], "font-src 'self' data:")
  assert.equal(d['connect-src'], "connect-src 'self' https://api.example.com")
  assert.equal(d['form-action'], "form-action 'self' https://login.example.com")
  assert.equal(d['frame-ancestors'], "frame-ancestors 'none'")
  assert.equal(d['object-src'], "object-src 'none'")
})

test('a wildcard or a keyword in an allow list fails by name', () => {
  assert.throws(() => buildCsp('n', { img: ['*'] }), /allow\.img is not a host/)
  assert.throws(() => buildCsp('n', { script: ["'unsafe-eval'"] }), /allow\.script is not a host/)
})

test('HTTPS comes from the load balancer when it says so, else from the URL', () => {
  assert.equal(isHttps(req('http://app/', { 'x-forwarded-proto': 'https' })), true)
  assert.equal(isHttps(req('http://app/', { 'x-forwarded-proto': 'http, https' })), false)
  assert.equal(isHttps(req('https://app/')), true)
  assert.equal(isHttps(req('http://app/')), false)
})

test('an HTML page gets the policy, nosniff and a referrer policy; HSTS only over HTTPS, without subdomains', () => {
  const plain = withSecurityHeaders(req(), html(), { nonce: 'n1' })
  assert.match(plain.headers.get('content-security-policy'), /'nonce-n1'/)
  assert.equal(plain.headers.get('x-content-type-options'), 'nosniff')
  assert.equal(plain.headers.get('referrer-policy'), 'strict-origin-when-cross-origin')
  assert.equal(plain.headers.get('strict-transport-security'), null)
  const secure = withSecurityHeaders(req('http://app/', { 'x-forwarded-proto': 'https' }), html(), { nonce: 'n1' })
  assert.equal(secure.headers.get('strict-transport-security'), 'max-age=31536000')
})

test('a non-HTML response gets nosniff but no policy; a route\'s own policy and referrer policy are kept', async () => {
  const json = withSecurityHeaders(req(), new Response('{}', { headers: { 'content-type': 'application/json' } }), { nonce: 'n' })
  assert.equal(json.headers.get('content-security-policy'), null)
  assert.equal(json.headers.get('x-content-type-options'), 'nosniff')
  const own = withSecurityHeaders(req(), html({ 'content-security-policy': 'sandbox', 'referrer-policy': 'no-referrer' }), { nonce: 'n' })
  assert.equal(own.headers.get('content-security-policy'), 'sandbox')
  assert.equal(own.headers.get('referrer-policy'), 'no-referrer')
  assert.equal(await own.text(), '<!doctype html>')
  assert.equal(withSecurityHeaders(req(), new Response('x', { status: 404, headers: { 'content-type': 'text/html' } }), { nonce: 'n' }).status, 404)
})
