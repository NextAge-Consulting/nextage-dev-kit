#!/usr/bin/env node
/**
 * The locator: every candidate the judge is asked about, found by code that never decides.
 *
 *   node .claude/skills/design-system/scripts/locate.mjs [--base <ref>]        the change since <ref>
 *   node .claude/skills/design-system/scripts/locate.mjs --all [--layer <l>]  everything, one layer
 *
 * Prints one JSON object per line. A `question` line is a candidate for one judge
 * question (references/judge-questions.md) with the fields that question is Given, and
 * `at` for the pending item a yes becomes: file:line, or the file alone when the question
 * is about a component as a whole. Where one place can hold several
 * candidates of a question, the line carries `about` — the other thing that candidate names:
 * the token, the class, the rule's file, the other role, block or rule — so each yes is its
 * own item and says what it is a yes about; `note` adds what whoever acts on the yes would
 * otherwise look up (a token's purpose). A FOLLOWS-RULE line also carries `anchor` — the
 * screen's changed lines, the only lines a yes may rest on; the judge places the item on the
 * one its evidence quotes. A RULE-REACH or RULE-CONFLICT line carries `sentences` — each
 * rule file with the candidate field that holds its text, and for a conflict the lines of it
 * the change touched — and the judge rests the item on the sentence it quotes from each. A
 * `finding` line is decided by code alone — a second block of one type — and needs no judge.
 *
 * The change mode reads the lines changed since <ref> (default: where this work left
 * origin/main, else HEAD) in the UI source the DESIGN_* keys name, the token stylesheets
 * and the references, and locates only in them. A changed source line that is only a
 * comment, or part of an import that binds names, is not a change; nor is a line whose code
 * the same change removed elsewhere, which only moved. A file with no other change is
 * untouched: a header, a pointer or an import added to every file judges nothing, and so
 * does code moved into another file or a new shared one. A component, recipe or rule the
 * human has answered for — `ui-status: approved` or `deferred` — is not asked about its
 * own contents; a screen's use of it still is. Nor is what a Design Pack installs, in the
 * change that adds it: each file carrying the pack's pointer, and each role those files
 * read that the change declares. `--all` reads a whole layer and asks
 * everything: tokens,
 * components, references or screens (default every layer).
 *
 * Which token a class uses is Tailwind's answer, never a reading of the class's name: each
 * class is compiled by the project's own Tailwind and the custom properties its
 * declarations read are its tokens.
 *
 * What is mechanical stays mechanical: a class a call site adds to a component — a colour,
 * a fixed height, padding, a gap, a border, a radius, a shadow, type — a role named with a
 * t-shirt size, a frame atom in a screen, are the token checker's and are not candidates
 * here.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, globSync, readFileSync, realpathSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { readBlockTypes } from './block-types.mjs'
import { ALL, changedLines, classText, constantClasses, loadTypeScript, openingTags, purposesOf, readKeys, rolesOf, screenBase } from './check-design-tokens.mjs'
import { classCompilers } from './compare-ui-values.mjs'
import { uiSourceDirs, workspaceDirs } from './ui-sources.mjs'
import { appOf, catalogueRows, frontmatter, headers, isComponent, isScreen, key, lineCode, listOf } from '../../ui-patterns/scripts/check-ui-status.mjs'

const REFERENCES = '.claude/skills/ui-patterns/references'
const INVENTORY = '.claude/rules/project/ui-inventory.md'
export const LAYERS = ['tokens', 'components', 'references', 'screens']
const posix = (p) => p.split(path.sep).join('/')

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
 * The code of every line the change removed, counted: what a moved line is matched against.
 * A deleted file is all removed lines.
 */
function removedCode(repo, base) {
  const out = new Map()
  const diff = execFileSync('git', ['-C', repo, 'diff', '-M', '-U0', '--no-color', base, '--', '*.ts', '*.tsx'], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
  for (const line of diff.split('\n')) {
    if (!line.startsWith('-') || line.startsWith('---')) continue
    const code = lineCode(line.slice(1))
    if (/\w/.test(code)) out.set(code, (out.get(code) ?? 0) + 1)
  }
  return out
}

/**
 * The changed lines that carry code. A TypeScript line whose change is a comment, or part
 * of an import that binds names, is not a change. Nor is a line whose code the same change
 * removed somewhere — a line moved, into another file or a new shared one, draws what it
 * drew: each removed line answers for one line that arrived. A file left with no changed
 * line is untouched. Stylesheets and references are kept whole: a token's purpose comment
 * and a rule's prose are their content. `newFiles` holds every file new in the change,
 * whatever lines it keeps.
 */
function codeChanges(repo, changed, base) {
  const out = new Map()
  const newFiles = new Set()
  const removed = removedCode(repo, base)
  // A file is new in the change when what the change is measured from did not hold it,
  // whether or not a commit along the way has taken it in.
  let before = null
  try {
    before = new Set(execFileSync('git', ['-C', repo, 'ls-tree', '-r', '--name-only', '-z', base ?? 'HEAD'], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] }).split('\0'))
  } catch {
    // No commit to measure from: only a file git does not track yet is known to be new.
  }
  for (const [file, lines] of changed) {
    if (lines === ALL || (before && !before.has(file))) newFiles.add(file)
    if (!/\.tsx?$/.test(file)) {
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
    const kept = new Set()
    for (const n of lines === ALL ? text.map((_, i) => i + 1) : [...lines].sort((a, b) => a - b)) {
      const line = text[n - 1] ?? ''
      if (isComment(line) || imports.has(n)) continue
      const code = lineCode(line)
      const left = removed.get(code) ?? 0
      if (left > 0) {
        removed.set(code, left - 1)
        continue
      }
      kept.add(n)
    }
    if (kept.size) out.set(file, kept)
  }
  return { changed: out, newFiles }
}

/** Everything the locator reads about a repository, once. */
export function readRepo(repo, { base = null, all = false, tokensOf = null } = {}) {
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
  let newFiles = new Set()
  if (!all) {
    const ref = screenBase(repo, base) ?? 'HEAD'
    ;({ changed, newFiles } = codeChanges(repo, new Map([...changedLines(repo, ref), ...changedIn(repo, ref, ['*.css', '*.md'])]), ref))
  }
  return { repo, keys, pkgRel, dirs, workspaces, css, sources, refs, rows, inventoryLines, types, changed, newFiles, isAtomFile, tokensOf }
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
const isNew = (R, file) => !!R.changed && R.newFiles.has(file)
/** A file a Design Pack installed says so in its opening lines: `// ui-pack:` in code,
 * `pack:` in a reference. */
const PACK_POINTER = /^(?:\/\/ ui-pack:|pack:)\s*\S+\/\S+\s+@\s+\S+/m
/** A pack's file in the change that adds it. It was judged where it was made, and the
 * human approves it on the pack's reference pages; from the next change on it is asked
 * about as any other file is. */
const arrived = (R, file) => isNew(R, file) && PACK_POINTER.test((R.sources.get(file) ?? R.refs.get(file) ?? '').split('\n', 20).join('\n'))
/** A piece the human has answered for — approved, or deferred — is not asked about at a
 * commit: its own contents are theirs. Nor is a pack's file as it arrives. An audit
 * (`--all`) asks everything. */
const answered = (R, file) => !!R.changed && (arrived(R, file) || /ui-status:\s*(?:approved|deferred)\b/.test(R.sources.get(file) ?? R.refs.get(file) ?? ''))

/** The roles the pack files arriving in this change read: a role declared with them was
 * fitted by the install, which already asked whether the project had one for the job. */
function arrivingRoles(R) {
  const out = new Set()
  if (!R.changed) return out
  const types = rolesOf(R.css).typeRoles
  for (const [file, src] of R.sources) {
    if (!arrived(R, file)) continue
    for (const m of src.matchAll(/var\((--[A-Za-z0-9-]+)/g)) out.add(m[1])
    for (const raw of classText(src).split(/\s+/)) {
      const cls = raw.replace(/^["'`]+|["'`,]+$/g, '')
      if (!/^[\w!@[-]/.test(cls)) continue
      const base = cls.split(':').pop().replace(/^!|!$/g, '')
      if (types.has(base)) out.add(base)
      for (const t of R.tokensOf?.(file, cls) ?? []) out.add(t)
    }
  }
  // And what those roles rest on: a type role names the size, weight and line height it
  // is made of, and a token the token it points at.
  const made = new Map(roles(R).map((r) => [r.name, r.value]))
  for (const [, css] of R.css) for (const m of css.matchAll(/^\s*(--[A-Za-z0-9-]+)\s*:\s*([^;]+);/gm)) if (!made.has(m[1])) made.set(m[1], m[2])
  const queue = [...out]
  while (queue.length) {
    for (const m of (made.get(queue.pop()) ?? '').matchAll(/var\((--[A-Za-z0-9-]+)/g)) {
      if (out.has(m[1])) continue
      out.add(m[1])
      queue.push(m[1])
    }
  }
  // A theme alias of one of them (`--spacing-x: var(--x)`) is the same role under the name
  // Tailwind reads, which its build replaces with what it points at.
  for (let grew = true; grew; ) {
    grew = false
    for (const [name, value] of made) {
      const to = value.trim().match(/^var\((--[A-Za-z0-9-]+)\)$/)?.[1]
      if (to && out.has(to) && !out.has(name)) {
        out.add(name)
        grew = true
      }
    }
  }
  return out
}

/** A component file's name as the catalogue keys it: its own, or its folder's for an index. */
const stemOf = (file) => {
  const parts = file.split('/')
  const base = parts.at(-1).replace(/\.tsx$/, '')
  return base === 'index' ? parts.at(-2) : base
}

/**
 * The inventory row and line for a component file, matched as the status check matches it:
 * by name, and by path where the row gives one — two blocks of one name in two folders each
 * have their own row.
 */
function rowFor(R, file) {
  const k = key(stemOf(file))
  const named = R.rows.filter((r) => !r.name.endsWith('.md') && key(r.name.split('/').at(-1)) === k)
  const row = named.find((r) => r.name.includes('/') && key(file).endsWith(key(r.name))) ?? named.find((r) => !r.name.includes('/')) ?? (named.length === 1 ? named[0] : null)
  return row ? { row, line: R.inventoryLines[row.line - 1] ?? '' } : { row: null, line: '' }
}

/**
 * The components a file exports, in order: each exported, capitalised function or constant
 * whose code draws JSX, with the line its first JSX starts on. Read from TypeScript's tree.
 */
function exportedComponents(R, file) {
  R.components ??= new Map()
  if (R.components.has(file)) return R.components.get(file)
  const ts = loadTypeScript(R.repo)
  const src = R.sources.get(file) ?? ''
  const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  const firstJsx = (n) => {
    let at = null
    const visit = (x) => {
      if (at !== null) return
      if (ts.isJsxElement(x) || ts.isJsxSelfClosingElement(x) || ts.isJsxFragment(x)) at = sf.getLineAndCharacterOfPosition(x.getStart(sf)).line + 1
      else ts.forEachChild(x, visit)
    }
    visit(n)
    return at
  }
  const exported = new Set()
  const declared = []
  for (const s of sf.statements) {
    const isExport = s.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword)
    if (ts.isFunctionDeclaration(s) && s.name) declared.push({ name: s.name.text, node: s, isExport })
    else if (ts.isVariableStatement(s)) for (const d of s.declarationList.declarations) if (ts.isIdentifier(d.name) && d.initializer) declared.push({ name: d.name.text, node: d.initializer, isExport })
    else if (ts.isExportDeclaration(s) && !s.moduleSpecifier && s.exportClause && ts.isNamedExports(s.exportClause)) for (const e of s.exportClause.elements) exported.add((e.propertyName ?? e.name).text)
    else if (ts.isExportAssignment(s) && ts.isIdentifier(s.expression)) exported.add(s.expression.text)
  }
  const out = declared.filter((d) => /^[A-Z]/.test(d.name) && (d.isExport || exported.has(d.name))).map((d) => ({ name: d.name, jsx: firstJsx(d.node) })).filter((d) => d.jsx !== null)
  R.components.set(file, out)
  return out
}
/** The component a block file is: the one named as the file is, else the first it exports. */
const blockOf = (R, file) => {
  const all = exportedComponents(R, file)
  return all.find((c) => key(c.name) === key(stemOf(file))) ?? all[0] ?? null
}
const componentName = (R, file) => blockOf(R, file)?.name ?? path.basename(file, '.tsx')
const blockType = (R, file) => headers(R.sources.get(file) ?? '').block ?? rowFor(R, file).row?.type ?? null
/**
 * What a block draws and takes, from its code: its first lines that hold code — imports,
 * comments and blank lines left out — and, when those stop short of it, the start of what
 * the block draws.
 */
function summary(R, file, lines = 40) {
  const src = R.sources.get(file) ?? ''
  const imports = importLines(R.repo, file, src)
  const code = src.split('\n').map((l, i) => [i + 1, l]).filter(([n, l]) => l.trim() && !imports.has(n) && !/^\s*(\/\/|\/\*|\*)/.test(l))
  const head = code.slice(0, lines)
  const jsx = blockOf(R, file)?.jsx
  const drawn = jsx && !head.some(([n]) => n >= jsx) ? [[0, '…'], ...code.filter(([n]) => n >= jsx).slice(0, Math.ceil(lines / 2))] : []
  return [...head, ...drawn].map(([, l]) => l).join('\n')
}
/** An opening tag as written, on one line: every attribute it carries, however it is wrapped. */
const oneLine = (tag) => tag.replace(/\s+/g, ' ').trim()
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
  const withPack = arrivingRoles(R)
  // A role is asked about when the change touched it, unless it came in with a pack.
  const asked = (r) => touched(R, r.file, r.line) && !withPack.has(r.name)
  for (const r of all) {
    if (!asked(r)) continue
    yield { question: 'ROLE-NAME', at: `${r.file}:${r.line}`, candidate: { name: r.name, purpose: r.purpose, value: r.value } }
  }
  const byFamily = new Map()
  for (const r of all) byFamily.set(r.family, [...(byFamily.get(r.family) ?? []), r])
  for (const list of byFamily.values()) {
    for (let i = 0; i < list.length; i++) {
      for (let j = i + 1; j < list.length; j++) {
        const a = list[i]
        const b = list[j]
        if (!asked(a) && !asked(b)) continue
        if (!a.purpose && !b.purpose) continue
        yield { question: 'DUPLICATE-ROLE', at: `${b.file}:${b.line}`, about: a.name, candidate: { a: { name: a.name, purpose: a.purpose, value: a.value }, b: { name: b.name, purpose: b.purpose, value: b.value } } }
      }
    }
  }
}

// ─── classes at use: the token used against its purpose ──────────────────

/**
 * What each class reads, from Tailwind's own build of it: a function (file, class) → the
 * custom properties the class's compiled declarations name. Nothing is inferred from how a
 * class is spelled. `entries` is the stylesheets that import tailwindcss; with none there is
 * no build to ask, and the function is null.
 */
export async function classTokens(repo) {
  const { entries, declarationsOf } = await classCompilers(repo)
  if (!entries.length) return { entries, tokensOf: null }
  const cache = new Map()
  const tokensOf = (file, cls) => {
    const k = `${file}\0${cls}`
    if (!cache.has(k)) cache.set(k, tokensIn(declarationsOf(file, cls)))
    return cache.get(k)
  }
  return { entries, tokensOf }
}

/** The custom properties a class's declarations read, Tailwind's own (`--tw-…`) left out. */
export function tokensIn(declarations) {
  const out = new Set()
  for (const [key, value] of declarations) {
    // A declaration is keyed by the rules it sits in, then `|`, then its property.
    const property = key.slice(key.lastIndexOf('|') + 1)
    // A declaration that sets a token gives it a value under this class — a theme, a scope
    // an app marks its root with — and is no use of the tokens it is made from. Tailwind's
    // own variables (`--tw-shadow`) are how a utility applies one, and still count.
    if (property.startsWith('--') && !property.startsWith('--tw-')) continue
    for (const m of value.matchAll(/var\((--[\w-]+)/g)) if (!m[1].startsWith('--tw-')) out.add(m[1])
  }
  return [...out]
}

/** The roles a class uses that carry a purpose: a type utility is its own role; any other
 * class uses the tokens Tailwind's build says it reads. */
function tokensOf(R, file, cls, typeRoles, purposes) {
  const base = cls.split(':').pop()
  if (typeRoles.has(base)) return [base]
  return (R.tokensOf?.(file, cls) ?? []).filter((t) => purposes.get(t))
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
        if (!/^[\w!@[-]/.test(cls)) continue
        const tokens = tokensOf(R, file, cls, r.typeRoles, purposes)
        if (!tokens.length) continue
        if (R.changed === null && seen.has(cls)) continue
        seen.add(cls)
        for (const token of tokens) {
          const purpose = purposes.get(token)
          if (!purpose) continue
          yield { question: 'TOKEN-AGAINST-PURPOSE', at: `${file}:${i + 1}`, about: tokens.length > 1 ? `${cls} (${token})` : cls, note: `${token} is for: ${purpose}`, candidate: { token: cls, purpose, line: lines[i], where: `${where} ${file}`, context: context(src, i + 1, 5) } }
        }
      }
    }
  }
}

// ─── components ──────────────────────────────────────────────────────────

/**
 * For each source file, the file every name it imports is declared in: TypeScript's own
 * resolution, through the project's tsconfig, its aliases and its barrels. A tag is the
 * component its import says it is, never another component that shares its name. A
 * namespace import's members are held as `Namespace.Member`. `R.unresolved` lists each
 * import of the project's own code — a relative path, or a workspace package — that
 * TypeScript could not resolve: what such a name is cannot be known.
 */
export function componentBindings(R) {
  if (R.bindings) return R.bindings
  const ts = loadTypeScript(R.repo)
  const root = realpathSync(R.repo)
  const groups = new Map()
  for (const f of R.sources.keys()) {
    let d = path.dirname(f)
    while (d !== '.' && !existsSync(path.join(root, d, 'tsconfig.json'))) d = path.dirname(d)
    const cfg = existsSync(path.join(root, d, 'tsconfig.json')) ? path.join(root, d, 'tsconfig.json') : ''
    groups.set(cfg, [...(groups.get(cfg) ?? []), f])
  }
  const out = new Map()
  const unresolved = []
  const packages = R.workspaces.map((d) => {
    try {
      return JSON.parse(readFileSync(path.join(root, d, 'package.json'), 'utf8')).name
    } catch {
      return null
    }
  }).filter(Boolean)
  const own = (spec) => !/\?|\.(?!tsx?$|jsx?$)[a-z0-9]+$/i.test(spec) && (spec.startsWith('.') || packages.some((p) => spec === p || spec.startsWith(`${p}/`)))
  for (const [cfg, files] of groups) {
    const parsed = cfg ? ts.getParsedCommandLineOfConfigFile(cfg, {}, { ...ts.sys, onUnRecoverableConfigFileDiagnostic() {} }) : null
    const options = { jsx: ts.JsxEmit.Preserve, moduleResolution: ts.ModuleResolutionKind.Bundler, module: ts.ModuleKind.ESNext, ...(parsed?.options ?? {}), noEmit: true }
    const program = ts.createProgram({ rootNames: files.map((f) => path.join(root, f)), options })
    const checker = program.getTypeChecker()
    const fileOf = (sym) => {
      if (sym && sym.flags & ts.SymbolFlags.Alias) sym = checker.getAliasedSymbol(sym)
      const d = sym?.declarations?.[0]
      return d ? posix(path.relative(root, d.getSourceFile().fileName)) : null
    }
    for (const f of files) {
      const sf = program.getSourceFile(path.join(root, f))
      const names = new Map()
      for (const s of sf?.statements ?? []) {
        if (!ts.isImportDeclaration(s) || !s.importClause) continue
        const c = s.importClause
        if (!c.isTypeOnly && own(s.moduleSpecifier.text) && !checker.getSymbolAtLocation(s.moduleSpecifier)) unresolved.push(`${f}: ${s.moduleSpecifier.text}`)
        if (c.name) names.set(c.name.text, fileOf(checker.getSymbolAtLocation(c.name)))
        const nb = c.namedBindings
        if (nb && ts.isNamedImports(nb)) for (const e of nb.elements) names.set(e.name.text, fileOf(checker.getSymbolAtLocation(e.name)))
        if (nb && ts.isNamespaceImport(nb)) {
          const mod = checker.getSymbolAtLocation(s.moduleSpecifier)
          if (mod) for (const ex of checker.getExportsOfModule(mod)) names.set(`${nb.name.text}.${ex.name}`, fileOf(ex))
        }
      }
      out.set(f, names)
    }
  }
  R.bindings = out
  R.unresolved = unresolved
  return out
}

/** Every use of a project component across the sources: { file, line, name, tag, classes, variant }. */
function callSites(R) {
  const bindings = componentBindings(R)
  const out = []
  const exported = new Map()
  for (const [, s] of R.sources) constantClasses(s, exported)
  for (const [file, src] of R.sources) {
    const consts = constantClasses(src)
    for (const t of openingTags(src, /<([A-Z][\w.]*)\b/g)) {
      const names = bindings.get(file)
      const target = names?.get(t.name) ?? names?.get(t.name.split('.')[0])
      if (!target || target === file || !isComponent(target) || !R.sources.has(target)) continue
      const classes = [...t.classes, ...t.ids.flatMap((id) => consts.get(id) ?? exported.get(id) ?? [])]
      // A variant given as an expression is its own group, never the default.
      const variant = t.open.match(/\svariant=(?:"([^"]+)"|\{\s*["']([^"']+)["']\s*\}|(\{[^}]*\}))/)
      out.push({ file, line: t.line, name: t.name, target, tag: oneLine(t.open), classes, variant: variant?.[1] ?? variant?.[2] ?? variant?.[3] ?? 'default' })
    }
  }
  return out
}

function* components(R) {
  const sites = callSites(R)
  const blocks = [...R.sources.keys()].filter((f) => isComponent(f) && !R.isAtomFile(f))
  const usedBy = (file) => [...new Set(sites.filter((s) => s.target === file).map((s) => s.file))]

  for (const file of blocks) {
    if (!fileTouched(R, file) || answered(R, file)) continue
    const src = R.sources.get(file)
    yield { question: 'NAMED-FOR-DATA', at: file, candidate: { name: componentName(R, file), blockType: blockType(R, file) ?? '(none named)', summary: summary(R, file), screens: usedBy(file) } }
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
    if (answered(R, target)) continue
    if (!fileTouched(R, target) && !list.some((s) => touched(R, s.file, s.line))) continue
    const definition = classText(R.sources.get(target)).split('\n').map((l) => l.trim()).filter(Boolean).join(' ')
    yield { question: 'VARIANT-INCOMPLETE', at: target, about: variant, candidate: { component: componentName(R, target), variant, definition, callSites: list.map((s) => `${s.file}:${s.line} ${s.tag}`) } }
  }

  // A new block against its neighbours; a second block of a type is code's finding.
  for (const file of blocks) {
    if (R.changed && (!isNew(R, file) || answered(R, file))) continue
    const type = blockType(R, file)
    const name = componentName(R, file)
    const others = blocks.filter((f) => f !== file)
    const same = others.filter((f) => type && blockType(R, f) === type)
    for (const f of same) {
      const { line } = rowFor(R, f)
      yield { finding: 'SECOND-BLOCK', at: file, about: componentName(R, f), text: `${name} is a second block of type ${type}; the first is ${componentName(R, f)} (${f})${line ? ` — its inventory line: ${line.trim()}` : ''}. Same thing: fold in as a variant. Different: the human's reason goes on the new line.` }
    }
    // Neighbours both ways: the types the new one is not to be confused with, and the types
    // that name the new one as theirs.
    const neighbourTypes = new Set(type ? [...(R.types.neighbours.get(type) ?? []), ...[...R.types.neighbours].filter(([, list]) => list.includes(type)).map(([t]) => t)] : [...R.types.names])
    for (const f of others) {
      const t = blockType(R, f)
      if (!t || !neighbourTypes.has(t) || same.includes(f)) continue
      yield {
        question: 'DUPLICATE-BLOCK',
        at: file,
        about: componentName(R, f),
        candidate: {
          new: { name, type: type ?? '(none named)', code: summary(R, file, 80) },
          existing: { name: componentName(R, f), type: t, code: summary(R, f, 80), inventoryLine: rowFor(R, f).line.trim() },
        },
      }
    }
  }

  yield* tokenUses(R, blocks.filter((f) => !answered(R, f)), 'block')
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

/**
 * The lines of a reference a yes about it may rest on, for the judge: null when any line
 * may — an audit, a new file, or a change to the `block-types:` or `apps:` line, which
 * changes what every sentence of the file governs — else the lines the change touched.
 */
function changedOf(R, ref) {
  if (!R.changed) return null
  const lines = R.changed.get(ref.file)
  if (!lines) return []
  if (lines === ALL) return null
  const text = ref.text.split('\n')
  if ([...lines].some((n) => /^(?:block-types|apps):/.test(text[n - 1] ?? ''))) return null
  return [...lines].sort((a, b) => a - b)
}
const sentencesOf = (R, ref, from) => {
  const changed = changedOf(R, ref)
  return { file: ref.file, from, ...(changed ? { changed } : {}) }
}

function* references(R) {
  const refs = refMeta(R)
  const blocks = [...R.sources.keys()].filter((f) => isComponent(f) && !R.isAtomFile(f))
  for (const rule of refs) {
    if (rule.kind !== 'behaviour' || rule.blockTypes.includes('cross-cutting')) continue
    for (const f of blocks) {
      const t = blockType(R, f)
      if (!t || !rule.blockTypes.includes(t) || !governs(R, rule, f)) continue
      if (!fileTouched(R, rule.file) && !fileTouched(R, f)) continue
      if (answered(R, rule.file) && answered(R, f)) continue
      yield { question: 'RULE-REACH', at: rule.file, about: componentName(R, f), sentences: [{ file: rule.file, from: 'rule' }], candidate: { rule: rule.text, blockTypes: `block-types: ${rule.raw}`, block: { name: componentName(R, f), type: t, summary: summary(R, f), inventoryLine: rowFor(R, f).line.trim() } } }
    }
  }
  for (let i = 0; i < refs.length; i++) {
    for (let j = i + 1; j < refs.length; j++) {
      const a = refs[i]
      const b = refs[j]
      if (!fileTouched(R, a.file) && !fileTouched(R, b.file)) continue
      if (answered(R, a.file) && answered(R, b.file)) continue
      // Two references for different apps never meet on a screen.
      if (!shareApp(a, b)) continue
      // A cross-cutting rule governs every surface, so it shares the other rule's surfaces.
      const aAll = a.blockTypes.includes('cross-cutting')
      const bAll = b.blockTypes.includes('cross-cutting')
      const shared = aAll && bAll ? ['every surface'] : aAll ? b.blockTypes : bAll ? a.blockTypes : a.blockTypes.filter((t) => b.blockTypes.includes(t))
      if (!shared.length) continue
      const surface = shared.join(', ')
      yield { question: 'RULE-CONFLICT', at: b.file, about: path.basename(a.file), sentences: [sentencesOf(R, b, 'b.text'), sentencesOf(R, a, 'a.text')], candidate: { surface, a: { file: path.basename(a.file), text: a.text }, b: { file: path.basename(b.file), text: b.text } } }
    }
  }
  yield* tokenUses(R, [...R.refs.keys()].filter((f) => fileTouched(R, f) && !answered(R, f)), 'rule')
}

// ─── screens ─────────────────────────────────────────────────────────────

function* screens(R, only = null) {
  const sites = callSites(R)
  const refs = refMeta(R)
  const files = [...R.sources.keys()].filter((f) => isScreen(f, R.dirs) && (!only || f === only || f.startsWith(`${only.replace(/\/$/, '')}/`)))
  const typesText = [...R.types.definitions].map(([t, d]) => `${t}: ${d}`).join('\n')
  const blockRows = R.inventoryLines.filter((l) => /^\|\s*`/.test(l))
  for (const file of files) {
    if (!fileTouched(R, file) || arrived(R, file)) continue
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
      // The whole opening tag, and the lines after it ends: a tag wrapped over several lines
      // carries its classes below its first.
      const last = t.line + t.open.split('\n').length - 1
      yield { question: 'SCREEN-BOX', at: `${file}:${t.line}`, candidate: { tag: oneLine(t.open), children: context(src, last + 2, 1), file, blockTypes: typesText, blocks: blockRows } }
    }
  }
  yield* tokenUses(R, files.filter((f) => !arrived(R, f)), 'screen')
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
  let classes
  try {
    classes = await classTokens(repo)
  } catch (e) {
    console.error(`locate: Tailwind could not compile this project's classes, so what each class reads is unknown — ${e.message}`)
    process.exit(1)
  }
  const R = readRepo(repo, { base: opt('--base') ?? null, all, tokensOf: classes.tokensOf })
  if (!R.notApplicable && !R.problems) {
    componentBindings(R)
    if (R.unresolved.length) {
      console.error(`locate: TypeScript could not resolve ${R.unresolved.length} import(s) of this project's own code, so which component a tag is cannot be known. Install the dependencies, or fix the path or the tsconfig alias. First: ${R.unresolved.slice(0, 3).join('; ')}`)
      process.exit(1)
    }
  }
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
  console.error(`locate: ${n} candidate(s)${all ? ` in ${layer ?? 'every layer'}` : ' in the change'}; ${classes.tokensOf ? `classes read through Tailwind's build of ${classes.entries.length} stylesheet(s)` : 'no stylesheet imports tailwindcss, so only type roles are located as token uses'}`)
}
