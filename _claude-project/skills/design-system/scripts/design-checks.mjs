/**
 * The design checks (references/design-checks.md), read for the tools that apply them.
 *
 *   readDesignChecks()  → [{ name, layer, title, wholeLayer }], in the file's order
 *   node design-checks.mjs --names [--review]
 *                       prints the check names one per line; --review leaves out the checks
 *                       marked *Whole layer*, which a review of one change cannot judge
 *
 * Read from this script's own place, so the kit and every project resolve the same file.
 */

import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const DESIGN_CHECKS = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../references/design-checks.md')

/** The checks of a design-checks text: each `### NAME — title` under a `## <n>. <layer>` heading. */
export function parseDesignChecks(text) {
  const checks = []
  let layer = null
  let current = null
  for (const line of text.split('\n')) {
    const section = line.match(/^## (\d+)\. /)
    if (section) {
      layer = Number(section[1])
      current = null
      continue
    }
    if (/^## /.test(line)) {
      layer = null
      current = null
      continue
    }
    const check = layer && line.match(/^### ([A-Z][A-Z-]*[A-Z]) — (.+)$/)
    if (check) {
      current = { name: check[1], layer, title: check[2].trim(), wholeLayer: false }
      checks.push(current)
      continue
    }
    if (current && /^\*Whole layer\.\*/.test(line)) current.wholeLayer = true
  }
  return checks
}

export function readDesignChecks(file = DESIGN_CHECKS) {
  if (!existsSync(file)) throw new Error(`${file}: the design checks are missing`)
  const checks = parseDesignChecks(readFileSync(file, 'utf8'))
  if (!checks.length) throw new Error(`${file}: no checks found under its numbered layer headings`)
  const dup = checks.map((c) => c.name).find((n, i, all) => all.indexOf(n) !== i)
  if (dup) throw new Error(`${file}: the check ${dup} is named twice`)
  return checks
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv.includes('--names')) {
    console.error('usage: node design-checks.mjs --names [--review]')
    process.exit(2)
  }
  try {
    const review = process.argv.includes('--review')
    console.log(readDesignChecks().filter((c) => !(review && c.wholeLayer)).map((c) => c.name).join('\n'))
  } catch (err) {
    console.error(`design checks: ${err.message}`)
    process.exit(1)
  }
}
