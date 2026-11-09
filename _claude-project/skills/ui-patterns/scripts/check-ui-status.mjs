#!/usr/bin/env node
/**
 * No UI becomes law until a human has approved it, and every piece says what governs it.
 *
 *   node .claude/skills/ui-patterns/scripts/check-ui-status.mjs
 *
 * Status. Every component (a .tsx under a `components/` folder outside `features/`) and
 * every recipe or behaviour rule (.claude/skills/ui-patterns/references/*.md) carries
 * exactly one line `ui-status: approved`, `ui-status: pending` or `ui-status: deferred`.
 * A token awaiting approval carries `ui-status: pending` in its comment. The UI inventory
 * (.claude/rules/project/ui-inventory.md) lists every component, recipe and rule with the
 * same status its file carries.
 *
 * Deferred is the human's "I did not look; I trust it": it blocks nothing, needs no
 * reason, and is listed apart. Its inventory line carries the file's fingerprint from when
 * it was deferred; once the file changes it is pending again. A line in UI source may be
 * deferred the same way — `design-deferred <fingerprint>` in a comment on the line, the
 * fingerprint of the line's own code — and is pending again when that code changes.
 * `design-accepted` on a line is approved on a line and needs nothing.
 *
 * The judge's ledger. A yes from the judge (design-system skill, scripts/judge.mjs) is a
 * pending item in .claude/ui-pending.json, keyed by question and place with the fingerprint
 * of the line it names. It is pending until the human approves the line (design-accepted),
 * defers it (design-deferred) or the line changes, when it is re-judged at the next commit.
 *
 * Pointers. Every file names what governs it at its top, and the check confirms each
 * pointer names something real:
 *   a component     `// ui-block: <Type>` (a type on the block-type list, agreeing with its
 *                   inventory line), or `// ui-atom`; optionally `// ui-behaviour: a.md, b.md`,
 *                   the behaviour rules it carries out;
 *   behaviour code  `// ui-behaviour-code: <rule>.md` on any .ts/.tsx that carries a rule;
 *   a screen        `// ui-recipe: <recipe>.md`, or `// ui-content` for a feature file that
 *                   holds one screen's content;
 *   a recipe        frontmatter `kind: recipe`, `frame: <component>`, `reference: <screen
 *                   file>`, `block-types:`;
 *   a behaviour rule frontmatter `kind: behaviour`, `code: [<files>]`, `block-types:`; every
 *                   file in `code` points back at the rule.
 *   Either may carry `apps: [<workspace>, …]` — the workspaces the root package.json
 *   declares that it governs; omitted, it governs every app. A recipe's reference screen
 *   lives in one of them.
 *
 * Fails, naming each, on:
 *   pending     a component, recipe, rule or token still awaiting the human's approval, a
 *               deferred one whose file changed since, and a deferred line whose code changed;
 *   unmarked    a component, recipe or rule with no status line, more than one, or an
 *               unknown value;
 *   catalogue   a component, recipe or rule the inventory does not list, a line whose
 *               status differs from its file's, a status line naming no file, a deferred
 *               line with no fingerprint, a component line with no Type or one not on the
 *               block-type list;
 *   pointers    a pointer naming nothing, a header disagreeing with the inventory, a rule's
 *               code list not matched by the files pointing back, a screen or reference
 *               with no pointer.
 *
 *   node .claude/skills/ui-patterns/scripts/check-ui-status.mjs --fingerprint <file>
 *     prints a file's fingerprint, as a deferred inventory line names it.
 *   node .claude/skills/ui-patterns/scripts/check-ui-status.mjs --line-fingerprint <file> <n>
 *     prints line n's fingerprint, as a `design-deferred` comment names it.
 *   node .claude/skills/ui-patterns/scripts/check-ui-status.mjs --deferred
 *     lists what the human set aside; a plain run prints only the count.
 *   node .claude/skills/ui-patterns/scripts/check-ui-status.mjs --maturity
 *     prints, per screen file, how many blocks the inventory gained in the commit that
 *     added the screen: the reading of whether the system is maturing.
 *
 * /deploy refuses while it fails; /work and /handoff run it to show what awaits review.
 * Prints what it inspected, and passes saying it does not apply when the project has no
 * component or reference files.
 */

import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { CROSS_CUTTING, readBlockTypes } from '../../design-system/scripts/block-types.mjs'
import { workspaceDirs } from '../../design-system/scripts/ui-sources.mjs'
import { uiSourceDirs } from '../../design-system/scripts/ui-sources.mjs'

export const INVENTORY = '.claude/rules/project/ui-inventory.md'
export const LEDGER = '.claude/ui-pending.json'
const REFERENCES = '.claude/skills/ui-patterns/references/'
const STATUS = /ui-status:\s*([A-Za-z-]+)/g
const VALUES = new Set(['approved', 'pending', 'deferred'])
const KINDS = new Set(['recipe', 'behaviour'])
const HEADER_LINES = 12

export const NOT_APPLICABLE = 'UI status does not apply: this project has no component or reference files'

/** A file's fingerprint, as a deferred inventory line names it: the first eight hex digits of its SHA-256. */
export function fingerprint(text) {
  return createHash('sha256').update(text).digest('hex').slice(0, 8)
}

/** A line's code without its comments, trimmed: what a `design-deferred` fingerprint is taken over. */
export function lineCode(line) {
  return line
    .replace(/\{\s*\/\*[\s\S]*?\*\/\s*\}/g, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/.*$/, '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .trim()
}

/** Every tracked or new file, gitignored ones left out. */
function repoFiles(repo) {
  const out = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], {
    cwd: repo,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  })
  return [...new Set(out.split('\0').filter(Boolean))].filter((f) => existsSync(path.join(repo, f)))
}

const isSource = (file) => /\.(ts|tsx)$/.test(file) && !/\.(test|spec|stories|d)\.tsx?$/.test(file) && !/\.(gen|generated)\.ts$/.test(file) && !file.split('/').includes('node_modules')

export function isComponent(file) {
  if (!file.endsWith('.tsx') || /\.(test|spec|stories)\.tsx$/.test(file)) return false
  const parts = file.split('/')
  // A feature folder holds one screen's content, never a block — whatever it names a subfolder.
  return parts.includes('components') && !parts.includes('features') && !parts.includes('node_modules')
}

/** A screen or feature file: a .tsx in the UI source that is not a component. */
export function isScreen(file, sourceDirs) {
  if (!file.endsWith('.tsx') || isComponent(file) || !isSource(file)) return false
  if (!sourceDirs) return true
  return sourceDirs.some((d) => d === '.' || file === d || file.startsWith(`${d}/`))
}

/** A vendored atom, which carries no block type: under DESIGN_VENDORED_DIR, or a
 * `components/ui/` folder when the key is not set. */
function atomTest(repo) {
  const file = path.join(repo, '.claude/sync-substitutions.json')
  const dir = existsSync(file) ? String(JSON.parse(readFileSync(file, 'utf8')).DESIGN_VENDORED_DIR ?? '').trim().replace(/\/$/, '') : ''
  return dir ? (f) => f.startsWith(`${dir}/`) : (f) => f.includes('components/ui/')
}

/** The UI source folders, when the project names its UI package; null means every folder. */
function sourceDirsOf(repo) {
  const file = path.join(repo, '.claude/sync-substitutions.json')
  const ui = existsSync(file) ? String(JSON.parse(readFileSync(file, 'utf8')).DESIGN_UI_PACKAGE ?? '').trim() : ''
  if (!ui) return null
  const { dirs, problems } = uiSourceDirs(repo, ui)
  return problems.length || !dirs.length ? null : dirs
}

/** A reference's frontmatter as a flat map of key → raw value, or null when it has none. */
export function frontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) return null
  const out = {}
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^([A-Za-z-]+):\s*(.*)$/)
    if (kv) out[kv[1]] = kv[2].trim()
  }
  return out
}

/** A frontmatter list value as items: `[a, b]`, `a, b` or `cross-cutting`. */
export const listOf = (v) => (v == null ? [] : v.replace(/[[\]]/g, '').split(',').map((t) => t.trim()).filter(Boolean))

/** The workspace a file lives in — the declared folder that prefixes it — or null. */
export function appOf(file, workspaces) {
  return workspaces.find((w) => w !== '.' && file.startsWith(`${w}/`)) ?? null
}

/** A recipe or rule's `block-types:` as a list, or null when it has none. */
export function patternBlockTypes(text) {
  const fm = frontmatter(text)
  if (!fm || fm['block-types'] === undefined) return null
  return listOf(fm['block-types'])
}

/** A reference: any .md directly under references/ except the kit's own README. */
export function isPattern(file) {
  const name = file.slice(REFERENCES.length)
  return file.startsWith(REFERENCES) && name.endsWith('.md') && !name.includes('/') && name !== 'README.md'
}

/** The name a catalogue line uses for a file: `IconButton`, `icon-button.tsx` and `icon-button` all match. */
export function key(name) {
  return name.toLowerCase().replace(/\.(tsx|md)$/, '').replace(/[^a-z0-9]/g, '')
}

function fileKey(file) {
  const parts = file.split('/')
  const base = parts.at(-1).replace(/\.(tsx|md)$/, '')
  return key(base === 'index' ? parts.at(-2) : base)
}

/** Statuses found in a file, with their line numbers. */
function statuses(text) {
  const found = []
  text.split('\n').forEach((line, i) => {
    for (const m of line.matchAll(STATUS)) found.push({ value: m[1], line: i + 1 })
  })
  return found
}

/** The pointer lines a source file carries in its header. */
export function headers(text) {
  const out = { block: null, atom: false, behaviour: [], behaviourCode: [], recipe: null, content: false }
  for (const line of text.split('\n').slice(0, HEADER_LINES)) {
    const m = line.match(/^\s*(?:\/\/|\/\*|\*)\s*ui-(block|atom|behaviour-code|behaviour|recipe|content)\b:?\s*(.*?)\s*(?:\*\/)?\s*$/)
    if (!m) continue
    const v = m[2].trim()
    if (m[1] === 'block') out.block = v
    else if (m[1] === 'atom') out.atom = true
    else if (m[1] === 'behaviour') out.behaviour.push(...v.split(',').map((s) => s.trim()).filter(Boolean))
    else if (m[1] === 'behaviour-code') out.behaviourCode.push(...v.split(',').map((s) => s.trim()).filter(Boolean))
    else if (m[1] === 'recipe') out.recipe = v
    else if (m[1] === 'content') out.content = true
  }
  return out
}

/** Inventory table rows: the first backticked name in the first cell, a status cell if
 * any, and the cells under `Type` when the table has it. */
export function catalogueRows(text) {
  const rows = []
  let header = null
  text.split('\n').forEach((line, i) => {
    if (!line.trimStart().startsWith('|')) {
      header = null
      return
    }
    if (/^\s*\|[\s:|-]+\|\s*$/.test(line)) return
    const cells = line.split('|').slice(1, -1).map((c) => c.trim())
    const name = cells[0]?.match(/`([^`]+)`/)?.[1]
    if (!name) {
      header ??= cells.map((c) => c.replace(/[*_]/g, '').trim())
      return
    }
    // A Status cell holds the value alone, or `deferred` with the file's fingerprint.
    const cell = cells
      .slice(1)
      .map((c) => c.replace(/[*_]/g, '').trim().match(/^(\w+)(?:\s+`([0-9a-f]{8})`.*)?$/))
      .find((m) => m && VALUES.has(m[1].toLowerCase()))
    const status = cell?.[1].toLowerCase()
    const mark = status === 'deferred' ? (cell[2] ?? null) : undefined
    const at = header ? header.indexOf('Type') : -1
    rows.push({
      name,
      status,
      line: i + 1,
      ...(mark !== undefined ? { mark } : {}),
      ...(at > 0 ? { type: cells[at]?.replace(/[`*]/g, '').trim() ?? '' } : {}),
    })
  })
  return rows
}

export function checkUiStatus(repo, { files = repoFiles(repo), sourceDirs = sourceDirsOf(repo) } = {}) {
  const parts = files.filter((f) => isComponent(f) || isPattern(f))
  const stylesheets = files.filter((f) => f.endsWith('.css') && !f.split('/').includes('node_modules'))
  const sources = files.filter(isSource)
  if (parts.length === 0) return { notApplicable: NOT_APPLICABLE }

  const pending = []
  const deferred = []
  const problems = []
  const statusOf = new Map()
  const texts = new Map()
  const read = (f) => {
    if (!texts.has(f)) texts.set(f, readFileSync(path.join(repo, f), 'utf8'))
    return texts.get(f)
  }
  const isAtom = atomTest(repo)
  let types = null
  try {
    types = readBlockTypes().names
  } catch (err) {
    problems.push(`${err.message} — block types cannot be checked`)
  }

  // --- status words on every component and reference -------------------------
  for (const f of parts) {
    const found = statuses(read(f))
    if (found.length === 0) problems.push(`${f}: no ui-status line`)
    else if (found.length > 1) problems.push(`${f}: ${found.length} ui-status lines (lines ${found.map((s) => s.line).join(', ')}); a file carries one`)
    else if (!VALUES.has(found[0].value)) problems.push(`${f}:${found[0].line}: ui-status "${found[0].value}" is not approved, pending or deferred`)
    else {
      statusOf.set(f, found[0].value)
      if (found[0].value === 'pending') pending.push(`${f} (${isPattern(f) ? 'reference' : 'component'})`)
    }
  }

  // --- references: a kind, a block-types line, and the pointers of their kind ------
  const references = parts.filter(isPattern)
  const refByName = new Map(references.map((f) => [path.basename(f), f]))
  const ruleCode = new Map() // rule file → the files its `code:` names
  const recipeOf = new Map() // recipe file → its frontmatter
  let workspaces = null
  for (const f of references) {
    const fm = frontmatter(read(f)) ?? {}
    let apps = null
    if (fm.apps !== undefined) {
      apps = listOf(fm.apps)
      if (!apps.length) problems.push(`${f}: \`apps:\` names no workspace — list the apps it governs, or leave the line out to govern every app`)
      workspaces ??= workspaceDirs(repo).dirs
      for (const a of apps) if (!workspaces.includes(a)) problems.push(`${f}: apps names \`${a}\`, which is not a workspace the root package.json declares`)
    }
    const named = fm['block-types'] === undefined ? null : listOf(fm['block-types'])
    if (!named?.length) problems.push(`${f}: no block-types line — list the block types it governs in its frontmatter, or ${CROSS_CUTTING}`)
    else if (types) for (const t of named) if (t !== CROSS_CUTTING && !types.has(t)) problems.push(`${f}: block-types names \`${t}\`, which is not on the block-type list`)
    if (!KINDS.has(fm.kind)) {
      problems.push(`${f}: no \`kind:\` in its frontmatter — a reference is \`kind: recipe\` or \`kind: behaviour\``)
      continue
    }
    if (fm.kind === 'recipe') {
      recipeOf.set(f, fm)
      if (!fm.frame) problems.push(`${f}: a recipe names its frame — \`frame: <component>\``)
      else if (!parts.some((c) => isComponent(c) && fileKey(c) === key(fm.frame.split('/').at(-1)))) problems.push(`${f}: frame \`${fm.frame}\` names no component file`)
      if (!fm.reference) problems.push(`${f}: a recipe names one reference screen — \`reference: <screen file>\``)
      else if (!files.includes(fm.reference)) problems.push(`${f}: reference \`${fm.reference}\` is not a file in this repository`)
      else if (apps?.length && !apps.includes(appOf(fm.reference, apps))) problems.push(`${f}: reference \`${fm.reference}\` is not in an app its \`apps:\` line names`)
    } else {
      const code = listOf(fm.code)
      ruleCode.set(f, code)
      if (!code.length) problems.push(`${f}: a behaviour rule lists its code — \`code: [<files>]\``)
      for (const c of code) if (!files.includes(c)) problems.push(`${f}: code \`${c}\` is not a file in this repository`)
    }
  }

  // --- components: a block type or atom header, and the rules they carry ---------
  const carriers = new Map() // rule file → files pointing back at it
  const pointBack = (rule, from) => carriers.set(rule, [...(carriers.get(rule) ?? []), from])
  for (const f of parts.filter(isComponent)) {
    const h = headers(read(f))
    if (isAtom(f)) {
      if (h.block) problems.push(`${f}: a vendored atom carries \`// ui-atom\`, never a block type`)
    } else if (h.atom && h.block) problems.push(`${f}: both \`// ui-atom\` and \`// ui-block\`; a file is one or the other`)
    else if (!h.atom && !h.block) problems.push(`${f}: no header — \`// ui-block: <Type>\` from the block-type list, or \`// ui-atom\``)
    else if (h.block && types && !types.has(h.block)) problems.push(`${f}: \`// ui-block: ${h.block}\` is not on the block-type list`)
    for (const rule of h.behaviour) {
      if (!refByName.has(rule)) problems.push(`${f}: \`// ui-behaviour: ${rule}\` names no reference file`)
      else if (!ruleCode.has(refByName.get(rule))) problems.push(`${f}: \`// ui-behaviour: ${rule}\` names a reference that is not a behaviour rule`)
      else pointBack(refByName.get(rule), f)
    }
  }

  // --- behaviour code anywhere in the source, and screens ------------------------
  for (const f of sources) {
    const h = headers(read(f))
    for (const rule of h.behaviourCode) {
      if (!refByName.has(rule)) problems.push(`${f}: \`// ui-behaviour-code: ${rule}\` names no reference file`)
      else if (!ruleCode.has(refByName.get(rule))) problems.push(`${f}: \`// ui-behaviour-code: ${rule}\` names a reference that is not a behaviour rule`)
      else pointBack(refByName.get(rule), f)
    }
    if (!isScreen(f, sourceDirs)) continue
    if (h.recipe && h.content) problems.push(`${f}: both \`// ui-recipe\` and \`// ui-content\`; a screen follows a recipe, a feature file is content`)
    else if (!h.recipe && !h.content) problems.push(`${f}: no header — \`// ui-recipe: <recipe>.md\`, or \`// ui-content\` for one screen's content`)
    else if (h.recipe) {
      if (!refByName.has(h.recipe)) problems.push(`${f}: \`// ui-recipe: ${h.recipe}\` names no reference file`)
      else if (!recipeOf.has(refByName.get(h.recipe))) problems.push(`${f}: \`// ui-recipe: ${h.recipe}\` names a reference that is not a recipe`)
    }
  }
  for (const [rule, code] of ruleCode) {
    const back = new Set(carriers.get(rule) ?? [])
    for (const c of code) if (!back.has(c)) problems.push(`${rule}: lists \`${c}\` as its code, which does not point back with \`// ui-behaviour\` or \`// ui-behaviour-code: ${path.basename(rule)}\``)
    for (const c of back) if (!code.includes(c)) problems.push(`${c}: points at ${path.basename(rule)}, whose \`code:\` list does not name it`)
  }

  // --- pending tokens, and lines deferred or re-pending ---------------------------
  for (const f of stylesheets) {
    read(f).split('\n').forEach((line, i, lines) => {
      if (!/ui-status:\s*pending/.test(line)) return
      const decl = [line, lines[i + 1] ?? ''].join(' ').match(/(--[\w-]+)\s*:/)
      pending.push(`${f}:${i + 1} (token${decl ? ` ${decl[1]}` : ''})`)
    })
  }
  let deferredLines = 0
  for (const f of [...sources, ...stylesheets]) {
    read(f).split('\n').forEach((line, i) => {
      const m = line.match(/design-deferred(?:\s+`?([0-9a-f]{8})`?)?/)
      if (!m) return
      const at = `${f}:${i + 1}`
      if (!m[1]) {
        problems.push(`${at}: \`design-deferred\` with no fingerprint — record the line's fingerprint (--line-fingerprint)`)
        return
      }
      const now = fingerprint(lineCode(line))
      if (m[1] !== now) pending.push(`${at} (line), changed since it was deferred (\`${m[1]}\`, now \`${now}\`) — put it to the human again`)
      else {
        deferredLines++
        deferred.push(`${at} (line)`)
      }
    })
  }

  // --- the judge's ledger: a yes is pending until the human answers or the line changes ---
  let judged = 0
  const ledgerPath = path.join(repo, LEDGER)
  if (existsSync(ledgerPath)) {
    let items = []
    try {
      items = JSON.parse(readFileSync(ledgerPath, 'utf8'))
    } catch {
      problems.push(`${LEDGER}: not JSON — the judge's ledger cannot be read`)
    }
    for (const i of Array.isArray(items) ? items : []) {
      const m = String(i.at ?? '').match(/^(.*):(\d+)$/)
      const line = m && existsSync(path.join(repo, m[1])) ? readFileSync(path.join(repo, m[1]), 'utf8').split('\n')[Number(m[2]) - 1] : undefined
      if (line === undefined || fingerprint(lineCode(line)) !== i.fingerprint || /design-(?:accepted|deferred)\b/.test(line)) continue
      judged++
      pending.push(`${i.at} (judge ${i.question}) — ${String(i.quote ?? '').split('\n')[0].slice(0, 100)}`)
    }
  }

  // --- the inventory agrees with the files -------------------------------------
  const inventoryPath = path.join(repo, INVENTORY)
  let rows = []
  if (!existsSync(inventoryPath)) problems.push(`${INVENTORY}: missing — the catalogue of components, recipes and rules`)
  else rows = catalogueRows(readFileSync(inventoryPath, 'utf8'))

  const listed = new Set()
  for (const row of rows) {
    const byPath = row.name.includes('/')
    const want = key(row.name.split('/').at(-1))
    const kind = row.name.endsWith('.md') ? isPattern : isComponent
    const matches = parts.filter((f) => kind(f) && fileKey(f) === want && (!byPath || key(f).endsWith(key(row.name))))
    if (matches.length === 0) {
      if (row.status) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` has a status but no component or reference file is named that`)
      continue
    }
    // An atom — vendored, or one the project made and headed `// ui-atom` — carries no type.
    if (kind === isComponent && matches.some((f) => !isAtom(f) && !headers(read(f)).atom)) {
      if (!row.type) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` has no block type — name its type from the block-type list in a Type column`)
      else if (types && !types.has(row.type)) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` names block type \`${row.type}\`, which is not on the block-type list`)
      else for (const f of matches) {
        const h = headers(read(f))
        if (h.block && h.block !== row.type) problems.push(`${f}: \`// ui-block: ${h.block}\` but its inventory line says ${row.type} (${INVENTORY}:${row.line})`)
      }
    }
    for (const f of matches) {
      listed.add(f)
      const actual = statusOf.get(f)
      if (!row.status) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` has no status; its file says ${actual ?? 'nothing'}`)
      else if (actual && row.status !== actual) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` is ${row.status} here, ${actual} in ${f}`)
      if (actual === 'deferred' && row.status === 'deferred') {
        const what = `${f} (${isPattern(f) ? 'reference' : 'component'})`
        const now = fingerprint(readFileSync(path.join(repo, f)))
        if (!row.mark) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` is deferred with no fingerprint — record the file's fingerprint on its line (--fingerprint)`)
        else if (row.mark !== now) pending.push(`${what}, changed since it was deferred (\`${row.mark}\`, now \`${now}\`) — put it to the human again`)
        else deferred.push(`${what} — ${INVENTORY}:${row.line}`)
      }
    }
  }
  if (existsSync(inventoryPath)) {
    for (const f of parts) if (!listed.has(f)) problems.push(`${f}: not in ${INVENTORY}`)
  }

  return {
    pending,
    deferred,
    problems,
    counts: {
      components: parts.filter(isComponent).length,
      references: references.length,
      screens: sources.filter((f) => isScreen(f, sourceDirs)).length,
      stylesheets: stylesheets.length,
      catalogue: rows.length,
      deferredLines,
      judged,
    },
  }
}

/** Blocks the inventory gained per screen added, read from git history: how many lines the
 * inventory's component tables grew in each commit that added a screen file. */
export function maturity(repo, { sourceDirs = sourceDirsOf(repo) } = {}) {
  const log = execFileSync('git', ['log', '--reverse', '--diff-filter=A', '--name-only', '--format=%H %ad', '--date=short', '--', '*.tsx'], { cwd: repo, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  const out = []
  let commit = null
  for (const line of log.split('\n')) {
    const h = line.match(/^([0-9a-f]{40}) (\d{4}-\d{2}-\d{2})$/)
    if (h) {
      commit = { sha: h[1], date: h[2], screens: [] }
      continue
    }
    if (commit && line && isScreen(line, sourceDirs)) commit.screens.push(line)
    if (commit && !line && commit.screens.length) {
      const numstat = execFileSync('git', ['show', '--numstat', '--format=', commit.sha, '--', INVENTORY], { cwd: repo, encoding: 'utf8' }).trim()
      const added = numstat ? Number(numstat.split('\t')[0]) || 0 : 0
      out.push({ date: commit.date, sha: commit.sha.slice(0, 7), screens: commit.screens.length, inventoryLinesAdded: added })
      commit = null
    }
  }
  return out
}

function main() {
  // The repository root, from this script's own place: .claude/skills/ui-patterns/scripts/.
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..')
  const args = process.argv.slice(2)
  if (args[0] === '--fingerprint') {
    if (!args[1]) {
      console.error('usage: check-ui-status.mjs --fingerprint <file>')
      process.exit(2)
    }
    console.log(fingerprint(readFileSync(path.resolve(args[1]))))
    return
  }
  if (args[0] === '--line-fingerprint') {
    const n = Number(args[2])
    if (!args[1] || !n) {
      console.error('usage: check-ui-status.mjs --line-fingerprint <file> <line>')
      process.exit(2)
    }
    const line = readFileSync(path.resolve(args[1]), 'utf8').split('\n')[n - 1]
    if (line === undefined) {
      console.error(`${args[1]} has no line ${n}`)
      process.exit(2)
    }
    console.log(fingerprint(lineCode(line)))
    return
  }
  if (args[0] === '--maturity') {
    const rows = maturity(repo)
    if (!rows.length) {
      console.log('maturity: no commit has added a screen file yet')
      return
    }
    console.log('date        commit   screens  inventory lines added')
    for (const r of rows) console.log(`${r.date}  ${r.sha}  ${String(r.screens).padStart(7)}  ${String(r.inventoryLinesAdded).padStart(21)}`)
    const recent = rows.slice(-10)
    const per = recent.reduce((n, r) => n + r.inventoryLinesAdded, 0) / recent.reduce((n, r) => n + r.screens, 0)
    console.log(`\nlast ${recent.length} commits adding screens: ${per.toFixed(1)} inventory lines per screen — a maturing system trends toward zero`)
    return
  }
  const { notApplicable, pending, deferred, problems, counts } = checkUiStatus(repo)
  if (notApplicable) {
    console.log(`✓ ${notApplicable}`)
    return
  }
  if (args.includes('--deferred')) {
    console.log(`Set aside by the human, not blocking (${deferred.length}):`)
    for (const p of deferred) console.log(`    ${p}`)
    return
  }
  const scanned = `scanned ${counts.components} components, ${counts.references} references, ${counts.screens} screens, ${counts.stylesheets} stylesheets and ${counts.catalogue} catalogue lines`
  if (pending.length) {
    console.error(`\n✗ UI awaiting the human's approval (${pending.length}):`)
    for (const p of pending) console.error(`    ${p}`)
  }
  if (problems.length) {
    console.error(`\n✗ UI status problems (${problems.length}):`)
    for (const p of problems) console.error(`    ${p}`)
  }
  if (deferred.length) console.log(`\n· ${deferred.length} UI set aside, not blocking — ask for the list (--deferred)`)
  if (pending.length || problems.length) {
    console.error(`\n  (${scanned})`)
    process.exit(1)
  }
  const aside = deferred.length ? `, ${deferred.length} set aside` : ''
  console.log(`✓ UI status: nothing awaiting approval, everything catalogued and every pointer real${aside}; ${scanned}`)
}

if (import.meta.main) main()
