#!/usr/bin/env node
/**
 * The mechanical half of the User Experience System migration: what changes nothing a
 * user sees or the app does, written by code so the session spends its time on the rest.
 *
 *   node codemod.mjs [repoRoot] [--dry-run]
 *
 * - `ui-status: unresolved` becomes `ui-status: deferred` in every component and
 *   reference, and on every inventory line, where the reason that followed the
 *   fingerprint is dropped: deferring needs none.
 * - The inventory's Fit check column is removed, header, divider and cells.
 * - Every component whose inventory line names a block type on the kit's list gains
 *   `// ui-block: <Type>` under its status line; every vendored atom gains `// ui-atom`.
 *   A component that already carries a header is left alone.
 *
 * Prints what it changed, and what it left for the session: components with no type on
 * the list, screens with no `// ui-recipe` or `// ui-content`, references with no
 * `kind:`. With --dry-run it writes nothing and prints the same report.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { readBlockTypes } from '../../../_claude-project/skills/design-system/scripts/block-types.mjs'
import { catalogueRows, frontmatter, headers, INVENTORY, isComponent, isPattern, isScreen, key } from '../../../_claude-project/skills/ui-patterns/scripts/check-ui-status.mjs'

/** Every tracked or new file. */
function repoFiles(root) {
  const out = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], { cwd: root, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 })
  return [...new Set(out.split('\0').filter(Boolean))].filter((f) => existsSync(path.join(root, f)))
}

/** The status rename in a file's text; null when nothing changes. */
export function renameStatus(text) {
  const next = text.replace(/ui-status:(\s*)unresolved\b/g, 'ui-status:$1deferred')
  return next === text ? null : next
}

/** The inventory with `unresolved` cells renamed and reasons dropped, and the Fit check column gone. */
export function rewriteInventory(text) {
  const lines = text.split('\n')
  let fitAt = -1
  let changed = false
  const out = lines.map((line) => {
    if (!line.trimStart().startsWith('|')) {
      fitAt = -1
      return line
    }
    let cells = line.split('|')
    const inner = cells.slice(1, -1)
    const isDivider = inner.every((c) => /^\s*:?-+:?\s*$/.test(c))
    const header = inner.map((c) => c.replace(/[*_]/g, '').trim())
    if (fitAt === -1 && !isDivider && header.includes('Fit check')) fitAt = header.indexOf('Fit check')
    if (fitAt >= 0 && inner.length > fitAt) {
      inner.splice(fitAt, 1)
      cells = [cells[0], ...inner, cells.at(-1)]
      changed = true
    }
    const next = cells.map((c) => c.replace(/(\s*)unresolved(\s+`[0-9a-f]{8}`)[^|]*/i, (_, lead, fp) => `${lead}deferred${fp} `))
    if (next.join('|') !== cells.join('|')) changed = true
    return next.join('|')
  })
  return changed ? out.join('\n') : null
}

/** A component's text with its block header added under the status line; null when it has one or none fits. */
export function addHeader(text, { type = null, atom = false } = {}) {
  const h = headers(text)
  if (h.block || h.atom) return null
  const line = atom ? '// ui-atom' : type ? `// ui-block: ${type}` : null
  if (!line) return null
  const lines = text.split('\n')
  const at = lines.findIndex((l) => /ui-status:/.test(l))
  lines.splice(at >= 0 ? at + 1 : 0, 0, line)
  return lines.join('\n')
}

export function migrate(root, { dryRun = false } = {}) {
  const files = repoFiles(root)
  const read = (f) => readFileSync(path.join(root, f), 'utf8')
  const write = (f, text) => {
    if (!dryRun) writeFileSync(path.join(root, f), text)
  }
  const report = { renamed: [], headers: [], inventory: false, untyped: [], unheadedScreens: [], unkinded: [] }
  const subsFile = path.join(root, '.claude/sync-substitutions.json')
  const subs = existsSync(subsFile) ? JSON.parse(readFileSync(subsFile, 'utf8')) : {}
  const vendored = String(subs.DESIGN_VENDORED_DIR ?? '').trim().replace(/\/$/, '')
  const isAtom = vendored ? (f) => f.startsWith(`${vendored}/`) : (f) => f.includes('components/ui/')
  let types = new Set()
  try {
    types = readBlockTypes().names
  } catch {}

  const inventoryText = files.includes(INVENTORY) ? read(INVENTORY) : ''
  const rows = catalogueRows(inventoryText)
  const typeFor = (file) => {
    const parts = file.split('/')
    const base = parts.at(-1).replace(/\.tsx$/, '')
    const k = key(base === 'index' ? parts.at(-2) : base)
    return rows.find((r) => !r.name.endsWith('.md') && key(r.name.split('/').at(-1)) === k)?.type ?? null
  }

  for (const f of files) {
    if (!(isComponent(f) || isPattern(f))) continue
    let text = read(f)
    const renamed = renameStatus(text)
    if (renamed) {
      text = renamed
      report.renamed.push(f)
    }
    if (isComponent(f)) {
      const type = typeFor(f)
      const withHeader = addHeader(text, isAtom(f) ? { atom: true } : { type: type && types.has(type) ? type : null })
      if (withHeader) {
        text = withHeader
        report.headers.push(`${f} → ${isAtom(f) ? 'ui-atom' : `ui-block: ${type}`}`)
      } else if (!isAtom(f) && !headers(text).block) report.untyped.push(`${f}${type ? ` (inventory says ${type})` : ''}`)
    } else if (!['recipe', 'behaviour'].includes(frontmatter(text)?.kind)) report.unkinded.push(f)
    if (text !== read(f)) write(f, text)
  }
  for (const f of files) {
    if (!isScreen(f, null)) continue
    const h = headers(read(f))
    if (!h.recipe && !h.content) report.unheadedScreens.push(f)
  }
  if (inventoryText) {
    const next = rewriteInventory(inventoryText)
    if (next) {
      report.inventory = true
      write(INVENTORY, next)
    }
  }
  return report
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const dryRun = args.includes('--dry-run')
  const root = path.resolve(args.find((a) => !a.startsWith('--')) ?? '.')
  const r = migrate(root, { dryRun })
  const verb = dryRun ? 'would' : 'did'
  console.log(`uxes-model codemod (${dryRun ? 'dry run — nothing written' : 'applied'}):`)
  console.log(`  ${verb} rename unresolved → deferred in ${r.renamed.length} file(s)${r.inventory ? ', and rewrite the inventory (deferred cells, Fit check column removed)' : ''}`)
  console.log(`  ${verb} add a header to ${r.headers.length} component(s):`)
  for (const h of r.headers) console.log(`    ${h}`)
  console.log(`  left for the session — components with no type on the list (${r.untyped.length}):`)
  for (const u of r.untyped) console.log(`    ${u}`)
  console.log(`  left for the session — screens with no // ui-recipe or // ui-content (${r.unheadedScreens.length}):`)
  for (const u of r.unheadedScreens) console.log(`    ${u}`)
  console.log(`  left for the session — references with no kind: (${r.unkinded.length}):`)
  for (const u of r.unkinded) console.log(`    ${u}`)
}
