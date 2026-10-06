#!/usr/bin/env node
/**
 * No UI becomes law until a human has approved it.
 *
 *   node .claude/skills/ui-patterns/scripts/check-ui-status.mjs
 *
 * Every component (a .tsx under a `components/` folder outside `features/`) and every
 * pattern reference (.claude/skills/ui-patterns/references/*.md) carries exactly one line
 * `ui-status: approved` or `ui-status: pending`. A token awaiting approval carries
 * `ui-status: pending` in its comment. The UI inventory
 * (.claude/rules/project/ui-inventory.md) lists every component and pattern with the
 * same status its file carries.
 *
 * Fails, naming each, on:
 *   pending     a component, pattern or token still awaiting the human's approval;
 *   unmarked    a component or pattern with no status line, more than one, or an
 *               unknown value;
 *   catalogue   a component or pattern the inventory does not list, a line whose
 *               status differs from its file's, or a status line naming no file;
 *   block type  a component's line — every component but a vendored atom — with no
 *               Type, or one not on the design-system skill's references/block-types.md
 *               and not `<none>`; a pattern with no `block-types:` frontmatter line, or
 *               one naming a type not on the list and not `cross-cutting`.
 *
 * /deploy refuses while it fails; /work and /handoff run it to show what awaits
 * review. Prints what it inspected, and passes saying it does not apply when the
 * project has no component or pattern files.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { CROSS_CUTTING, NO_TYPE, readBlockTypes } from '../../design-system/scripts/block-types.mjs'

export const INVENTORY = '.claude/rules/project/ui-inventory.md'
const REFERENCES = '.claude/skills/ui-patterns/references/'
const STATUS = /ui-status:\s*([A-Za-z-]+)/g
const VALUES = new Set(['approved', 'pending'])

export const NOT_APPLICABLE = 'UI status does not apply: this project has no component or pattern files'

/** Every tracked or new file, gitignored ones left out. */
function repoFiles(repo) {
  const out = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], {
    cwd: repo,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  })
  return [...new Set(out.split('\0').filter(Boolean))].filter((f) => existsSync(path.join(repo, f)))
}

export function isComponent(file) {
  if (!file.endsWith('.tsx') || /\.(test|spec|stories)\.tsx$/.test(file)) return false
  const parts = file.split('/')
  // A feature folder holds one screen's content, never a part — whatever it names a subfolder.
  return parts.includes('components') && !parts.includes('features') && !parts.includes('node_modules')
}

/** A vendored atom, which carries no block type: under DESIGN_VENDORED_DIR, or a
 * `components/ui/` folder when the key is not set. */
function atomTest(repo) {
  const file = path.join(repo, '.claude/sync-substitutions.json')
  const dir = existsSync(file) ? String(JSON.parse(readFileSync(file, 'utf8')).DESIGN_VENDORED_DIR ?? '').trim().replace(/\/$/, '') : ''
  return dir ? (f) => f.startsWith(`${dir}/`) : (f) => f.includes('components/ui/')
}

/** A pattern's `block-types:` frontmatter value as a list, or null when it has none. */
export function patternBlockTypes(text) {
  const front = text.match(/^---\n([\s\S]*?)\n---/)?.[1] ?? ''
  const line = front.match(/^block-types:\s*(.*)$/m)
  if (!line) return null
  return line[1].replace(/[[\]]/g, '').split(',').map((t) => t.trim()).filter(Boolean)
}

/** A pattern reference: any .md directly under references/ except the kit's own README. */
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

/** Inventory table rows: the first backticked name in the first cell, a status cell if
 * any, and the cell under a `Type` header when the table has one. */
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
    const status = cells.slice(1).map((c) => c.replace(/[*_]/g, '').trim().toLowerCase()).find((c) => VALUES.has(c))
    const at = header ? header.indexOf('Type') : -1
    rows.push({ name, status, line: i + 1, ...(at > 0 ? { type: cells[at]?.replace(/[`*]/g, '').trim() ?? '' } : {}) })
  })
  return rows
}

export function checkUiStatus(repo, { files = repoFiles(repo) } = {}) {
  const parts = files.filter((f) => isComponent(f) || isPattern(f))
  const stylesheets = files.filter((f) => f.endsWith('.css') && !f.split('/').includes('node_modules'))
  if (parts.length === 0) return { notApplicable: NOT_APPLICABLE }

  const pending = []
  const problems = []
  const statusOf = new Map()
  const isAtom = atomTest(repo)
  let types = null
  try {
    types = readBlockTypes().names
  } catch (err) {
    problems.push(`${err.message} — block types cannot be checked`)
  }

  for (const f of parts) {
    const found = statuses(readFileSync(path.join(repo, f), 'utf8'))
    if (found.length === 0) problems.push(`${f}: no ui-status line`)
    else if (found.length > 1) problems.push(`${f}: ${found.length} ui-status lines (lines ${found.map((s) => s.line).join(', ')}); a file carries one`)
    else if (!VALUES.has(found[0].value)) problems.push(`${f}:${found[0].line}: ui-status "${found[0].value}" is neither approved nor pending`)
    else {
      statusOf.set(f, found[0].value)
      if (found[0].value === 'pending') pending.push(`${f} (${isPattern(f) ? 'pattern' : 'component'})`)
    }
  }

  for (const f of parts.filter(isPattern)) {
    const named = patternBlockTypes(readFileSync(path.join(repo, f), 'utf8'))
    if (!named?.length) problems.push(`${f}: no block-types line — list the block types it governs in its frontmatter, or ${CROSS_CUTTING}`)
    else if (types)
      for (const t of named) if (t !== CROSS_CUTTING && !types.has(t)) problems.push(`${f}: block-types names \`${t}\`, which is not on the block-type list`)
  }

  for (const f of stylesheets) {
    readFileSync(path.join(repo, f), 'utf8').split('\n').forEach((line, i, lines) => {
      if (!/ui-status:\s*pending/.test(line)) return
      const decl = [line, lines[i + 1] ?? ''].join(' ').match(/(--[\w-]+)\s*:/)
      pending.push(`${f}:${i + 1} (token${decl ? ` ${decl[1]}` : ''})`)
    })
  }

  const inventoryPath = path.join(repo, INVENTORY)
  let rows = []
  if (!existsSync(inventoryPath)) problems.push(`${INVENTORY}: missing — the catalogue of components and patterns`)
  else rows = catalogueRows(readFileSync(inventoryPath, 'utf8'))

  const listed = new Set()
  for (const row of rows) {
    const byPath = row.name.includes('/')
    const want = key(row.name.split('/').at(-1))
    // A row naming a .md file is a pattern; any other names a component.
    const kind = row.name.endsWith('.md') ? isPattern : isComponent
    const matches = parts.filter((f) => kind(f) && fileKey(f) === want && (!byPath || key(f).endsWith(key(row.name))))
    if (matches.length === 0) {
      if (row.status) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` has a status but no component or pattern file is named that`)
      continue
    }
    if (kind === isComponent && matches.some((f) => !isAtom(f))) {
      if (!row.type) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` has no block type — name its type from the block-type list in a Type column, or ${NO_TYPE}`)
      else if (types && row.type !== NO_TYPE && !types.has(row.type)) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` names block type \`${row.type}\`, which is not on the block-type list`)
    }
    for (const f of matches) {
      listed.add(f)
      const actual = statusOf.get(f)
      if (!row.status) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` has no status; its file says ${actual ?? 'nothing'}`)
      else if (actual && row.status !== actual) problems.push(`${INVENTORY}:${row.line}: \`${row.name}\` is ${row.status} here, ${actual} in ${f}`)
    }
  }
  if (existsSync(inventoryPath)) {
    for (const f of parts) if (!listed.has(f)) problems.push(`${f}: not in ${INVENTORY}`)
  }

  return {
    pending,
    problems,
    counts: {
      components: parts.filter(isComponent).length,
      patterns: parts.filter(isPattern).length,
      stylesheets: stylesheets.length,
      catalogue: rows.length,
    },
  }
}

function main() {
  // The repository root, from this script's own place: .claude/skills/ui-patterns/scripts/.
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..')
  const { notApplicable, pending, problems, counts } = checkUiStatus(repo)
  if (notApplicable) {
    console.log(`✓ ${notApplicable}`)
    return
  }
  const scanned = `scanned ${counts.components} components, ${counts.patterns} patterns, ${counts.stylesheets} stylesheets and ${counts.catalogue} catalogue lines`
  if (pending.length) {
    console.error(`\n✗ UI awaiting the human's approval (${pending.length}):`)
    for (const p of pending) console.error(`    ${p}`)
  }
  if (problems.length) {
    console.error(`\n✗ UI status problems (${problems.length}):`)
    for (const p of problems) console.error(`    ${p}`)
  }
  if (pending.length || problems.length) {
    console.error(`\n  (${scanned})`)
    process.exit(1)
  }
  console.log(`✓ UI status: everything approved and catalogued; ${scanned}`)
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) main()
