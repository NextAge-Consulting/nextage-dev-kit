#!/usr/bin/env node
/**
 * The locator: every candidate the judge is asked about, found by code that never decides.
 *
 *   node .claude/skills/design-system/scripts/locate.mjs [--base <ref>]        the change since <ref>
 *   node .claude/skills/design-system/scripts/locate.mjs --all [--layer <l>]  everything, one layer
 *
 * Prints one JSON object per line. A `question` line is a candidate for one judge
 * question (references/judge-questions.md) with the fields that question is Given, and
 * `at` (file:line) for the pending item a yes becomes. A FOLLOWS-RULE line also carries
 * `about` (the rule's file) and `anchor` — the screen's changed lines, the only lines a yes
 * may rest on; the judge places the item on the one its evidence quotes. A `finding` line
 * is decided by code alone — a second block of one type — and needs no judge.
 *
 * The change mode reads the lines changed since <ref> (default: where this work left
 * origin/main, else HEAD) in the UI source the DESIGN_* keys name, the token stylesheets
 * and the references, and locates only in them. A changed source line that is only a
 * comment, or part of an import that binds names, is not a change, and a file with no
 * other change is untouched: a header, a pointer or an import added to every file judges
 * nothing. `--all` reads a whole layer: tokens,
 * components, references or screens (default every layer).
 *
 * What is mechanical stays mechanical: a colour or fixed height at a call site, a role
 * named with a t-shirt size, a frame atom in a screen, are the token checker's and are not
 * candidates here. Placement classes a screen may always write (margin, width, a flex or
 * grid share, position) are not candidates either.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, globSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { readBlockTypes } from './block-types.mjs'
import { ALL, changedLines, classText, constantClasses, loadTypeScript, openingTags, purposesOf, readKeys, rolesOf, screenBase } from './check-design-tokens.mjs'
import { uiSourceDirs, workspaceDirs } from './ui-sources.mjs'
import { appOf, catalogueRows, frontmatter, headers, isComponent, isScreen, key, lineCode, listOf } from '../../ui-patterns/scripts/check-ui-status.mjs'

const REFERENCES = '.claude/skills/ui-patterns/references'
const INVENTORY = '.claude/rules/project/ui-inventory.md'
export const LAYERS = ['tokens', 'components', 'references', 'screens']
const posix = (p) => p.split(path.sep).join('/')

/** Placement a screen may always write: never a REPAINT candidate. */
const PLACEMENT = /^(?:-?m[xytrblse]?-|w-|min-w-|max-w-|max-h-|min-h-|basis-|grow|shrink|flex(?:-|$)|grid(?:-|$)|col-|row-|order-|self-|place-self|justify-self|absolute|relative|fixed|sticky|static|inset-|top-|right-|bottom-|left-|z-|hidden|block|inline|contents|invisible|visible|sr-only|text-(?:left|right|center|start|end)|truncate|overflow-hidden|aspect-|float-|clear-)/
/** A class that paints a colour or fixes a size — the token checker's — never REPAINT's. */
const MECHANICAL = /^(?:(?:text|bg|border|ring|outline|fill|stroke)-[a-z]|h-|size-)/
/** A box a screen draws: the classes that start SCREEN-BOX. */
const BOX = /^(?:bg-|border(?:$|-(?!b$|t$|l$|r$|x$|y$|none$))|rounded(?:$|-)|shadow(?:$|-)|p[xytrbl]?-)/

/** Lines changed since `base` in files matching the git pathspecs, plus whole new files. */
function changedIn(repo, base, pathspecs) {
  const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  const out = new Map()
  let file = null
  for (const line of git('diff', '-M', '-U0', '--no-color', base, '--', ...pathspecs).split('\n')) {
    if (line.startsWith('+++ ')) file = line.slice(4).replace(/^b\//, '')
    const m = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/)
    if (!m || !file || file === '/dev/null') continue
    if (!out.has(file)) out.set(file, new Set())
    for (let n = Number(m[1]), end = n + Number(m[2] ?? 1); n < end; n++) out.get(file).add(n)
  }
  for (const f of git('ls-files', '--others', '--exclude-standard', '--', ...pathspecs).split('\n')) if (f) out.set(f, ALL)
  return out
}

/** A source line that is only a comment: a line comment, a one-line block comment, or a line inside a block comment. */
const isComment = (line) => lineCode(line) === '' || /^\s*(?:\/\*|\*)/.test(line)

/**
 * The lines of a file's imports that bind names. Such an import draws nothing and does
 * nothing until a line uses the name, and that line is a change of its own. An import for
 * its effect alone (`import './x.css'`) is code like any other.
 */
function importLines(repo, file, text) {
  const ts = loadTypeScript(repo)
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, false, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  const out = new Set()
  for (const s of sf.statements) {
    if (!ts.isImportDeclaration(s) || !s.importClause) continue
    const from = sf.getLineAndCharacterOfPosition(s.getStart(sf)).line + 1
    const to = sf.getLineAndCharacterOfPosition(s.end).line + 1
    for (let n = from; n <= to; n++) out.add(n)
  }
  return out
}

/**
 * The changed lines that carry code. A TypeScript line whose change is a comment, or part
 * of an import that binds names, is not a change, and a file left with none is untouched.
 * Stylesheets and references are kept whole: a token's purpose comment and a rule's prose
 * are their content.
 */
function codeChanges(repo, changed) {
  const out = new Map()
  for (const [file, lines] of changed) {
    if (lines === ALL || !/\.tsx?$/.test(file)) {
      out.set(file, lines)
      continue
    }
    let source
    try {
      source = readFileSync(path.join(repo, file), 'utf8')
    } catch {
      continue
    }
    const text = source.split('\n')
    const imports = importLines(repo, file, source)
    const kept = new Set([...lines].filter((n) => !isComment(text[n - 1] ?? '') && !imports.has(n)))
    if (kept.size) out.set(file, kept)
  }
  return out
}

/** Everything the locator reads about a repository, once. */
export function readRepo(repo, { base = null, all = false } = {}) {
  const { keys, problems, notApplicable } = readKeys(repo)
  if (notApplicable) return { notApplicable }
  if (problems.length) return { problems }
  const pkgRel = keys.DESIGN_UI_PACKAGE.replace(/\/$/, '')
  const { dirs, problems: sourceProblems } = uiSourceDirs(repo, pkgRel)
  if (sourceProblems.length) return { problems: sourceProblems }
  const workspaces = workspaceDirs(repo).dirs
  const styleRels = [...new Set([...keys.DESIGN_TOKEN_FILES.split(/\s+/), keys.DESIGN_TYPE_FILE, keys.DESIGN_STYLES_FILE].filter(Boolean).map((r) => posix(path.join(pkgRel, r))))]
  const css = styleRels.filter((s) => existsSync(path.join(repo, s))).map((s) => [s, readFileSync(path.join(repo, s), 'utf8').replace(/\r\n/g, '\n')])
  const vendored = keys.DESIGN_VENDORED_DIR ? `${keys.DESIGN_VENDORED_DIR.replace(/\/$/, '')}/` : null
  const isAtomFile = (f) => (vendored ? f.startsWith(vendored) : f.includes('components/ui/'))
  const sourceFiles = [...new Set(dirs.flatMap((d) => globSync(`${d}/**/*.{ts,tsx}`, { cwd: repo }).map(posix)))].filter((f) => !/\.(test|spec|stories|d)\.tsx?$/.test(f) && !/\.(gen|generated)\.ts$/.test(f) && !f.includes('/node_modules/'))
  const sources = new Map(sourceFiles.map((f) => [f, readFileSync(path.join(repo, f), 'utf8').replace(/\r\n/g, '\n')]))
  const refDir = path.join(repo, REFERENCES)
  const references = existsSync(refDir) ? globSync('*.md', { cwd: refDir }).filter((f) => f !== 'README.md').sort().map((f) => `${REFERENCES}/${f}`) : []
  const refs = new Map(references.map((f) => [f, readFileSync(path.join(repo, f), 'utf8').replace(/\r\n/g, '\n')]))
  const inventory = existsSync(path.join(repo, INVENTORY)) ? readFileSync(path.join(repo, INVENTORY), 'utf8') : ''
  const rows = catalogueRows(inventory)
  const inventoryLines = inventory.split('\n')
  let types
  try {
    types = readBlockTypes()
  } catch {
    types = { names: new Set(), neighbours: new Map(), definitions: new Map() }
  }
  let changed = null
  if (!all) {
    const ref = screenBase(repo, base) ?? 'HEAD'
    changed = codeChanges(repo, new Map([...changedLines(repo, ref), ...changedIn(repo, ref, ['*.css', '*.md'])]))
  }
  return { repo, keys, pkgRel, dirs, workspaces, css, sources, refs, rows, inventoryLines, types, changed, isAtomFile }
}

const touched = (R, file, from, to = from) => {
  if (!R.changed) return true
  const lines = R.changed.get(file)
  if (!lines) return false
  if (lines === ALL) return true
  for (let n = from; n <= to; n++) if (lines.has(n)) return true
  return false
}
const fileTouched = (R, file) => !R.changed || R.changed.has(file)
const isNew = (R, file) => !!R.changed && R.changed.get(file) === ALL

/** The inventory row and line for a component file, by the catalogue's name matching. */
function rowFor(R, file) {
  const parts = file.split('/')
  const base = parts.at(-1).replace(/\.tsx$/, '')
  const k = key(base === 'index' ? parts.at(-2) : base)
  const row = R.rows.find((r) => !r.name.endsWith('.md') && key(r.name.split('/').at(-1)) === k)
  return row ? { row, line: R.inventoryLines[row.line - 1] ?? '' } : { row: null, line: '' }
}
const componentName = (R, file) => {
  const src = R.sources.get(file) ?? ''
  const m = src.match(/export\s+(?:default\s+)?(?:function|const)\s+([A-Z]\w*)/)
  return m?.[1] ?? path.basename(file, '.tsx')
}
const blockType = (R, file) => headers(R.sources.get(file) ?? '').block ?? rowFor(R, file).row?.type ?? null
const summary = (src, lines = 40) => src.split('\n').filter((l) => !/^\s*(\/\/|\/\*|\*)/.test(l)).slice(0, lines).join('\n')
const context = (src, line, around) => src.split('\n').slice(Math.max(0, line - 1 - around), line + around).join('\n')

// ─── tokens ────────────────────────────────────────────────────────────────

/** Every role token and type utility with its purpose, value and place. */
function roles(R) {
  const purposes = purposesOf(R.css)
  const out = []
  const seen = new Set()
  for (const [file, src] of R.css) {
    src.split('\n').forEach((line, i) => {
      const d = line.match(/^\s*(--(?:radius|font-weight|shadow|spacing|leading|tracking)-[a-z0-9-]+)\s*:\s*([^;]+);/)
      // A theme re-export (`--radius-x: var(--radius-x)`) is the same role again, not a second one.
      if (d && d[2].trim() !== `var(${d[1]})` && !seen.has(d[1])) {
        seen.add(d[1])
        out.push({ name: d[1], family: d[1].match(/^--([a-z-]+?)-[a-z0-9]/)[1], purpose: purposes.get(d[1]) ?? '', value: d[2].trim(), file, line: i + 1 })
      }
      const u = line.match(/^\s*@utility\s+(type-[a-z0-9-]+)\s*\{/)
      if (u) out.push({ name: u[1], family: 'type', purpose: purposes.get(u[1]) ?? '', value: context(src, i + 1, 4), file, line: i + 1 })
    })
  }
  return out
}

function* tokens(R) {
  const all = roles(R)
  for (const r of all) {
    if (!touched(R, r.file, r.line)) continue
    yield { question: 'ROLE-NAME', at: `${r.file}:${r.line}`, candidate: { name: r.name, purpose: r.purpose, value: r.value } }
  }
  const byFamily = new Map()
  for (const r of all) byFamily.set(r.family, [...(byFamily.get(r.family) ?? []), r])
  for (const list of byFamily.values()) {
    for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i]
        const b = list[j]
        if (!touched(R, a.file, a.line) && !touched(R, b.file, b.line)) continue
        if (!a.purpose && !b.purpose) continue
        yield { question: 'DUPLICATE-ROLE', at: `${b.file}:${b.line}`, candidate: { a: { name: a.name, purpose: a.purpose, value: a.value }, b: { name: b.name, purpose: b.purpose, value: b.value } } }
      }
    }
  }
}

// ─── classes at use: the token used against its purpose ──────────────────

/** The token a class names, when the stylesheets define it as a role with a purpose. */
function tokenOf(cls, rolesOfCss, purposes) {
  const base = cls.split(':').pop().replace(/\/\d+$/, '')
  let m
  if ((m = base.match(/^(?:text|bg|border|ring|outline|fill|stroke|divide|accent)-(.+)$/)) && rolesOfCss.colours.has(m[1])) return `--color-${m[1]}`
  if ((m = base.match(/^rounded(?:-[a-z]{1,2})?-(.+)$/)) && rolesOfCss.radiusRoles.has(m[1])) return `--radius-${m[1]}`
  if ((m = base.match(/^shadow-(.+)$/)) && rolesOfCss.shadowRoles.has(m[1])) return `--shadow-${m[1]}`
  if ((m = base.match(/^font-(.+)$/)) && rolesOfCss.weightRoles.has(m[1])) return `--font-weight-${m[1]}`
  if ((m = base.match(/^(?:p|px|py|pt|pb|pl|pr|m|mx|my|mt|mb|ml|mr|gap|gap-x|gap-y|w|h|size)-(.+)$/)) && rolesOfCss.spacingAliases.has(m[1])) return `--spacing-${m[1]}`
  if (rolesOfCss.typeRoles.has(base)) return base
  return purposes.has(`--${base}`) ? `--${base}` : null
}

function* tokenUses(R, files, where) {
  const r = rolesOf(R.css)
  const purposes = purposesOf(R.css)
  for (const file of files) {
    const src = R.sources.get(file) ?? R.refs.get(file)
    if (!src) continue
    const classLines = (R.sources.has(file) ? classText(src) : src).split('\n')
    const lines = src.split('\n')
    const seen = new Set()
    for (let i = 0; i < classLines.length; i++) {
      if (!touched(R, file, i + 1)) continue
      for (const raw of classLines[i].split(/\s+/).filter(Boolean)) {
        const cls = raw.replace(/^["'`]+|["'`,]+$/g, '')
        const token = tokenOf(cls, r, purposes)
        if (!token) continue
        const purpose = purposes.get(token)
        if (!purpose) continue
        if (R.changed === null && seen.has(cls)) continue
        seen.add(cls)
        yield { question: 'TOKEN-AGAINST-PURPOSE', at: `${file}:${i + 1}`, candidate: { token: cls, purpose, line: lines[i], where: `${where} ${file}`, context: context(src, i + 1, 5) } }
      }
    }
  }
}

// ─── components ──────────────────────────────────────────────────────────

/** Project components by the name they are imported as, with their file. */
function componentIndex(R) {
  const byName = new Map()
  for (const file of R.sources.keys()) {
    if (!isComponent(file)) continue
    const src = R.sources.get(file)
    for (const m of src.matchAll(/export\s+(?:default\s+)?(?:function|const|class)\s+([A-Z]\w*)/g)) byName.set(m[1], file)
    for (const m of src.matchAll(/export\s+\{([^}]+)\}/g)) for (const n of m[1].split(',')) {
      const id = n.trim().split(/\s+as\s+/).pop()
      if (/^[A-Z]/.test(id) && !byName.has(id)) byName.set(id, file)
    }
  }
  return byName
}

/** Every use of a project component across the sources: { file, line, name, tag, classes, variant }. */
function callSites(R, index) {
  const out = []
  const exported = new Map()
  for (const [, s] of R.sources) constantClasses(s, exported)
  for (const [file, src] of R.sources) {
    const consts = constantClasses(src)
    for (const t of openingTags(src, /<([A-Z][\w.]*)\b/g)) {
      const target = index.get(t.name)
      if (!target || target === file) continue
      const classes = [...t.classes, ...t.ids.flatMap((id) => consts.get(id) ?? exported.get(id) ?? [])]
      const variant = t.open.match(/\svariant=(?:"([^"]+)"|\{\s*["']([^"']+)["']\s*\})/)
      out.push({ file, line: t.line, name: t.name, target, tag: t.open.split('\n')[0], classes, variant: variant?.[1] ?? variant?.[2] ?? 'default' })
    }
  }
  return out
}

function* components(R) {
  const index = componentIndex(R)
  const sites = callSites(R, index)
  const blocks = [...R.sources.keys()].filter((f) => isComponent(f) && !R.isAtomFile(f))
  const usedBy = (file) => [...new Set(sites.filter((s) => s.target === file).map((s) => s.file))]

  for (const file of blocks) {
    if (!fileTouched(R, file)) continue
    const src = R.sources.get(file)
    yield { question: 'NAMED-FOR-DATA', at: `${file}:1`, candidate: { name: componentName(R, file), blockType: blockType(R, file) ?? '(none named)', summary: summary(src), screens: usedBy(file) } }
  }

  // A variant finished by its callers: grouped per component and variant, two or more sites.
  const groups = new Map()
  for (const s of sites) {
    if (!isComponent(s.target)) continue
    const k = `${s.target}\0${s.variant}`
    groups.set(k, [...(groups.get(k) ?? []), s])
  }
  for (const [k, list] of groups) {
    if (list.length < 2) continue
    const [target, variant] = k.split('\0')
    if (!fileTouched(R, target) && !list.some((s) => touched(R, s.file, s.line))) continue
    const definition = classText(R.sources.get(target)).split('\n').map((l) => l.trim()).filter(Boolean).join(' ')
    yield { question: 'VARIANT-INCOMPLETE', at: `${target}:1`, candidate: { component: componentName(R, target), variant, definition, callSites: list.map((s) => `${s.file}:${s.line} ${s.tag}`) } }
  }

  // A new block against its neighbours; a second block of a type is code's finding.
  for (const file of blocks) {
    if (R.changed && !isNew(R, file)) continue
    const type = blockType(R, file)
    const name = componentName(R, file)
    const others = blocks.filter((f) => f !== file)
    const same = others.filter((f) => type && blockType(R, f) === type)
    for (const f of same) {
      const { line } = rowFor(R, f)
      yield { finding: 'SECOND-BLOCK', at: `${file}:1`, text: `${name} is a second block of type ${type}; the first is ${componentName(R, f)} (${f})${line ? ` — its inventory line: ${line.trim()}` : ''}. Same thing: fold in as a variant. Different: the human's reason goes on the new line.` }
    }
    // Neighbours both ways: the types the new one is not to be confused with, and the types
    // that name the new one as theirs.
    const neighbourTypes = new Set(type ? [...(R.types.neighbours.get(type) ?? []), ...[...R.types.neighbours].filter(([, list]) => list.includes(type)).map(([t]) => t)] : [...R.types.names])
    for (const f of others) {
      const t = blockType(R, f)
      if (!t || !neighbourTypes.has(t) || same.includes(f)) continue
      yield {
        question: 'DUPLICATE-BLOCK',
        at: `${file}:1`,
        candidate: {
          new: { name, type: type ?? '(none named)', code: summary(R.sources.get(file), 80) },
          existing: { name: componentName(R, f), type: t, code: summary(R.sources.get(f), 80), inventoryLine: rowFor(R, f).line.trim() },
        },
      }
    }
  }

  yield* tokenUses(R, blocks, 'block')
  yield* repaints(R, sites.filter((s) => isComponent(s.file)))
}

// ─── references ──────────────────────────────────────────────────────────

function refMeta(R) {
  const out = []
  for (const [file, text] of R.refs) {
    const fm = frontmatter(text) ?? {}
    out.push({ file, text, kind: fm.kind ?? null, blockTypes: listOf(fm['block-types']), frame: fm.frame ?? null, raw: fm['block-types'] ?? '', apps: fm.apps === undefined ? null : listOf(fm.apps) })
  }
  return out
}

/** Whether a reference governs a file: it names no apps, the file is in no app, or in one it names. */
function governs(R, ref, file) {
  if (!ref.apps) return true
  const app = appOf(file, R.workspaces)
  return app === null || ref.apps.includes(app)
}
/** Whether two references can meet on one screen: either governs every app, or they share one. */
const shareApp = (a, b) => !a.apps || !b.apps || a.apps.some((x) => b.apps.includes(x))

function* references(R) {
  const refs = refMeta(R)
  const blocks = [...R.sources.keys()].filter((f) => isComponent(f) && !R.isAtomFile(f))
  for (const rule of refs) {
    if (rule.kind !== 'behaviour' || rule.blockTypes.includes('cross-cutting')) continue
    for (const f of blocks) {
      const t = blockType(R, f)
      if (!t || !rule.blockTypes.includes(t) || !governs(R, rule, f)) continue
      if (!fileTouched(R, rule.file) && !fileTouched(R, f)) continue
      yield { question: 'RULE-REACH', at: `${rule.file}:1`, candidate: { rule: rule.text, blockTypes: `block-types: ${rule.raw}`, block: { name: componentName(R, f), type: t, summary: summary(R.sources.get(f)), inventoryLine: rowFor(R, f).line.trim() } } }
    }
  }
  for (let i = 0; i < refs.length; i++) {
    for (let j = i + 1; j < refs.length; j++) {
      const a = refs[i]
      const b = refs[j]
      if (!fileTouched(R, a.file) && !fileTouched(R, b.file)) continue
      // Two references for different apps never meet on a screen.
      if (!shareApp(a, b)) continue
      // A cross-cutting rule governs every surface, so it shares the other rule's surfaces.
      const aAll = a.blockTypes.includes('cross-cutting')
      const bAll = b.blockTypes.includes('cross-cutting')
      const shared = aAll && bAll ? ['every surface'] : aAll ? b.blockTypes : bAll ? a.blockTypes : a.blockTypes.filter((t) => b.blockTypes.includes(t))
      if (!shared.length) continue
      const surface = shared.join(', ')
      yield { question: 'RULE-CONFLICT', at: `${b.file}:1`, candidate: { surface, a: { file: path.basename(a.file), text: a.text }, b: { file: path.basename(b.file), text: b.text } } }
    }
  }
  yield* tokenUses(R, [...R.refs.keys()].filter((f) => fileTouched(R, f)), 'rule')
}

// ─── screens ─────────────────────────────────────────────────────────────

function* repaints(R, sites) {
  for (const s of sites) {
    if (!touched(R, s.file, s.line)) continue
    for (const cls of s.classes) {
      const base = cls.split(':').pop()
      if (PLACEMENT.test(base) || MECHANICAL.test(base)) continue
      yield { question: 'REPAINT', at: `${s.file}:${s.line}`, candidate: { component: s.name, class: cls, tag: s.tag, accepts: [], kind: R.isAtomFile(s.target) || s.target.includes('/components/ui/') ? 'atom' : 'block' } }
    }
  }
}

function* screens(R, only = null) {
  const index = componentIndex(R)
  const sites = callSites(R, index)
  const refs = refMeta(R)
  const files = [...R.sources.keys()].filter((f) => isScreen(f, R.dirs) && (!only || f === only || f.startsWith(`${only.replace(/\/$/, '')}/`)))
  const typesText = [...R.types.definitions].map(([t, d]) => `${t}: ${d}`).join('\n')
  const blockRows = R.inventoryLines.filter((l) => /^\|\s*`/.test(l))
  for (const file of files) {
    if (!fileTouched(R, file)) continue
    const src = R.sources.get(file)
    const h = headers(src)
    const recipe = h.recipe ? refs.find((r) => path.basename(r.file) === h.recipe) : null
    const pageTypes = recipe?.blockTypes ?? []
    const imported = new Set(sites.filter((s) => s.file === file).map((s) => blockType(R, s.target)).filter(Boolean))
    const governing = refs.filter((r) => r === recipe || (r.kind === 'behaviour' && governs(R, r, file) && (r.blockTypes.includes('cross-cutting') || r.blockTypes.some((t) => pageTypes.includes(t) || imported.has(t)))))
    const partial = R.changed && R.changed.get(file) !== ALL
    const screenText = partial ? changedRegion(src, R.changed.get(file), 20) : src
    // The lines a yes may rest on: the changed lines that hold code, or every such line of a
    // new or audited screen. The lines around them are the judge's context and nothing more.
    const all = src.split('\n')
    const scope = partial ? [...R.changed.get(file)].sort((a, b) => a - b) : all.map((_, i) => i + 1)
    const lines = scope.filter((n) => !isComment(all[n - 1] ?? '') && /\w/.test(all[n - 1] ?? '')).map((n) => [n, all[n - 1]])
    if (lines.length)
      for (const r of governing) yield { question: 'FOLLOWS-RULE', at: `${file}:${lines[0][0]}`, about: path.basename(r.file), anchor: { file, lines }, candidate: { rule: r.text, screen: screenText } }

    for (const t of openingTags(src, /<([a-z][\w-]*)\b(?!\.)/g)) {
      if (!touched(R, file, t.line)) continue
      if (!t.classes.some((c) => BOX.test(c.split(':').pop()))) continue
      yield { question: 'SCREEN-BOX', at: `${file}:${t.line}`, candidate: { tag: t.open.split('\n')[0], children: context(src, t.line + 2, 1), file, blockTypes: typesText, blocks: blockRows } }
    }
  }
  yield* repaints(R, sites.filter((s) => files.includes(s.file)))
  yield* tokenUses(R, files, 'screen')
}

/** The changed lines of a file with `around` lines each side, joined; gaps marked. */
function changedRegion(src, lines, around) {
  const all = src.split('\n')
  const keep = new Set()
  for (const n of lines) for (let i = Math.max(1, n - around); i <= Math.min(all.length, n + around); i++) keep.add(i)
  const out = []
  let last = 0
  for (const i of [...keep].sort((a, b) => a - b)) {
    if (last && i !== last + 1) out.push('…')
    out.push(all[i - 1])
    last = i
  }
  return out.join('\n')
}

/** Every candidate for a repository: the change since `base`, or a whole layer. */
export function* locate(R, { layer = null, path: only = null } = {}) {
  if (!layer || layer === 'tokens') yield* tokens(R)
  if (!layer || layer === 'components') yield* components(R)
  if (!layer || layer === 'references') yield* references(R)
  if (!layer || layer === 'screens') yield* screens(R, only)
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  const opt = (k) => {
    const i = argv.indexOf(k)
    return i >= 0 ? argv[i + 1] : undefined
  }
  const repo = path.resolve(opt('--repo') ?? execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim())
  const all = argv.includes('--all')
  const layer = opt('--layer') ?? null
  if (layer && !LAYERS.includes(layer)) {
    console.error(`locate: --layer is one of ${LAYERS.join(', ')}`)
    process.exit(2)
  }
  loadTypeScript(repo)
  const R = readRepo(repo, { base: opt('--base') ?? null, all })
  if (R.notApplicable) {
    console.error(`locate: ${R.notApplicable}`)
    process.exit(0)
  }
  if (R.problems) {
    for (const p of R.problems) console.error(`locate: ${p}`)
    process.exit(1)
  }
  let n = 0
  for (const c of locate(R, { layer, path: opt('--path') ?? null })) {
    console.log(JSON.stringify(c))
    n++
  }
  console.error(`locate: ${n} candidate(s)${all ? ` in ${layer ?? 'every layer'}` : ' in the change'}`)
}
