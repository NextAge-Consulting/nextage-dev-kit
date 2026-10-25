#!/usr/bin/env node
/**
 * What an app is made of — its routes, server functions and tables — and how far that has
 * moved since its happy path was last decided.
 *
 *   node .claude/skills/happy-path/scripts/drift.mjs units [--repo <dir>]
 *        every app and the shared module, one per line
 *   node .claude/skills/happy-path/scripts/drift.mjs inventory <unit> [--repo <dir>]
 *        the unit's routes, server functions and tables as JSON, each with what the audit
 *        ranks by: the files that use it, the foreign keys pointing at a table, and the
 *        fix commits that touched the file declaring it
 *   node .claude/skills/happy-path/scripts/drift.mjs snapshot <unit> [--repo <dir>]
 *        writes the unit's snapshot (SNAPSHOT below), the record drift is measured from
 *   node .claude/skills/happy-path/scripts/drift.mjs check [<unit>…] [--changed <file>] [--repo <dir>]
 *        one line per unit: `<status>\t<unit>\t<what it means>`, status one of
 *        ok, none (no happy-path tests), unsnapshotted, drifted, unreadable. With --changed,
 *        the units are those the listed paths (one per line, `-` for stdin) fall in; with
 *        neither, every unit. Exits 1 only when it cannot work out the units at all.
 *
 * A unit is an app — a workspace under apps/ in the root package.json's workspaces — or the
 * shared module, SHARED_MODULE_DIR in .claude/sync-substitutions.json. A repository that
 * declares no workspaces is one unit: the shared module, or the root.
 *
 * Found by declaration, the way TanStack Start and Drizzle write them:
 *   route            createFileRoute('/path') and its lazy and server forms
 *   server function  `const name = createServerFn(…)`
 *   table            `<dialect>Table('name', …)` and `<schema>.table('name', …)`
 *
 * The score is (items added + items removed) / items in the snapshot, every item weighted
 * the same. Past THRESHOLD the core the developer chose was chosen from a different app.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * The kit's drift threshold: a quarter of the app's routes, server functions and tables
 * added or removed since the audit. Below it the app is the one the core was chosen from,
 * grown at the edges; past it, one item in four is new or gone, and what is core may have
 * moved with them. A kit constant: no project or developer setting changes it.
 */
export const THRESHOLD = 0.25

/** Where a unit's happy-path tests live, from the unit, and the snapshot beside them. */
export const HAPPY_DIR = 'test/happy-path'
export const SNAPSHOT = `${HAPPY_DIR}/snapshot.json`
const HAPPY_TEST = /\.happy\.integration\.test\.tsx?$/

const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', 'coverage', '.output', '.vinxi', '.tanstack', '.wxt', '.git', '.turbo', '.next'])
const SOURCE = /\.(ts|tsx|mts|cts)$/
const NOT_SOURCE = /(\.d\.ts|\.gen\.ts|\.test\.tsx?)$/

const posix = (p) => p.split(path.sep).join('/')
const clean = (d) => posix(String(d ?? '').trim()).replace(/^\.\//, '').replace(/\/+$/, '') || '.'
const within = (file, dir) => dir === '.' || file === dir || file.startsWith(`${dir}/`)

function readJson(file) {
  return JSON.parse(readFileSync(file, 'utf8'))
}

/** The workspace folders the root package.json declares. */
function workspaceDirs(repo) {
  const manifest = path.join(repo, 'package.json')
  if (!existsSync(manifest)) return { dirs: [], problems: [] }
  const declared = readJson(manifest).workspaces
  const globs = Array.isArray(declared) ? declared : (declared?.packages ?? [])
  const dirs = []
  const problems = []
  for (const raw of globs) {
    const glob = clean(raw)
    if (!/[*?[{]/.test(glob)) {
      if (existsSync(path.join(repo, glob, 'package.json'))) dirs.push(glob)
      continue
    }
    if (!/^[^*?[{]+\/\*$/.test(glob)) {
      problems.push(`package.json workspaces: "${raw}" — only a folder or "<folder>/*" can be expanded to find the apps`)
      continue
    }
    const parent = glob.slice(0, -2)
    if (!existsSync(path.join(repo, parent))) continue
    for (const name of readdirSync(path.join(repo, parent)).sort()) {
      if (existsSync(path.join(repo, parent, name, 'package.json'))) dirs.push(`${parent}/${name}`)
    }
  }
  return { dirs: [...new Set(dirs)], problems }
}

/** The shared module's folder, or null when the project has none. */
function sharedModule(repo) {
  const subs = path.join(repo, '.claude/sync-substitutions.json')
  const value = existsSync(subs) ? String(readJson(subs).SHARED_MODULE_DIR ?? '').trim() : ''
  return value ? clean(value) : null
}

/** Every app and the shared module, shared module first. */
export function units(repo) {
  const shared = sharedModule(repo)
  const { dirs, problems } = workspaceDirs(repo)
  if (problems.length) return { units: [], problems }
  if (!dirs.length) return { units: [shared ?? '.'], problems: [] }
  const apps = dirs.filter((d) => d.startsWith('apps/') && d !== shared)
  return { units: [...(shared ? [shared] : []), ...apps], problems: [] }
}

/** The unit a path falls in: the deepest unit folder holding it. */
export function unitOf(file, all) {
  const f = clean(file)
  return all.filter((u) => within(f, u)).sort((a, b) => b.length - a.length)[0] ?? null
}

function* walk(repo, dir, others) {
  let entries
  try {
    entries = readdirSync(path.join(repo, dir))
  } catch {
    return
  }
  for (const name of entries.sort()) {
    if (SKIP_DIRS.has(name)) continue
    const rel = dir === '.' ? name : `${dir}/${name}`
    if (others.some((o) => o !== '.' && within(rel, o))) continue
    if (statSync(path.join(repo, rel)).isDirectory()) yield* walk(repo, rel, others)
    else yield rel
  }
}

/** Source text with comments blanked, line breaks kept. */
function code(repo, file) {
  return readFileSync(path.join(repo, file), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/(^|[^:'"`\\])\/\/[^\n]*/g, '$1')
}

const ROUTE = /\bcreate(?:Lazy)?(?:File|ServerFile|APIFile)Route\s*\(\s*(['"`])([^'"`]+)\1/g
const SERVER_FN = /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*createServerFn\b/g
const TABLE = /\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*(?:(?:pg|mssql|mysql|sqlite|singlestore|gel|cockroach)Table(?:WithSchema)?|(?!console\b)[A-Za-z_$][\w$]*\.table)\s*\(\s*(['"`])([^'"`]+)\2/g

/** The unit's routes, server functions and tables, each with the file declaring it. */
function declarations(repo, unit, all) {
  const others = all.filter((u) => u !== unit && within(u, unit))
  const items = []
  const files = []
  for (const file of walk(repo, unit, others)) {
    if (!SOURCE.test(file) || NOT_SOURCE.test(file)) continue
    files.push(file)
    const text = code(repo, file)
    for (const m of text.matchAll(ROUTE)) items.push({ kind: 'route', name: m[2], file })
    for (const m of text.matchAll(SERVER_FN)) items.push({ kind: 'serverFunction', name: m[1], file, symbol: m[1] })
    for (const m of text.matchAll(TABLE)) items.push({ kind: 'table', name: m[3], file, symbol: m[1] })
  }
  return { items, files }
}

const KEY = { route: 'routes', serverFunction: 'serverFunctions', table: 'tables' }

/** The unit as the snapshot records it: each kind's names, sorted and distinct. */
export function surface(repo, unit) {
  const { units: all, problems } = units(repo)
  if (problems.length) throw new Error(problems.join('\n'))
  const { items } = declarations(repo, unit, all)
  const out = { routes: [], serverFunctions: [], tables: [] }
  for (const it of items) out[KEY[it.kind]].push(it.name)
  for (const k of Object.keys(out)) out[k] = [...new Set(out[k])].sort()
  return out
}

/** The drift score from a snapshot to now: changed items over the snapshot's size. */
export function score(snapshot, now) {
  let changed = 0
  let size = 0
  for (const k of Object.values(KEY)) {
    const was = new Set(snapshot[k] ?? [])
    const is = new Set(now[k] ?? [])
    size += was.size
    for (const n of is) if (!was.has(n)) changed++
    for (const n of was) if (!is.has(n)) changed++
  }
  if (size === 0) return { score: changed === 0 ? 0 : Number.POSITIVE_INFINITY, changed, size }
  return { score: changed / size, changed, size }
}

function hasHappyTests(repo, unit, all) {
  const others = all.filter((u) => u !== unit && within(u, unit))
  for (const file of walk(repo, unit, others)) if (HAPPY_TEST.test(file)) return true
  return false
}

const snapshotPath = (repo, unit) => path.join(repo, unit === '.' ? SNAPSHOT : `${unit}/${SNAPSHOT}`)

/** One unit's standing: { status, unit, message }. */
export function checkUnit(repo, unit, all = units(repo).units) {
  const fix = `run /happy-path ${unit}`
  if (!hasHappyTests(repo, unit, all)) return { status: 'none', unit, message: `${unit} has no happy-path tests — ${fix}` }
  const file = snapshotPath(repo, unit)
  if (!existsSync(file)) return { status: 'unsnapshotted', unit, message: `${unit} has happy-path tests but no ${SNAPSHOT}, so how far it has moved is unknown — ${fix}` }
  let snap
  try {
    snap = readJson(file)
  } catch (e) {
    return { status: 'unreadable', unit, message: `${unit}/${SNAPSHOT} is not valid JSON (${e.message}) — ${fix}` }
  }
  const { score: s, changed, size } = score(snap, surface(repo, unit))
  const pct = Number.isFinite(s) ? `${Math.round(s * 100)}%` : 'all of it'
  if (s > THRESHOLD) {
    return { status: 'drifted', unit, message: `${unit} has moved ${pct} since its happy path was decided (${changed} routes, server functions and tables added or removed, against ${size}; the kit's limit is ${THRESHOLD * 100}%) — ${fix}` }
  }
  return { status: 'ok', unit, message: `${unit}: ${changed} of ${size} items changed since its happy path was decided (${pct})` }
}

/** Fix commits per file, from the repository's history. Empty outside a git repository. */
function fixHistory(repo) {
  const counts = new Map()
  let log
  try {
    log = execFileSync('git', ['-C', repo, 'log', '--no-merges', '--format=@@%s', '--name-only'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 256 * 1024 * 1024 })
  } catch {
    return { counts, available: false }
  }
  let isFix = false
  for (const line of log.split('\n')) {
    if (line.startsWith('@@')) {
      isFix = /^(\S+\s+)?fix(\(|!|:)/i.test(line.slice(2))
      continue
    }
    if (isFix && line) counts.set(line, (counts.get(line) ?? 0) + 1)
  }
  return { counts, available: true }
}

/** How often `symbol` appears in `text` as a whole identifier. */
const wordCount = (text, symbol) => (text.match(/[\w$]+/g) ?? []).filter((word) => word === symbol).length

/** A Drizzle foreign key, `.references(() => <table>.<column>)`, capturing the table. */
const REFERENCE = /\.references\(\s*\(\)\s*(?::[^=]+)?=>\s*([\w$]+)\./g

/** How many foreign keys in `text` point at the table named `symbol`. */
const referencesTo = (text, symbol) => [...text.matchAll(REFERENCE)].filter((match) => match[1] === symbol).length

/** The unit's declarations with what the audit ranks them by. */
export function inventory(repo, unit) {
  const { units: all, problems } = units(repo)
  if (problems.length) throw new Error(problems.join('\n'))
  const { items } = declarations(repo, unit, all)
  // A unit's code is used from the whole repository: the shared module's above all.
  const everywhere = []
  for (const u of all) everywhere.push(...declarations(repo, u, all).files)
  const texts = new Map([...new Set(everywhere)].map((f) => [f, code(repo, f)]))
  const { counts, available } = fixHistory(repo)
  const out = { unit, fixHistory: available, routes: [], serverFunctions: [], tables: [] }
  for (const it of items) {
    const entry = { name: it.name, file: it.file, fixCommits: counts.get(it.file) ?? 0 }
    if (it.symbol) {
      entry.usedIn = [...texts].filter(([f, t]) => f !== it.file && wordCount(t, it.symbol) > 0).length
    }
    if (it.kind === 'table') {
      entry.foreignKeys = [...texts.values()].reduce((n, t) => n + referencesTo(t, it.symbol), 0)
    }
    out[KEY[it.kind]].push(entry)
  }
  return out
}

/** Writes the unit's snapshot; returns its path from the repository root. */
export function writeSnapshot(repo, unit) {
  const file = snapshotPath(repo, unit)
  mkdirSync(path.dirname(file), { recursive: true })
  writeFileSync(file, `${JSON.stringify({ unit, ...surface(repo, unit) }, null, 2)}\n`)
  return posix(path.relative(repo, file))
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const take = (flag) => {
    const at = args.indexOf(flag)
    if (at === -1) return null
    const [, value] = args.splice(at, 2)
    return value
  }
  const repo = path.resolve(take('--repo') ?? '.')
  const changed = take('--changed')
  const [mode, ...rest] = args
  const fail = (msg) => {
    console.error(`happy-path drift: ${msg}`)
    process.exit(1)
  }
  const { units: all, problems } = units(repo)
  if (problems.length) fail(problems.join('\n'))
  const known = (u) => {
    const c = clean(u)
    if (!all.includes(c)) fail(`${u} is not an app or the shared module here; the units are: ${all.join(', ')}`)
    return c
  }

  if (mode === 'units') {
    console.log(all.join('\n'))
  } else if (mode === 'inventory' && rest.length === 1) {
    console.log(JSON.stringify(inventory(repo, known(rest[0])), null, 2))
  } else if (mode === 'snapshot' && rest.length === 1) {
    console.log(writeSnapshot(repo, known(rest[0])))
  } else if (mode === 'check') {
    let targets
    if (changed) {
      const list = readFileSync(changed === '-' ? 0 : changed, 'utf8').split('\n').filter((f) => SOURCE.test(f))
      targets = [...new Set(list.map((f) => unitOf(f, all)).filter(Boolean))]
    } else {
      targets = rest.length ? rest.map(known) : all
    }
    for (const u of targets) {
      const r = checkUnit(repo, u, all)
      console.log(`${r.status}\t${r.unit}\t${r.message}`)
    }
  } else {
    fail('usage: drift.mjs units | inventory <unit> | snapshot <unit> | check [<unit>…] [--changed <file|->]  [--repo <dir>]')
  }
}
