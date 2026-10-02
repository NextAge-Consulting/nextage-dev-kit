// node --test _claude-maintainer/migrations/ui-status/mark-approved.test.mjs
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { markApproved, markText } from './mark-approved.mjs'

const dirs = []
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
})

const COMP = 'src/components/card.tsx'
const REF = '.claude/skills/ui-patterns/references/browse-layout.md'

test('a component gets the status as its first line', () => {
  assert.equal(markText(COMP, '"use client"\n'), '// ui-status: approved\n"use client"\n')
})

test('a pattern gets it in its frontmatter, which is added when missing', () => {
  assert.equal(markText(REF, '---\nx: 1\n---\n# B\n'), '---\nui-status: approved\nx: 1\n---\n# B\n')
  assert.equal(markText(REF, '# B\n'), '---\nui-status: approved\n---\n\n# B\n')
})

test('a file already carrying a status is left alone', () => {
  assert.equal(markText(COMP, '// ui-status: pending\n'), null)
})

test('marks every unmarked component and pattern in a repository; --dry-run writes nothing', () => {
  const root = mkdtempSync(join(tmpdir(), 'mark-approved-'))
  dirs.push(root)
  const put = (f, t) => {
    mkdirSync(dirname(join(root, f)), { recursive: true })
    writeFileSync(join(root, f), t)
  }
  put(COMP, 'export {}\n')
  put(REF, '# Browse\n')
  put('src/routes/index.tsx', 'export {}\n')
  put('src/components/pending.tsx', '// ui-status: pending\n')
  execFileSync('git', ['init', '-q'], { cwd: root })

  assert.deepEqual(markApproved(root, { dryRun: true }).sort(), [REF, COMP].sort())
  assert.equal(readFileSync(join(root, COMP), 'utf8'), 'export {}\n')

  assert.deepEqual(markApproved(root).sort(), [REF, COMP].sort())
  assert.equal(readFileSync(join(root, COMP), 'utf8'), '// ui-status: approved\nexport {}\n')
  assert.equal(readFileSync(join(root, 'src/components/pending.tsx'), 'utf8'), '// ui-status: pending\n')
  assert.deepEqual(markApproved(root), [])
})
