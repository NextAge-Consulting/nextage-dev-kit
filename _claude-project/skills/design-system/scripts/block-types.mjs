/**
 * The block-type list (references/block-types.md), read for the checks that enforce it.
 *
 *   names   every type a part or a pattern may name;
 *   frames  each frame atom (a Wraps cell) with the types that wrap it.
 *
 * Read from this script's own place, so the kit and every project resolve the same file.
 */

import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const BLOCK_TYPES = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../references/block-types.md')

/** A recipe or behaviour rule that governs every type. */
export const CROSS_CUTTING = 'cross-cutting'

/** The types, frame atoms, definitions and neighbours of a block-type list's text: every
 * table whose first header is `Type`. `neighbours` holds each type's "Not to be confused
 * with" column as type names; `definitions` each type's "What it is". */
export function parseBlockTypes(text) {
  const names = new Set()
  const frames = new Map()
  const neighbours = new Map()
  const definitions = new Map()
  let header = null
  for (const line of text.split('\n')) {
    if (!line.trimStart().startsWith('|')) {
      header = null
      continue
    }
    const cells = line.split('|').slice(1, -1).map((c) => c.trim())
    if (cells.every((c) => /^:?-+:?$/.test(c))) continue
    if (!header) {
      header = cells
      continue
    }
    if (header[0] !== 'Type' || !cells[0]) continue
    names.add(cells[0])
    const wraps = cells[header.indexOf('Wraps')]
    if (header.includes('Wraps') && wraps) frames.set(wraps, [...(frames.get(wraps) ?? []), cells[0]])
    const what = cells[header.indexOf('What it is')]
    if (what) definitions.set(cells[0], what)
    const confused = cells[header.indexOf('Not to be confused with')]
    if (confused) neighbours.set(cells[0], confused.split(';').map((c) => c.replace(/\(.*?\)/g, '').trim()).filter(Boolean))
  }
  return { names, frames, neighbours, definitions }
}

export function readBlockTypes(file = BLOCK_TYPES) {
  if (!existsSync(file)) throw new Error(`${file}: the block-type list is missing`)
  const list = parseBlockTypes(readFileSync(file, 'utf8'))
  if (!list.names.size) throw new Error(`${file}: no block types found in its tables`)
  return list
}

/** The module an atom lives in, as shadcn names it: `AlertDialog` → `alert-dialog`. */
export const atomModule = (atom) => atom.replace(/(?<=[a-z0-9])([A-Z])/g, '-$1').toLowerCase()
