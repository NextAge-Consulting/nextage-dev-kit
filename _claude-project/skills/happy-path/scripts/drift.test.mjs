import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkUnit, inventory, score, surface, THRESHOLD, unitOf, units, writeSnapshot } from './drift.mjs'

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), 'drift.mjs')

function repo(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'happy-drift-'))
  write(dir, files)
  return dir
}
function write(dir, files) {
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), typeof content === 'string' ? content : JSON.stringify(content))
  }
}
const cli = (dir, ...args) => execFileSync('node', [CLI, ...args, '--repo', dir], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })

const SCHEMA = `import { pgTable, integer, text } from 'drizzle-orm/pg-core'
export const customer = pgTable('customer', { customerid: integer().primaryKey() })
export const invoice = pgTable("invoice", {
  invoiceid: integer().primaryKey(),
  customerid: integer().references(() => customer.customerid),
})
// export const ghost = pgTable('ghost', {})
`
const MONOREPO = {
  'package.json': { workspaces: ['apps/*', 'packages/*'] },
  '.claude/sync-substitutions.json': { SHARED_MODULE_DIR: 'apps/shared' },
  'apps/shared/package.json': { name: '@acme/shared' },
  'apps/shared/src/db/schema.ts': SCHEMA,
  'apps/shared/src/billing.ts': 'import { invoice } from "./db/schema"\nexport const total = (db) => db.select().from(invoice)\n',
  'apps/shop/package.json': { name: 'shop' },
  'apps/shop/src/routes/index.tsx': "export const Route = createFileRoute('/')({ component: Home })\n",
  'apps/shop/src/routes/cart.tsx': "export const Route = createFileRoute('/cart')({})\n",
  'apps/shop/src/server/cart.ts': `import { customer } from '@acme/shared'
export const getCart = createServerFn({ method: 'GET' }).handler(logFailures('getCart', async () => customer))
export const addToCart = createServerFn({ method: 'POST' })
  .handler(logFailures('addToCart', async () => 1))
`,
  'apps/shop/src/server/cart.test.ts': "const fake = createServerFn({ method: 'GET' })\n",
  'apps/shop/src/routeTree.gen.ts': "createFileRoute('/generated')\n",
  'apps/office/package.json': { name: 'office' },
  'apps/office/src/routes/index.tsx': "export const Route = createFileRoute('/')({})\n",
  'packages/ui/package.json': { name: '@acme/ui' },
}

test('the units are the shared module and every workspace under apps/', () => {
  assert.deepEqual(units(repo(MONOREPO)), { units: ['apps/shared', 'apps/office', 'apps/shop'], problems: [] })
})

test('a repository with no workspaces is one unit: the shared module, or the root', () => {
  assert.deepEqual(units(repo({ '.claude/sync-substitutions.json': { SHARED_MODULE_DIR: 'src' } })).units, ['src'])
  assert.deepEqual(units(repo({ 'package.json': { name: 'web' } })).units, ['.'])
})

test('a workspace pattern it cannot expand is a problem, not a skipped app', () => {
  assert.match(units(repo({ 'package.json': { workspaces: ['apps/**'] } })).problems[0], /"apps\/\*\*"/)
})

test('a path belongs to the unit holding it, and to none outside every unit', () => {
  const all = ['apps/shared', 'apps/shop']
  assert.equal(unitOf('apps/shop/src/routes/cart.tsx', all), 'apps/shop')
  assert.equal(unitOf('packages/ui/src/button.tsx', all), null)
  assert.equal(unitOf('src/x.ts', ['.']), '.')
})

test('routes, server functions and tables are found by declaration; tests, generated files and comments are not', () => {
  const dir = repo(MONOREPO)
  assert.deepEqual(surface(dir, 'apps/shop'), { routes: ['/', '/cart'], serverFunctions: ['addToCart', 'getCart'], tables: [] })
  assert.deepEqual(surface(dir, 'apps/shared'), { routes: [], serverFunctions: [], tables: ['customer', 'invoice'] })
})

test('the inventory carries reach: files using it, foreign keys at a table', () => {
  const inv = inventory(repo(MONOREPO), 'apps/shared')
  const customer = inv.tables.find((t) => t.name === 'customer')
  const invoice = inv.tables.find((t) => t.name === 'invoice')
  assert.equal(customer.foreignKeys, 1)
  assert.equal(invoice.foreignKeys, 0)
  assert.equal(customer.usedIn, 1, 'used from the shop app')
  assert.equal(invoice.usedIn, 1, 'used from billing.ts')
})

test('the inventory counts the fix commits that touched a declaring file', () => {
  const dir = repo(MONOREPO)
  const git = (...a) => execFileSync('git', ['-C', dir, ...a], { stdio: 'ignore' })
  git('init', '-q')
  git('-c', 'user.email=t@example.com', '-c', 'user.name=t', 'add', '-A')
  git('-c', 'user.email=t@example.com', '-c', 'user.name=t', 'commit', '-qm', 'feat: start')
  fs.appendFileSync(path.join(dir, 'apps/shop/src/server/cart.ts'), '\n')
  git('-c', 'user.email=t@example.com', '-c', 'user.name=t', 'commit', '-qam', '🐛 fix(cart): totals')
  const inv = inventory(dir, 'apps/shop')
  assert.equal(inv.fixHistory, true)
  assert.equal(inv.serverFunctions.find((f) => f.name === 'getCart').fixCommits, 1)
  assert.equal(inv.routes.find((r) => r.name === '/cart').fixCommits, 0)
})

test('the score is items added plus items removed over the snapshot size, each weighted the same', () => {
  const was = { routes: ['/a', '/b'], serverFunctions: ['f', 'g'], tables: ['t', 'u', 'v', 'w'] }
  assert.deepEqual(score(was, was), { score: 0, changed: 0, size: 8 })
  assert.deepEqual(score(was, { ...was, routes: ['/a', '/c'] }), { score: 2 / 8, changed: 2, size: 8 })
  assert.deepEqual(score(was, { ...was, tables: [] }), { score: 4 / 8, changed: 4, size: 8 })
  assert.equal(score({}, {}).score, 0)
  assert.equal(score({}, { routes: ['/x'] }).score, Number.POSITIVE_INFINITY)
})

test('an app with no happy-path tests is reported as such', () => {
  const r = checkUnit(repo(MONOREPO), 'apps/shop')
  assert.equal(r.status, 'none')
  assert.match(r.message, /apps\/shop has no happy-path tests — run \/happy-path apps\/shop/)
})

test('happy-path tests with no snapshot are reported, not passed', () => {
  const dir = repo({ ...MONOREPO, 'apps/shop/test/happy-path/cart.happy.integration.test.ts': '' })
  assert.equal(checkUnit(dir, 'apps/shop').status, 'unsnapshotted')
})

test('a fresh snapshot is ok; drift past the threshold is reported with its share', () => {
  const dir = repo({ ...MONOREPO, 'apps/shop/test/happy-path/cart.happy.integration.test.ts': '' })
  assert.equal(writeSnapshot(dir, 'apps/shop'), 'apps/shop/test/happy-path/snapshot.json')
  assert.equal(checkUnit(dir, 'apps/shop').status, 'ok')
  // One of four items added: exactly the threshold, not past it.
  write(dir, { 'apps/shop/src/routes/checkout.tsx': "createFileRoute('/checkout')\n" })
  assert.equal(score(JSON.parse(fs.readFileSync(path.join(dir, 'apps/shop/test/happy-path/snapshot.json'), 'utf8')), surface(dir, 'apps/shop')).score, THRESHOLD)
  assert.equal(checkUnit(dir, 'apps/shop').status, 'ok')
  write(dir, { 'apps/shop/src/routes/account.tsx': "createFileRoute('/account')\n" })
  const r = checkUnit(dir, 'apps/shop')
  assert.equal(r.status, 'drifted')
  assert.match(r.message, /moved 50%/)
})

test('a snapshot that is not JSON is reported as unreadable', () => {
  const dir = repo({ ...MONOREPO, 'apps/shop/test/happy-path/a.happy.integration.test.ts': '', 'apps/shop/test/happy-path/snapshot.json': '{' })
  assert.equal(checkUnit(dir, 'apps/shop').status, 'unreadable')
})

test('check --changed reports only the units the changed source files fall in', () => {
  const dir = repo(MONOREPO)
  const list = path.join(dir, 'changed.txt')
  fs.writeFileSync(list, 'apps/shop/src/server/cart.ts\napps/office/README.md\npackages/ui/src/x.ts\n')
  assert.equal(cli(dir, 'check', '--changed', list), 'none\tapps/shop\tapps/shop has no happy-path tests — run /happy-path apps/shop\n')
})

test('the command names the units, writes a snapshot, and refuses a folder that is not a unit', () => {
  const dir = repo(MONOREPO)
  assert.equal(cli(dir, 'units'), 'apps/shared\napps/office\napps/shop\n')
  assert.equal(cli(dir, 'snapshot', 'apps/office'), 'apps/office/test/happy-path/snapshot.json\n')
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(dir, 'apps/office/test/happy-path/snapshot.json'), 'utf8')), {
    unit: 'apps/office', routes: ['/'], serverFunctions: [], tables: [],
  })
  assert.throws(() => cli(dir, 'check', 'packages/ui'), /not an app or the shared module/)
})
