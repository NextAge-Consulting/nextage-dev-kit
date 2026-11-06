import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { addHeader, migrate, renameStatus, rewriteInventory } from './codemod.mjs'

test('the status rename touches only the word, in a comment or frontmatter', () => {
  assert.equal(renameStatus('// ui-status: unresolved\nx\n'), '// ui-status: deferred\nx\n')
  assert.equal(renameStatus('---\nui-status:  unresolved\n---\n'), '---\nui-status:  deferred\n---\n')
  assert.equal(renameStatus('// ui-status: approved\n'), null)
})

test('the inventory: deferred cells lose their reason, and the Fit check column goes', () => {
  const inv = [
    '| Component | Use for | Type | Status | Fit check |',
    '|---|---|---|---|---|',
    '| `a` | x | Row | unresolved `1a2b3c4d` awaiting review | |',
    '| `b` | y | Row | pending | `9f9f9f9f` new; nearest Row |',
    '',
    '| Atom | Status |',
    '|---|---|',
    '| `button` | approved |',
  ].join('\n')
  assert.equal(
    rewriteInventory(inv),
    ['| Component | Use for | Type | Status |', '|---|---|---|---|', '| `a` | x | Row | deferred `1a2b3c4d` |', '| `b` | y | Row | pending |', '', '| Atom | Status |', '|---|---|', '| `button` | approved |'].join('\n'),
  )
  assert.equal(rewriteInventory('| A | B |\n|---|---|\n| `x` | approved |\n'), null)
})

test('a header is added under the status line once, never over an existing one', () => {
  assert.equal(addHeader('// ui-status: approved\nexport const X = 1\n', { type: 'Row' }), '// ui-status: approved\n// ui-block: Row\nexport const X = 1\n')
  assert.equal(addHeader('// ui-status: approved\n', { atom: true }), '// ui-status: approved\n// ui-atom\n')
  assert.equal(addHeader('// ui-status: approved\n// ui-block: Row\n', { type: 'Pager' }), null)
  assert.equal(addHeader('// ui-status: approved\n', {}), null)
})

test('over a repository: renames, headers from the inventory, and the report of what is left', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'uxes-codemod-'))
  const files = {
    '.claude/sync-substitutions.json': JSON.stringify({ DESIGN_VENDORED_DIR: 'packages/ui/src/components/ui' }),
    'packages/ui/src/components/ui/button.tsx': '// ui-status: approved\nexport const Button = 1\n',
    'packages/ui/src/components/review-dialog.tsx': '// ui-status: unresolved\nexport const ReviewDialog = 1\n',
    'packages/ui/src/components/fact-list.tsx': '// ui-status: approved\nexport const FactList = 1\n',
    'apps/web/src/routes/orders.tsx': 'export const O = 1\n',
    'apps/web/src/routes/users.tsx': '// ui-recipe: browse.md\nexport const U = 1\n',
    '.claude/skills/ui-patterns/references/browse.md': '---\nblock-types: [BrowseScreen]\nui-status: unresolved\n---\n',
    '.claude/skills/ui-patterns/references/saving.md': '---\nkind: behaviour\ncode: []\nblock-types: cross-cutting\nui-status: approved\n---\n',
    '.claude/rules/project/ui-inventory.md': '| Component | Use for | Type | Status | Fit check |\n|---|---|---|---|---|\n| `review-dialog` | x | ReviewDialog | unresolved `1a2b3c4d` later | |\n| `fact-list` | y | <none> | approved | |\n\n| File | Governs | Status |\n|---|---|---|\n| `browse.md` | x | unresolved `2b2b2b2b` wait |\n',
  }
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), content)
  }
  execFileSync('git', ['init', '-q'], { cwd: dir })
  const dry = migrate(dir, { dryRun: true })
  assert.equal(fs.readFileSync(path.join(dir, 'packages/ui/src/components/review-dialog.tsx'), 'utf8'), files['packages/ui/src/components/review-dialog.tsx'], 'dry run writes nothing')
  const r = migrate(dir)
  assert.deepEqual(r, dry)
  assert.deepEqual(r.renamed.sort(), ['.claude/skills/ui-patterns/references/browse.md', 'packages/ui/src/components/review-dialog.tsx'])
  assert.deepEqual(r.headers.sort(), ['packages/ui/src/components/review-dialog.tsx → ui-block: ReviewDialog', 'packages/ui/src/components/ui/button.tsx → ui-atom'])
  assert.deepEqual(r.untyped, ['packages/ui/src/components/fact-list.tsx (inventory says <none>)'])
  assert.deepEqual(r.unheadedScreens, ['apps/web/src/routes/orders.tsx'])
  assert.deepEqual(r.unkinded, ['.claude/skills/ui-patterns/references/browse.md'])
  assert.equal(r.inventory, true)
  assert.equal(fs.readFileSync(path.join(dir, 'packages/ui/src/components/review-dialog.tsx'), 'utf8'), '// ui-status: deferred\n// ui-block: ReviewDialog\nexport const ReviewDialog = 1\n')
  const inv = fs.readFileSync(path.join(dir, '.claude/rules/project/ui-inventory.md'), 'utf8')
  assert.match(inv, /\| `review-dialog` \| x \| ReviewDialog \| deferred `1a2b3c4d` \|/)
  assert.match(inv, /\| `browse\.md` \| x \| deferred `2b2b2b2b` \|/)
  assert.doesNotMatch(inv, /Fit check/)
})
