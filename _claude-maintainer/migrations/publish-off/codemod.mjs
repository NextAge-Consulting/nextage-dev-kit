#!/usr/bin/env node
/**
 * Moves a project's `families.skip` pattern into the token CSS, as
 * `/* publish: off *\/` … `/* publish: on *\/` comment pairs.
 *
 *   node codemod.mjs [repoRoot] [--dry-run]
 *
 * It reads DESIGN_UI_PACKAGE and DESIGN_TOKEN_FILES from .claude/sync-substitutions.json
 * and the skip pattern from <UI package>/design-system/design-system.config.mjs. In each
 * token file, every run of declarations whose name the pattern matches is wrapped in one
 * pair, the comment lines directly above a declaration moving with it. Declarations
 * keep their order. A block written on one line is not rewritten; it is listed for hand
 * review. The config's `skip` key is left for the migration's prompt to delete: the
 * codemod does not rewrite JavaScript.
 *
 * Prints, per file, how many declarations it wrapped in how many pairs, and anything it
 * left for hand review. With --dry-run it writes nothing and prints the same report.
 */

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const args = process.argv.slice(2)
if (args.includes('--help') || args.includes('-h')) {
  console.log('usage: node codemod.mjs [repoRoot] [--dry-run]')
  process.exit(0)
}
const dryRun = args.includes('--dry-run')
const root = path.resolve(args.find((a) => !a.startsWith('--')) ?? '.')

const subsFile = path.join(root, '.claude/sync-substitutions.json')
if (!existsSync(subsFile)) fail(`${subsFile} not found — run this from a kit project's root`)
const subs = JSON.parse(readFileSync(subsFile, 'utf8'))
const pkg = String(subs.DESIGN_UI_PACKAGE ?? '').trim()
const tokenFiles = String(subs.DESIGN_TOKEN_FILES ?? '').split(/\s+/).filter(Boolean)
if (!pkg || !tokenFiles.length) {
  console.log('publish-off: no DESIGN_UI_PACKAGE or DESIGN_TOKEN_FILES — no design system, nothing to migrate')
  process.exit(0)
}
const configFile = path.join(root, pkg, 'design-system/design-system.config.mjs')
if (!existsSync(configFile)) {
  console.log(`publish-off: no ${path.relative(root, configFile)} — the project does not publish to Claude Design, nothing to migrate`)
  process.exit(0)
}
const skip = (await import(pathToFileURL(configFile).href)).default?.families?.skip
if (!skip) {
  console.log('publish-off: the config has no families.skip — nothing to migrate')
  process.exit(0)
}
if (!(skip instanceof RegExp)) fail(`families.skip in ${path.relative(root, configFile)} is not a RegExp`)

const DECL = /^(\s*)--([\w-]+)\s*:/
const COMMENT_LINE = /^\s*(\/\*.*\*\/|\/\*.*|.*\*\/|\*.*)\s*$/
let total = 0
for (const rel of tokenFiles) {
  const file = path.join(root, pkg, rel)
  if (!existsSync(file)) {
    console.log(`  ${rel}: not found — skipped`)
    continue
  }
  const { text, wrapped, pairs, review } = wrap(readFileSync(file, 'utf8'), skip)
  total += wrapped
  console.log(`  ${rel}: ${wrapped} declaration(s) in ${pairs} publish: off pair(s)`)
  for (const r of review) console.log(`    hand review: ${r}`)
  if (!dryRun && wrapped) writeFileSync(file, text)
}
console.log(`publish-off: ${total} declaration(s) marked${dryRun ? ' (dry run — nothing written)' : ''}. Delete families.skip from ${path.relative(root, configFile)}.`)

/** The token CSS with every run of skipped declarations wrapped in a pair. */
function wrap(css, pattern) {
  const lines = css.split('\n')
  const out = []
  const review = []
  let depth = 0
  let open = false
  let wrapped = 0
  let pairs = 0
  // The index in `out` where the comment lines directly above the next declaration begin.
  let lead = null
  for (const [i, line] of lines.entries()) {
    const opens = (line.match(/\{/g) ?? []).length
    const closes = (line.match(/\}/g) ?? []).length
    if (opens && closes && /--[\w-]+\s*:/.test(line) && [...line.matchAll(/--([\w-]+)\s*:/g)].some((m) => pattern.test(m[1])))
      review.push(`line ${i + 1}: a one-line block holding a skipped token`)
    const decl = depth > 0 && !opens && !closes ? DECL.exec(line) : null
    if (decl) {
      const skipped = pattern.test(decl[2])
      const at = lead ?? out.length
      if (skipped && !open) {
        out.splice(at, 0, `${decl[1]}/* publish: off */`)
        open = true
        pairs++
      } else if (!skipped && open) {
        out.splice(at, 0, `${decl[1]}/* publish: on */`)
        open = false
      }
      if (skipped) wrapped++
      out.push(line)
      lead = null
      continue
    }
    if (depth > 0 && COMMENT_LINE.test(line) && line.trim()) lead ??= out.length
    else lead = null
    if (closes && open && depth - closes + opens === 0) {
      const indent = /^(\s*)/.exec(out.findLast((l) => DECL.test(l)) ?? '  ')[1]
      out.push(`${indent}/* publish: on */`)
      open = false
    }
    depth += opens - closes
    out.push(line)
  }
  return { text: out.join('\n'), wrapped, pairs, review }
}

function fail(message) {
  console.error(`publish-off: ${message}`)
  process.exit(2)
}
