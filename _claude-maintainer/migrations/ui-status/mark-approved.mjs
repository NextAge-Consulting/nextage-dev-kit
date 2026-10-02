#!/usr/bin/env node
/**
 * Marks every component and pattern reference a project already has as approved —
 * the one-time step that brings an existing project onto the UI status check
 * (.claude/skills/ui-patterns/scripts/check-ui-status.mjs).
 *
 *   node mark-approved.mjs [repoRoot] [--dry-run]
 *
 * A component gets `// ui-status: approved` as its first line. A pattern reference
 * gets `ui-status: approved` in its frontmatter, which is added when it has none.
 * A file already carrying a ui-status line is left alone, so a pending one stays
 * pending. Prints each file it marks; with --dry-run it writes nothing.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { isComponent, isPattern } from '../../../_claude-project/skills/ui-patterns/scripts/check-ui-status.mjs'

export function markText(file, text) {
  if (/ui-status:/.test(text)) return null
  if (isComponent(file)) return `// ui-status: approved\n${text}`
  if (text.startsWith('---\n')) return text.replace('---\n', '---\nui-status: approved\n')
  return `---\nui-status: approved\n---\n\n${text}`
}

export function markApproved(root, { dryRun = false } = {}) {
  const out = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard'], {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  })
  const marked = []
  for (const file of out.split('\0').filter(Boolean)) {
    if (!(isComponent(file) || isPattern(file)) || !existsSync(path.join(root, file))) continue
    const next = markText(file, readFileSync(path.join(root, file), 'utf8'))
    if (next === null) continue
    if (!dryRun) writeFileSync(path.join(root, file), next)
    marked.push(file)
  }
  return marked
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const args = process.argv.slice(2)
  const dryRun = args.includes('--dry-run')
  const root = path.resolve(args.find((a) => !a.startsWith('--')) ?? '.')
  const marked = markApproved(root, { dryRun })
  for (const f of marked) console.log(`  ${f}`)
  console.log(`${dryRun ? 'Would mark' : 'Marked'} ${marked.length} file(s) approved.`)
}
