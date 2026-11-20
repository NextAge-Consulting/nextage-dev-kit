/**
 * Design Packs, the receiving side: put a piece, or an app pack's list of pieces, into
 * this project, and say what a pack has changed since.
 *
 *   planInstall(repo, from, target, { swap, map })   what installing would do, nothing written
 *   applyInstall(repo, plan)                         copy the files it lists
 *   compare(repo, from, file?)                       each installed file whose pack file has changed
 *
 * `from` is a checkout of the packs repository: `pieces/<piece>/` folders, each with its
 * piece.json, and `packs/<name>.json`, each `{ "pieces": [<piece names>] }`. The version is
 * the checkout's own (`git describe`).
 *
 * The plan is everything code can decide: the pieces, each piece they depend on first;
 * where each file lands — the workspace of the same name where this project has one, else
 * the UI package, named as that folder's files already are; each import rewritten to the
 * file it meant, by this project's package names and exports; each file the pieces expect
 * this project to have, found by its path, its name or its exports; each role and library
 * they use that this project lacks; and each block or atom of this project an incoming
 * file would stand beside, with the screens using it. Nothing is copied while a file
 * stands beside one of the project's own with no answer, or an expected file is not found
 * at all (one found but short an export is listed, and fitted after the copy):
 * `map` carries the answers a person gives.
 *
 *   map.standIn  { "<pack file>": "<this project's file>" }       what stands in for a file
 *                                                                  a piece expects
 *   map.beside   { "<pack file>": "use-existing" | "replace" | "keep-both" }
 *                the answer for a file that stands beside one of the project's own: fold
 *                the incoming one into the project's and copy nothing; copy it over or
 *                beside the project's, which is then removed by hand; or keep both, which
 *                two files at one path cannot do
 *
 * Every installed file is pending, and points at its pack file and version:
 * `// ui-pack: <piece>/<file> @ <version>` in code, `pack: <piece>/<file> @ <version>` in a
 * reference's frontmatter.
 */

import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { checkDesignTokens, loadTypeScript, parityProblems, readKeys, rolesOf } from '../../design-system/scripts/check-design-tokens.mjs'
import { resolveVars, toPx } from '../../design-system/scripts/compare-ui-values.mjs'
import { uiPackages, workspaceDirs } from '../../design-system/scripts/ui-sources.mjs'
import { checkUiStatus, frontmatter, headers, isComponent, key, LEDGER, listOf } from '../../ui-patterns/scripts/check-ui-status.mjs'
import { importsOf, PACK_SCOPE, packageDir, stemOf, valuesOf } from './design-pack.mjs'

const REFERENCES = '.claude/skills/ui-patterns/references'
const INVENTORY = '.claude/rules/project/ui-inventory.md'
const POINTER = /ui-pack:\s*(\S+?)\/(\S+)\s+@\s+(\S+)/
const REFERENCE_POINTER = /^pack:\s*(\S+?)\/(\S+)\s+@\s+(\S+)/m
const posix = (p) => p.split(path.sep).join('/')
const isCode = (f) => /\.tsx?$/.test(f) && !f.endsWith('.d.ts')
const read = (f) => fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n')

// ─── the pack ────────────────────────────────────────────────────────────────

/** A packs checkout: where its pieces are, and its version. */
export function readPack(from) {
  const root = path.resolve(from)
  const pieces = fs.existsSync(path.join(root, 'pieces')) ? path.join(root, 'pieces') : root
  let version = 'local'
  try {
    version = execFileSync('git', ['-C', root, 'describe', '--tags', '--always', '--dirty'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || 'local'
  } catch {}
  const piece = (name) => {
    const file = path.join(pieces, name, 'piece.json')
    return fs.existsSync(file) ? { name, dir: path.join(pieces, name), json: JSON.parse(read(file)) } : null
  }
  const list = (name) => {
    const file = path.join(root, 'packs', `${name}.json`)
    return fs.existsSync(file) ? (JSON.parse(read(file)).pieces ?? []) : null
  }
  return { root, pieces, version, piece, list }
}

/**
 * The pieces a target names, each piece it depends on ahead of it. `target` is an app
 * pack's name or a piece's; `swap` replaces a listed piece by another.
 */
export function piecesFor(pack, target, swap = {}) {
  const problems = []
  const listed = pack.list(target)
  const start = (listed ?? [target]).map((n) => swap[n] ?? n)
  for (const from of Object.keys(swap)) if (!(listed ?? []).includes(from)) problems.push(`--swap ${from}=${swap[from]}: \`${target}\` does not list \`${from}\``)
  const order = []
  const seen = new Set()
  const visit = (name, via) => {
    if (seen.has(name)) return
    seen.add(name)
    const p = pack.piece(name)
    if (!p) {
      problems.push(`\`${name}\`${via ? `, which \`${via}\` depends on,` : ''} is not a piece of this pack (${pack.pieces})`)
      return
    }
    for (const d of p.json.pieces ?? []) visit(swap[d] ?? d, name)
    order.push(p)
  }
  for (const n of start) visit(n, null)
  return { order, problems }
}

// ─── this project ────────────────────────────────────────────────────────────

/** What install reads about the receiving project. `problems` when it is not ready for a pack. */
export function readProject(repo) {
  const root = fs.realpathSync(repo)
  const { keys, problems, notApplicable } = readKeys(root)
  if (notApplicable) return { problems: [`${notApplicable} — a piece is installed into a UI package`] }
  if (problems.length) return { problems }
  const ui = keys.DESIGN_UI_PACKAGE.replace(/\/$/, '')
  const workspaces = workspaceDirs(root).dirs
  const homes = uiPackages(root, ui).packages.filter((w) => w !== '.')
  const manifests = new Map()
  const manifest = (w) => {
    if (!manifests.has(w)) {
      try {
        manifests.set(w, JSON.parse(read(path.join(root, w, 'package.json'))))
      } catch {
        manifests.set(w, {})
      }
    }
    return manifests.get(w)
  }
  const files = execFileSync('git', ['-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
    .split('\0')
    .filter((f) => f && fs.existsSync(path.join(root, f)))
  const inSystem = (f) => !workspaces.length || homes.some((w) => f.startsWith(`${w}/`))
  const sources = files.filter((f) => /\.tsx?$/.test(f) && inSystem(f) && !/\.(test|spec|stories)\.tsx?$/.test(f))
  const list = (v) => String(v ?? '').split(/\s+/).filter(Boolean)
  const css = [...new Set([...list(keys.DESIGN_TOKEN_FILES), keys.DESIGN_TYPE_FILE, keys.DESIGN_STYLES_FILE].filter(Boolean))]
    .map((r) => posix(path.join(ui, r)))
    .filter((f) => fs.existsSync(path.join(root, f)))
    .map((f) => [f, read(path.join(root, f))])
  return { repo: root, keys, ui, workspaces, homes, manifest, files: new Set(files), sources, css, inSystem, ts: loadTypeScript(root), problems: [] }
}

/** The names a source file exports. */
export function exportsOf(ts, file, text) {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, false, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  const out = new Set()
  for (const s of sf.statements) {
    const exported = s.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword)
    const isDefault = s.modifiers?.some((m) => m.kind === ts.SyntaxKind.DefaultKeyword)
    if (ts.isExportAssignment(s) || (exported && isDefault)) {
      out.add('default')
    } else if (exported && ts.isVariableStatement(s)) {
      for (const d of s.declarationList.declarations) if (ts.isIdentifier(d.name)) out.add(d.name.text)
    } else if (exported && s.name) {
      out.add(s.name.text)
    } else if (ts.isExportDeclaration(s) && s.exportClause && ts.isNamedExports(s.exportClause)) {
      for (const e of s.exportClause.elements) out.add(e.name.text)
    } else if (ts.isExportDeclaration(s) && !s.exportClause) {
      out.add('*')
    }
  }
  return out
}

const pascal = (stem) => stem.split(/[-_\s]+/).map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join('')
const kebab = (stem) => stem.replace(/([a-z0-9])([A-Z])/g, '$1-$2').replace(/([A-Z])([A-Z][a-z])/g, '$1-$2').toLowerCase()

/** How a folder's component files are named: `pascal`, `kebab`, or null when it holds none. */
function namingOf(P, dir) {
  const names = [...P.files].filter((f) => path.dirname(f) === dir && f.endsWith('.tsx')).map((f) => path.basename(f, '.tsx'))
  if (!names.length) return null
  const upper = names.filter((n) => /^[A-Z]/.test(n)).length
  return upper > names.length / 2 ? 'pascal' : 'kebab'
}

/**
 * Where a pack file lands here: in the workspace named as its own was where this project
 * has one in its system, else in the UI package; a component named as its folder's are.
 */
export function destOf(P, piece, file) {
  const from = Object.keys(piece.json.workspaces ?? {}).sort((a, b) => b.length - a.length).find((w) => file.startsWith(`${w}/`))
  const within = from ? file.slice(from.length + 1) : file
  const home = from ? (P.homes.find((w) => path.basename(w) === path.basename(from)) ?? P.ui) : P.ui
  let dest = posix(path.join(home, within))
  if (isComponent(dest)) {
    const naming = namingOf(P, path.dirname(dest))
    const stem = path.basename(dest, '.tsx')
    if (naming && stem !== 'index') dest = posix(path.join(path.dirname(dest), `${naming === 'pascal' ? pascal(stem) : kebab(stem)}.tsx`))
  }
  return dest
}

/** The project's own file standing in for one a piece expects: by the answer given, the
 * same path, the same name, or being the only file that exports everything taken. */
export function findExpected(P, piece, atom, map = {}) {
  if (map.standIn?.[atom.file]) return map.standIn[atom.file]
  const same = destOf(P, piece, atom.file)
  if (P.files.has(same)) return same
  const want = key(stemOf(atom.file))
  const named = P.sources.filter((f) => key(stemOf(f)) === want && isComponent(f) === isComponent(atom.file))
  if (named.length === 1) return named[0]
  const taken = atom.exports.filter((n) => n !== '*')
  if (!taken.length) return null
  const offering = P.sources.filter((f) => {
    const has = exportsOf(P.ts, f, read(path.join(P.repo, f)))
    return taken.every((n) => has.has(n))
  })
  return offering.length === 1 ? offering[0] : null
}

/** The module specifier `from` uses for the project file `to`: a relative path inside one
 * workspace, else the package's name with the subpath its `exports` gives. Null when the
 * package exports no path to it. */
export function specifierFor(P, from, to) {
  const ws = (f) => P.workspaces.filter((w) => f.startsWith(`${w}/`)).sort((a, b) => b.length - a.length)[0] ?? null
  const bare = to.replace(/\.tsx?$/, '')
  if (!P.workspaces.length || ws(from) === ws(to)) {
    const rel = posix(path.relative(path.dirname(from), bare))
    return rel.startsWith('.') ? rel : `./${rel}`
  }
  const w = ws(to)
  const pkg = P.manifest(w)
  const within = `./${to.slice(w.length + 1)}`
  for (const [sub, target] of Object.entries(pkg.exports ?? {})) {
    const t = typeof target === 'string' ? target : (target?.import ?? target?.default)
    if (typeof t !== 'string') continue
    if (!t.includes('*')) {
      if (t === within) return posix(path.join(pkg.name, sub))
      continue
    }
    const [head, tail] = t.split('*')
    if (within.startsWith(head) && within.endsWith(tail) && within.length >= head.length + tail.length) return posix(path.join(pkg.name, sub.split('*').join(within.slice(head.length, within.length - tail.length))))
  }
  return null
}

// ─── the plan ────────────────────────────────────────────────────────────────

/** Everything installing `target` from the checkout at `from` would do here. */
export function planInstall(repo, from, target, { swap = {}, map = {}, apps = [] } = {}) {
  const P = readProject(repo)
  if (P.problems.length) return { problems: P.problems }
  const pack = readPack(from)
  const { order, problems } = piecesFor(pack, target, swap)
  // A control the pieces expect that this project has none of comes with them, where the
  // pack holds it: it lands like any piece. One the project has is left as the project's.
  for (let i = 0; i < order.length; i++) {
    for (const a of order[i].json.atoms ?? []) {
      if (!a.piece || order.some((p) => p.name === a.piece) || findExpected(P, order[i], a, map)) continue
      for (const p of piecesFor(pack, a.piece).order) if (!order.some((o) => o.name === p.name)) order.push(p)
    }
  }
  const workspaceOf = (f) => P.workspaces.filter((w) => f.startsWith(`${w}/`)).sort((a, b) => b.length - a.length)[0] ?? '.'
  const plan = { version: pack.version, pieces: [], files: [], references: [], inventory: [], guides: [], unexported: [], themes: { pack: [], project: [], missing: [] }, expected: [], beside: [], roles: [], packages: [], problems, map }
  if (!order.length) return plan

  // What an earlier install landed here: each file pointing at its pack file.
  const installed = installedFiles(P.repo)

  // Where each pack file lands, and what stands in for each one the pieces expect.
  const landing = new Map() // pack file → this project's file
  const owner = new Map() // pack file → the piece that holds it
  for (const p of order) {
    for (const f of p.json.files.filter((x) => !x.startsWith('references/'))) {
      // A file an earlier install landed stays where it landed, whatever its folder's files
      // are called by now.
      const dest = installed.find((i) => i.piece === p.name && i.packFile === f)?.file ?? destOf(P, p, f)
      // A helper two pieces both hold lands once, from the first; two different files
      // cannot share a place.
      if (landing.has(f)) {
        if (read(path.join(p.dir, f)) !== read(path.join(pack.piece(owner.get(f)).dir, f))) problems.push(`${p.name}/${f} and ${owner.get(f)}/${f} are different files of one name`)
        continue
      }
      const other = [...landing].find(([, v]) => v === dest)
      if (other) problems.push(`${p.name}/${f} and ${owner.get(other[0])}/${other[0]} both land at ${dest}`)
      landing.set(f, dest)
      owner.set(f, p.name)
    }
  }
  const standIn = new Map()
  for (const p of order) {
    for (const a of p.json.atoms ?? []) {
      if (landing.has(a.file)) continue
      const found = findExpected(P, p, a, map)
      const missing = found && P.files.has(found) ? a.exports.filter((n) => n !== '*' && !exportsOf(P.ts, found, read(path.join(P.repo, found))).has(n)) : []
      let entry = plan.expected.find((e) => e.file === a.file)
      if (entry) {
        entry.exports = [...new Set([...entry.exports, ...a.exports])].sort()
        entry.missing = [...new Set([...entry.missing, ...missing])].sort()
        entry.pieces.push(p.name)
      } else {
        entry = { file: a.file, name: a.name, exports: a.exports, found: found && P.files.has(found) ? found : null, missing, pieces: [p.name], asks: new Set(), unseen: [] }
        plan.expected.push(entry)
      }
      // Each value a piece passes for a prop — `Button variant quiet` — is something the
      // stand-in has to take.
      for (const [name, props] of Object.entries(a.uses ?? {})) for (const [prop, values] of Object.entries(props)) for (const v of values) entry.asks.add(`${name} ${prop} ${v}`)
      if (found && P.files.has(found)) standIn.set(a.file, found)
    }
  }

  // What a stand-in's file never mentions is a variant or an option it has still to gain.
  for (const e of plan.expected) {
    const words = e.found ? new Set(read(path.join(P.repo, e.found)).split(/[^A-Za-z0-9_-]+/)) : new Set()
    e.asks = [...e.asks].sort()
    e.unseen = e.found ? e.asks.filter((a) => !words.has(a.split(' ').slice(2).join(' '))) : e.asks
    e.done = e.pieces.every((name) => installed.some((i) => i.piece === name))
    if (e.done) {
      e.unseen = []
      e.missing = []
    }
  }

  // A file of this project an incoming file would stand beside: the same place, the same
  // name, or a block of the same type.
  const typeOf = (text) => headers(text).block
  // An answer is the word alone, or the word and the human's reason: `keep-both: <reason>`.
  const answerFor = (f) => {
    const [answer, ...reason] = String(map.beside?.[f] ?? '').split(':')
    return { answer: answer.trim() || null, reason: reason.join(':').trim() }
  }
  // Every file of the project that imports one: each import whose path ends in its name,
  // a block that draws it included.
  const importsBy = new Map(P.sources.map((x) => [x, importsOf(P.ts, x, read(path.join(P.repo, x))).map((d) => d.spec.split('/').at(-1))]))
  const importersOf = (file) => {
    const stem = path.basename(file).replace(/\.tsx?$/, '')
    return P.sources.filter((x) => x !== file && importsBy.get(x).includes(stem))
  }
  const mine = P.sources.filter(isComponent).map((f) => ({ file: f, text: read(path.join(P.repo, f)) }))
  for (const [f, dest] of landing) {
    const incoming = read(path.join(pack.piece(owner.get(f)).dir, f))
    if (!isComponent(dest)) {
      // Any other file stands beside one at its own path, or beside a file of its folder
      // that already exports a name it exports: the same thing under another file name.
      const at = (existing, why) => plan.beside.push({ piece: owner.get(f), file: f, dest, existing, why, usedBy: importersOf(existing), ...answerFor(f) })
      if (P.files.has(dest)) {
        if (!POINTER.test(read(path.join(P.repo, dest)))) at(dest, 'the same file')
      } else if (isCode(dest)) {
        const gives = [...exportsOf(P.ts, dest, incoming)].filter((n) => n !== 'default' && n !== '*')
        for (const o of P.sources.filter((x) => !isComponent(x) && path.dirname(x) === path.dirname(dest))) {
          const text = read(path.join(P.repo, o))
          const shared = POINTER.test(text) ? [] : gives.filter((n) => exportsOf(P.ts, o, text).has(n))
          if (shared.length) at(o, `it exports the same name, ${shared.join(', ')}`)
        }
      }
      continue
    }
    if (POINTER.test(mine.find((m) => m.file === dest)?.text ?? '')) continue
    const type = typeOf(incoming)
    const beside = mine.filter((m) => !POINTER.test(m.text) && (m.file === dest || key(stemOf(m.file)) === key(stemOf(dest)) || (type && typeOf(m.text) === type)))
    for (const m of beside) {
      const usedBy = importersOf(m.file)
      plan.beside.push({ piece: owner.get(f), file: f, dest, existing: m.file, why: m.file === dest ? 'the same file' : type && typeOf(m.text) === type ? `a block of the same type, ${type}` : 'the same name', usedBy, ...answerFor(f) })
    }
  }
  // Answered use-existing, the pieces use the project's file in the same place; failing
  // that, the one of the same name; and only then another block of the type.
  const closeness = (b) => (b.existing === b.dest ? 0 : key(stemOf(b.existing)) === key(stemOf(b.dest)) ? 1 : 2)
  const useExisting = new Map()
  for (const b of plan.beside.filter((x) => x.answer === 'use-existing').sort((a, c) => closeness(a) - closeness(c))) if (!useExisting.has(b.file)) useExisting.set(b.file, b.existing)
  // Each file of the project's own that takes a pack file's place carries that piece's
  // interface from here on, and is marked as doing so.
  plan.standsIn = [...useExisting].map(([packFile, file]) => ({ file, piece: owner.get(packFile), packFile }))

  // Each file, with its imports rewritten to what they meant.
  for (const p of order) {
    const lands = (packFile) => useExisting.get(packFile) ?? landing.get(packFile) ?? standIn.get(packFile) ?? null
    // A carrier installed earlier: this project's file pointing at that pack file.
    const carried = (packFile) => installed.find((i) => i.packFile === packFile)?.file ?? null
    plan.pieces.push({ name: p.name, files: p.json.files.length })
    for (const f of p.json.files) {
      const text = read(path.join(p.dir, f))
      if (f.startsWith('references/')) {
        const dest = `${REFERENCES}/${path.basename(f)}`
        // A recipe or rule a pack already landed here stays as this project has it.
        const installed = P.files.has(dest) && /^pack:/m.test(read(path.join(P.repo, dest)))
        plan.references.push({ piece: p.name, file: f, dest, installed, text, code: listOf((frontmatter(text) ?? {}).code).map((c) => ({ pack: c, dest: lands(c) ?? carried(c) })) })
        continue
      }
      if (useExisting.has(f) || owner.get(f) !== p.name) continue
      const dest = landing.get(f)
      const edits = []
      if (isCode(f)) {
        for (const d of importsOf(P.ts, f, text)) {
          let meant = (p.json.imports ?? {})[d.spec] ?? null
          if (!meant && d.spec.startsWith('.')) {
            const base = posix(path.join(path.dirname(f), d.spec))
            meant = [base, `${base}.ts`, `${base}.tsx`, `${base}/index.ts`, `${base}/index.tsx`].find((c) => landing.has(c) || standIn.has(c) || (p.json.atoms ?? []).some((a) => a.file === c)) ?? null
          }
          if (!meant) {
            if (d.spec.startsWith(`${PACK_SCOPE}/`)) problems.push(`${p.name}/${f}: imports \`${d.spec}\`, which piece.json does not place`)
            continue
          }
          const to = lands(meant)
          if (!to) continue // an expected file not found: reported once, under expected
          const spec = specifierFor(P, dest, to)
          if (!spec) problems.push(`${dest}: needs \`${to}\`, and its package exports no path to it — add one to its package.json \`exports\``)
          else if (spec !== d.spec) edits.push({ start: d.start, end: d.end, spec })
        }
      }
      const here = installed.find((i) => i.file === dest && i.piece === p.name && i.packFile === f)
      plan.files.push({ piece: p.name, file: f, dest, text, edits, exists: P.files.has(dest), installed: here?.version ?? null })
    }
    plan.inventory.push({ piece: p.name, text: read(path.join(p.dir, 'inventory.md')) })
    if (fs.existsSync(path.join(p.dir, 'GUIDE.md'))) plan.guides.push({ piece: p.name, file: path.join(p.dir, 'GUIDE.md') })
  }

  // The roles and libraries the pieces use that this project lacks.
  const defined = rolesOf(P.css)
  const declared = new Set()
  for (const [, s] of P.css) for (const m of s.matchAll(/(--[A-Za-z0-9-]+)\s*:/g)) declared.add(m[1])
  const roles = new Map()
  for (const p of order) for (const r of p.json.roles ?? []) roles.set(r.name, { ...r, classes: [...new Set([...(roles.get(r.name)?.classes ?? []), ...(r.classes ?? [])])], pieces: [...(roles.get(r.name)?.pieces ?? []), p.name] })
  for (const r of roles.values()) {
    const present = declared.has(r.name) || defined.typeRoles.has(r.name) || defined.utilities.has(r.name)
    const classes = [...new Set([...roles.values()].filter((x) => x.name === r.name).flatMap((x) => x.classes ?? []))]
    plan.roles.push({ ...r, classes, present, still: [] })
  }
  const libs = new Map()
  for (const p of order) for (const [name, version] of Object.entries(p.json.packages ?? {})) libs.set(name, { name, version, pieces: [...(libs.get(name)?.pieces ?? []), p.name] })
  for (const l of libs.values()) {
    const at = packageDir(l.name, path.join(P.repo, P.ui))
    // The workspaces whose landed files need it: where it is added.
    const into = [...new Set([...landing].filter(([f]) => l.pieces.includes(owner.get(f))).map(([, d]) => workspaceOf(d)))].sort()
    plan.packages.push({ ...l, installed: at ? JSON.parse(read(path.join(at, 'package.json'))).version : null, into })
  }
  // A landed component no package path reaches: an app importing it needs one added.
  const outsider = P.workspaces.find((w) => !P.homes.includes(w)) ?? P.workspaces.find((w) => w !== P.ui)
  for (const dest of new Set(landing.values())) {
    if (!isComponent(dest) || !P.workspaces.length) continue
    const from = workspaceOf(dest) === outsider ? P.ui : outsider
    if (from && specifierFor(P, `${from}/x.ts`, dest) === null) plan.unexported.push(dest)
  }
  // The themes the pieces are built for, and the ones this project's token files lack.
  const tokenFiles = String(P.keys.DESIGN_TOKEN_FILES ?? '').split(/\s+/).filter(Boolean).map((r) => posix(path.join(P.ui, r)))
  const here = parityProblems(P.css.filter(([f]) => tokenFiles.includes(f))).applies ? ['light', 'dark'] : ['light']
  const built = [...new Set(order.flatMap((p) => p.json.themes ?? ['light']))]
  plan.themes = { pack: built, project: here, missing: built.filter((t) => !here.includes(t)) }
  // The apps the pieces are for. A recipe or behaviour rule governs every app unless it names
  // some, so one landed with no app named would govern the project's other apps too.
  plan.apps = [...new Set(apps.map((a) => posix(a).replace(/\/$/, '')))]
  for (const a of plan.apps) if (!P.workspaces.includes(a)) plan.problems.push(`\`${a}\` is not a workspace of this project — name the app the pieces are for as the root package.json declares it (${P.workspaces.join(', ')})`)
  plan.project = P
  return plan
}

/**
 * Where each role this project lacks still shows in the installed files: a file using one
 * of the role's classes that this project's own build makes no rule of. A class this
 * project defines for itself — its own type role, its own named gap — is fitted already.
 * `makesRule(file, class)` is that build's answer.
 */
export function roleWork(plan, makesRule) {
  const P = plan.project
  const landed = installedFiles(P.repo).filter((i) => isCode(i.file)).map((i) => [i.file, new Set(read(path.join(P.repo, i.file)).split(/[\s"'`]+/).map((c) => c.split(':').pop().replace(/^!|!$/g, '')))])
  for (const r of plan.roles) {
    if (r.present) continue
    r.still = landed.filter(([file, words]) => r.classes.some((c) => words.has(c) && !makesRule(file, c))).map(([f]) => f)
  }
  return plan
}

/** What stops a plan being applied: each thing only a person can answer. */
export function blockers(plan) {
  const out = [...plan.problems]
  const rules = plan.references.filter((r) => !r.installed)
  if (rules.length && !plan.apps?.length) out.push(`${rules.length} recipe(s) and behaviour rule(s) land, and no app is named: each governs every app of this project unless it names the ones it is for — pass \`--app <workspace>\` for each app taking the pieces`)
  for (const b of plan.beside) {
    const at = `${b.piece}/${b.file} would stand beside this project's ${b.existing} (${b.why}), imported by ${b.usedBy.length} file(s)`
    const offered = b.dest === b.existing ? ['use-existing', 'replace'] : ['use-existing', 'replace', 'keep-both']
    if (!['use-existing', 'replace', 'keep-both'].includes(b.answer)) out.push(`${at} — answer ${offered.map((o) => `\`${o}\``).join(' or ')} for \`${b.file}\` under \`beside\``)
    else if (b.answer === 'keep-both' && b.dest === b.existing) out.push(`${at} — both cannot be kept at ${b.dest}: answer \`use-existing\` or \`replace\``)
  }
  for (const e of plan.expected) {
    if (!e.found) out.push(`${e.pieces.join(', ')} expect${e.pieces.length === 1 ? 's' : ''} this project to have \`${e.name}\` (${e.exports.join(', ')}), and no file here is it — build it, or name the file that stands in for \`${e.file}\` under \`standIn\``)
  }
  return out
}

// ─── applying it ─────────────────────────────────────────────────────────────

/** A code file as it lands: imports rewritten, pending, and pointing at its pack file. */
export function landedCode(file, version) {
  let text = file.text
  for (const e of [...file.edits].sort((a, b) => b.start - a.start)) text = text.slice(0, e.start) + e.spec + text.slice(e.end)
  const pointer = `// ui-pack: ${file.piece}/${file.file} @ ${version}`
  const lines = text.split('\n')
  const status = lines.findIndex((l, i) => i < 12 && /ui-status:\s*[A-Za-z-]+/.test(l))
  if (status === -1) return `${pointer}\n${text}`
  lines[status] = lines[status].replace(/ui-status:\s*[A-Za-z-]+/, 'ui-status: pending')
  lines.splice(status + 1, 0, pointer)
  return lines.join('\n')
}

/**
 * A reference as it lands: approved, as it was where it was proven; governing the apps the
 * pieces are for; its code where the code landed; pointing at its pack file. A recipe
 * names its reference screen once this project has built a real screen of the type.
 */
export function landedReference(ref, version, apps = []) {
  const m = ref.text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) return ref.text
  const lines = m[1].split('\n').flatMap((line) => {
    if (/^ui-status:/.test(line)) return ['ui-status: approved']
    if (/^(pack|reference|apps):/.test(line)) return []
    if (/^code:/.test(line)) return [`code: [${ref.code.filter((c) => c.dest).map((c) => c.dest).join(', ')}]`]
    return [line]
  })
  if (!lines.some((l) => l.startsWith('ui-status:'))) lines.push('ui-status: approved')
  // The apps it governs here: the ones the pieces were installed for.
  if (apps.length) lines.push(`apps: [${apps.join(', ')}]`)
  lines.push(`pack: ${ref.piece}/${ref.file} @ ${version}`)
  return `---\n${lines.join('\n')}\n---${ref.text.slice(m[0].length)}`
}

/**
 * A piece's inventory tables as they land: a component's line pending, a recipe's or rule's approved, each table in the region
 * its rows belong to. `landed(name)` says what a line's file is called here — its name,
 * a note for its description — or null when nothing of it was copied.
 */
export function landedInventory(inventory, pieceInventory, kindOf, landed = (name) => ({ name })) {
  const tables = pieceInventory.split(/\n\s*\n/).map((t) => t.trim()).filter((t) => t.startsWith('|'))
  let out = inventory
  for (const table of tables) {
    const [head, rule, ...body] = table.split('\n')
    const rows = body.flatMap((line) => {
      const name = line.match(/`([^`]+)`/)?.[1] ?? ''
      const here = landed(name)
      if (!here) return []
      const cells = line.split('|')
      cells[1] = cells[1].replace(`\`${name}\``, `\`${here.name}\``)
      if (here.note && cells.length > 3) cells[2] = `${cells[2].trimEnd()} ${here.note} `
      // A component wears this project's look, so it waits on the human; a recipe or rule
      // is instruction proven where it came from, and lands approved.
      const status = name.endsWith('.md') ? 'approved' : 'pending'
      return [cells.join('|').replace(/\|\s*(approved|pending|deferred(?:\s+`[0-9a-f]{8}`)?)\s*\|\s*$/, `| ${status} |`)]
    })
    if (!rows.length) continue
    const first = rows[0].match(/`([^`]+)`/)?.[1] ?? ''
    const region = first.endsWith('.md') ? (kindOf(first) === 'recipe' ? 'recipes' : 'behaviour-rules') : 'components'
    const end = `<!-- project:end ${region} -->`
    const block = `\n${[head, rule, ...rows].join('\n')}\n`
    out = out.includes(end) ? out.replace(end, `${block}${end}`) : `${out.replace(/\n*$/, '\n')}${block}`
  }
  return out
}

/** Copy what a plan lists. Refuses while anything in it waits on a person. */
export function applyInstall(repo, plan) {
  const waiting = blockers(plan)
  if (waiting.length) return { written: [], problems: waiting }
  const root = fs.realpathSync(repo)
  const written = []
  const write = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(root, rel)), { recursive: true })
    fs.writeFileSync(path.join(root, rel), text)
    written.push(rel)
  }
  // A file an earlier install landed is the project's now, fitted since: it is left alone.
  const fresh = plan.files.filter((f) => !f.installed)
  const freshPieces = new Set(fresh.map((f) => f.piece))
  for (const f of fresh) write(f.dest, isCode(f.file) ? landedCode(f, plan.version) : f.text)
  const kinds = new Map()
  for (const r of plan.references) {
    kinds.set(path.basename(r.file), (frontmatter(r.text) ?? {}).kind)
    if (r.installed) continue
    freshPieces.add(r.piece)
    write(r.dest, landedReference(r, plan.version, plan.apps ?? []))
  }
  // A rule already here gains each carrier that has just landed as its code.
  for (const f of fresh.filter((x) => isCode(x.file))) {
    const h = headers(f.text)
    for (const rule of [...h.behaviour, ...h.behaviourCode]) {
      const at = `${REFERENCES}/${rule}`
      if (written.includes(at) || !fs.existsSync(path.join(root, at))) continue
      const text = read(path.join(root, at))
      const code = listOf((frontmatter(text) ?? {}).code)
      if (!code.includes(f.dest)) write(at, text.replace(/^code:.*$/m, `code: [${[...code, f.dest].join(', ')}]`))
    }
  }
  // A file of the project's own the pieces now use as a rule's code points back at the rule.
  for (const r of plan.references) {
    for (const c of r.code) {
      if (!c.dest || written.includes(c.dest) || !isCode(c.dest) || !fs.existsSync(path.join(root, c.dest))) continue
      const text = read(path.join(root, c.dest))
      const rule = path.basename(r.file)
      const h = headers(text)
      if ([...h.behaviour, ...h.behaviourCode].includes(rule)) continue
      const word = isComponent(c.dest) ? 'ui-behaviour' : 'ui-behaviour-code'
      const lines = text.split('\n')
      const has = lines.findIndex((l, i) => i < 12 && l.trim().startsWith(`// ${word}:`))
      if (has !== -1) lines[has] = `${lines[has].trimEnd()}, ${rule}`
      else lines.splice(lines.findIndex((l, i) => i < 12 && /ui-status:/.test(l)) + 1, 0, `// ${word}: ${rule}`)
      write(c.dest, lines.join('\n'))
    }
  }
  // A file of the project's own standing in for a pack file says so in its opening lines:
  // what it exports for the pieces is their interface, not something left behind.
  for (const s of plan.standsIn ?? []) {
    if (!isCode(s.file) || !fs.existsSync(path.join(root, s.file))) continue
    const mark = `// ui-pack-for: ${s.piece}/${s.packFile}`
    const text = read(path.join(root, s.file))
    const lines = text.split('\n')
    if (lines.slice(0, 20).some((l) => l.trim() === mark)) continue
    lines.splice(lines.findIndex((l, i) => i < 12 && /ui-status:/.test(l)) + 1, 0, mark)
    write(s.file, lines.join('\n'))
  }
  // An inventory line names its file as it landed, by enough of its path to be the only
  // one of that name, and a line of the project's own that shared the name gains its path.
  const P = plan.project
  const components = P.sources.filter(isComponent)
  const pathName = (f) => f.replace(/\.tsx$/, '')
  const at = path.join(root, INVENTORY)
  let inventory = fs.existsSync(at) ? read(at) : ''
  const renamed = new Map()
  const landedAs = (name) => {
    if (name.endsWith('.md')) return written.includes(`${REFERENCES}/${name.split('/').at(-1)}`) ? { name } : null
    const want = key(name.split('/').at(-1))
    const file = fresh.find((f) => isComponent(f.dest) && key(stemOf(f.file)) === want && (!name.includes('/') || key(f.file).endsWith(key(name))))
    if (!file) return null
    const others = components.filter((c) => c !== file.dest && key(stemOf(c)) === key(stemOf(file.dest)))
    for (const o of others) renamed.set(`\`${stemOf(o)}\``, `\`${pathName(o)}\``)
    const kept = plan.beside.find((b) => b.file === file.file && b.answer === 'keep-both')
    return { name: others.length ? pathName(file.dest) : stemOf(file.dest), note: kept ? `Kept beside \`${stemOf(kept.existing)}\`${kept.reason ? `: ${kept.reason}` : ''}.` : '' }
  }
  for (const i of plan.inventory.filter((x) => freshPieces.has(x.piece))) inventory = landedInventory(inventory, i.text, (name) => kinds.get(name), landedAs)
  inventory = inventory
    .split('\n')
    .map((line) => {
      const cell = line.trimStart().startsWith('|') ? line.split('|')[1]?.trim() : null
      return renamed.has(cell) ? line.replace(cell, renamed.get(cell)) : line
    })
    .join('\n')
  write(INVENTORY, inventory)
  return { written, problems: [] }
}

// ─── what a pack has changed since ───────────────────────────────────────────

/** Every file of this project that points at a pack file: `{ file, piece, packFile, version }`. */
/**
 * The roles the pack carries that this project already has at another value: the one fit
 * an install never makes. Each is the human's, put in the pack's own reason. Values are
 * compared as what they come to — `var(--step-14)` and `0.875rem` are both 14px — one
 * property at a time, and a property either side cannot resolve is left out: the pack
 * carries no value for what it rests on.
 */
export function carriedHere(plan) {
  const here = valuesOf(plan.project?.css ?? [])
  const pack = new Map(plan.roles.filter((r) => r.value).map((r) => [r.name, r.value]))
  const parts = (value, vars) => {
    const one = (v) => toPx(resolveVars(v.trim(), vars))
    if (!/^[a-z-]+\s*:/.test(value)) return new Map([['', one(value)]])
    return new Map(value.split(';').map((d) => d.trim()).filter(Boolean).map((d) => [d.slice(0, d.indexOf(':')).trim(), one(d.slice(d.indexOf(':') + 1))]))
  }
  const unresolved = (v) => v === undefined || v.includes('<undefined') || v.includes('var(')
  const out = []
  for (const r of plan.roles) {
    if (!r.present || !r.value || !here.has(r.name)) continue
    const theirs = parts(r.value, pack)
    const ours = parts(here.get(r.name), here)
    const differs = [...theirs].filter(([prop, v]) => !unresolved(v) && !unresolved(ours.get(prop)) && ours.get(prop) !== v)
    if (differs.length) out.push({ name: r.name, pack: differs.map(([prop, v]) => `${prop ? `${prop} ` : ''}${v}`).join(', '), here: differs.map(([prop]) => `${prop ? `${prop} ` : ''}${ours.get(prop)}`).join(', '), why: r.why })
  }
  return out
}

/**
 * Whether the project is ready to take a piece: every layer finished beneath it. The token
 * check runs over the whole project with the vendored atoms read whatever the project's
 * setting, and the status check with it. A file a pack already landed is this install's own
 * work, and so is what waits on the human once an install is under way; everything else
 * that either check names refuses the install.
 */
export async function compliance(repo, { tokens = checkDesignTokens, status = checkUiStatus } = {}) {
  const read = readKeys(repo)
  if (read.notApplicable) return { problems: [`a piece is installed into a UI package: ${read.notApplicable}`], notes: [] }
  if (!read.keys) return { problems: read.problems, notes: [] }
  const landed = installedFiles(repo).map((f) => f.file)
  const ours = (line) => landed.some((f) => line.startsWith(`${f}:`) || line.startsWith(`${f} `))
  const t = await tokens(repo, { all: true, keys: { ...read.keys, DESIGN_VENDORED_RESTYLED: 'true' } })
  const s = status(repo)
  const problems = []
  for (const p of t.problems.filter((x) => !ours(x))) problems.push(`token check: ${p}`)
  for (const p of (s.problems ?? []).filter((x) => !ours(x))) problems.push(`status check: ${p}`)
  if (!landed.length) for (const p of s.pending ?? []) problems.push(`awaiting the human's approval: ${p}`)
  const notes = [
    `token check: ${t.counts ? `${t.counts.sourceFiles} source file(s) and ${t.counts.classesChecked} classes, the vendored atoms read` : 'nothing scanned'}`,
    `status check: ${s.counts ? `${s.counts.components} component(s), ${s.counts.references} reference(s) and ${s.counts.screens} screen(s)` : (s.notApplicable ?? 'nothing scanned')}`,
    ...(landed.length ? [`${landed.length} file(s) a pack already landed are this install's own work, and what waits on the human is not counted while it is under way`] : []),
  ]
  if (!t.counts && !t.problems.length) problems.push('token check: it scanned nothing, so the project cannot be shown ready')
  return { problems, notes }
}

/**
 * Approve everything a Design Pack installed here, on the human's word: they have reviewed
 * the roles it brought and looked over its reference pages as a whole. Every installed file
 * still pending becomes approved, with its inventory line, and the judge's ledger loses each
 * item resting on one of those files. A piece the human set aside stays set aside, and an
 * item about a role stays: a role is answered where it is reviewed, on its own line.
 */
export function approveInstalled(repo) {
  const root = fs.realpathSync(repo)
  // What a pack installed, and each file of the project's own that stands in for a pack
  // file: it was fitted for the pieces in the same install.
  const landed = [...installedFiles(repo), ...standingIn(repo)]
  if (!landed.length) return { problems: ['no file in this project carries a Design Pack pointer — there is nothing installed to approve'] }
  const at = (f) => path.join(root, f)
  const files = []
  for (const i of landed) {
    const text = read(at(i.file))
    const head = text.split('\n')
    const n = head.slice(0, 20).findIndex((l) => /ui-status:\s*pending\b/.test(l))
    if (n === -1) continue
    head[n] = head[n].replace(/ui-status:\s*pending\b/, 'ui-status: approved')
    fs.writeFileSync(at(i.file), head.join('\n'))
    files.push(i.file)
  }
  // The inventory line of each: by its name, and by its path where the line gives one.
  const stems = new Map()
  for (const i of landed) stems.set(key(stemOf(i.file)), [...(stems.get(key(stemOf(i.file))) ?? []), i.file])
  let lines = 0
  if (fs.existsSync(at(INVENTORY))) {
    const inventory = read(at(INVENTORY)).split('\n').map((line) => {
      const name = line.match(/^\|\s*`([^`]+)`/)?.[1]
      if (!name || !/\|\s*pending\s*\|\s*$/.test(line)) return line
      const mine = stems.get(key(name.split('/').at(-1).replace(/\.md$/, ''))) ?? []
      if (!mine.length || (name.includes('/') && !mine.some((f) => f.replace(/\.[a-z]+$/, '').endsWith(name.replace(/\.[a-z]+$/, ''))))) return line
      lines++
      return line.replace(/\|\s*pending\s*\|\s*$/, '| approved |')
    })
    if (lines) fs.writeFileSync(at(INVENTORY), inventory.join('\n'))
  }
  const mine = new Set(landed.map((i) => i.file))
  let cleared = 0
  let kept = 0
  if (fs.existsSync(at(LEDGER))) {
    const ledger = JSON.parse(read(at(LEDGER)))
    const stays = ledger.filter((item) => {
      const file = String(item.at ?? '').replace(/:\d+$/, '')
      const ours = mine.has(file) || (Array.isArray(item.rests) && item.rests.length > 0 && item.rests.every((r) => mine.has(r.file)))
      if (ours) cleared++
      else kept++
      return !ours
    })
    if (cleared) fs.writeFileSync(at(LEDGER), `${JSON.stringify(stays, null, 2)}\n`)
  }
  return { problems: [], installed: landed.length, files, lines, cleared, kept }
}

/** The project's own files that stand in for a pack file: `// ui-pack-for: <piece>/<file>`. */
export function standingIn(repo) {
  const root = fs.realpathSync(repo)
  const files = execFileSync('git', ['-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.ts', '*.tsx'], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).split('\0').filter(Boolean)
  const out = []
  for (const f of files) {
    if (!fs.existsSync(path.join(root, f))) continue
    const m = read(path.join(root, f)).split('\n').slice(0, 20).join('\n').match(/^\/\/ ui-pack-for:\s*(\S+?)\/(\S+)/m)
    if (m) out.push({ file: f, piece: m[1], packFile: m[2] })
  }
  return out
}

export function installedFiles(repo) {
  const root = fs.realpathSync(repo)
  const files = execFileSync('git', ['-C', root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.ts', '*.tsx', `${REFERENCES}/*.md`], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }).split('\0').filter(Boolean)
  const out = []
  for (const f of files) {
    if (!fs.existsSync(path.join(root, f))) continue
    const head = read(path.join(root, f)).split('\n').slice(0, 20).join('\n')
    const m = head.match(f.endsWith('.md') ? REFERENCE_POINTER : POINTER)
    if (m) out.push({ file: f, piece: m[1], packFile: m[2], version: m[3] })
  }
  return out
}

/**
 * What the pack has changed in each installed file's pack file since the version the file
 * points at: `{ file, piece, packFile, version, now, diff }`, `diff` empty when nothing has.
 * `only` limits it to one of this project's files.
 */
export function compare(repo, from, only = null) {
  const pack = readPack(from)
  const rel = posix(path.relative(pack.root, pack.pieces))
  const git = (...args) => execFileSync('git', ['-C', pack.root, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] })
  const out = []
  const problems = []
  let read = 0
  for (const i of installedFiles(repo)) {
    if (only && posix(path.relative(fs.realpathSync(repo), path.resolve(only))) !== i.file && only !== i.file) continue
    read++
    const at = posix(path.join(rel, i.piece, i.packFile))
    try {
      // Against the checkout as it stands, so a change not yet committed there shows too.
      const diff = git('diff', i.version, '--', at)
      const held = git('ls-tree', '-r', '--name-only', i.version, '--', at).trim()
      if (!held) problems.push(`${i.file}: the pack at ${i.version} does not hold ${i.piece}/${i.packFile} — the packs checkout had not committed it when this was installed, so what has changed since cannot be shown until it is committed there and this file's pointer names that version`)
      else out.push({ ...i, now: pack.version, diff })
    } catch (err) {
      problems.push(`${i.file}: points at ${i.piece}/${i.packFile} @ ${i.version}, which the pack's history does not hold (${String(err.stderr ?? err.message).split('\n')[0]})`)
    }
  }
  // Comparing nothing is a failure to compare, never a pass.
  if (!read) problems.push(only ? `${only} is not a file a pack installed in ${repo} — name an installed file by its path` : `no file in ${repo} carries a pack pointer — nothing was compared`)
  return { files: out, problems, read }
}
