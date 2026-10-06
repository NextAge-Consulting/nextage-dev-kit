import { after, test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { catalogueRows, checkUiStatus, INVENTORY, isComponent, isPattern, key, NOT_APPLICABLE, patternBlockTypes } from './check-ui-status.mjs'

const dirs = []
after(() => {
  for (const d of dirs) fs.rmSync(d, { recursive: true, force: true })
})

function repo(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ui-status-'))
  dirs.push(dir)
  for (const [f, text] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, f)), { recursive: true })
    fs.writeFileSync(path.join(dir, f), text)
  }
  return { dir, files: Object.keys(files) }
}

function run(files) {
  const r = repo(files)
  return checkUiStatus(r.dir, { files: r.files })
}

const BUTTON = 'packages/ui/src/components/ui/button.tsx'
const ICON = 'packages/ui/src/components/icon-button.tsx'
const BROWSE = '.claude/skills/ui-patterns/references/browse-layout.md'

const INV = (rows) =>
  `# UI Inventory\n\n| Component | Use for | Status | Type |\n|---|---|---|---|\n${rows.split('\n').map((r) => `${r} ModalShell |`).join('\n')}\n`

test('everything approved and catalogued passes, with counts', () => {
  const out = run({
    [BUTTON]: '// ui-status: approved\nexport function Button() {}\n',
    [ICON]: '// ui-status: approved\n',
    [BROWSE]: '---\nblock-types: [BrowseScreen, Pager]\nui-status: approved\n---\n# Browse\n',
    [INVENTORY]: INV('| `button` | actions | approved |\n| `IconButton` | icon-only | approved |\n| `browse-layout.md` | lists | approved |'),
  })
  assert.deepEqual(out.pending, [])
  assert.deepEqual(out.problems, [])
  assert.deepEqual(out.counts, { components: 2, patterns: 1, stylesheets: 0, catalogue: 3 })
})

test('no component or pattern files: does not apply', () => {
  assert.equal(run({ 'src/index.ts': 'export {}\n' }).notApplicable, NOT_APPLICABLE)
})

test('pending components, patterns and tokens are listed', () => {
  const out = run({
    [ICON]: '// ui-status: pending\n',
    [BROWSE]: '---\nblock-types: [BrowseScreen, Pager]\nui-status: pending\n---\n',
    'packages/ui/src/tokens.css': ':root {\n  /* a hover fill inside a card · ui-status: pending */\n  --card-hover: oklch(0.9 0 0);\n}\n',
    [INVENTORY]: INV('| `IconButton` | x | pending |\n| `browse-layout.md` | x | pending |'),
  })
  assert.deepEqual(out.problems, [])
  assert.deepEqual(out.pending, [
    `${ICON} (component)`,
    `${BROWSE} (pattern)`,
    'packages/ui/src/tokens.css:2 (token --card-hover)',
  ])
})

test('a part with no status, two, or an unknown value fails', () => {
  const out = run({
    [BUTTON]: 'export function Button() {}\n',
    [ICON]: '// ui-status: approved\n// ui-status: pending\n',
    [BROWSE]: '---\nblock-types: [BrowseScreen, Pager]\nui-status: draft\n---\n',
    [INVENTORY]: INV('| `button` | x | approved |\n| `IconButton` | x | approved |\n| `browse-layout.md` | x | approved |'),
  })
  assert.deepEqual(out.problems, [
    `${BUTTON}: no ui-status line`,
    `${ICON}: 2 ui-status lines (lines 1, 2); a file carries one`,
    `${BROWSE}:3: ui-status "draft" is neither approved nor pending`,
  ])
})

test('the catalogue must list every part with the status its file carries', () => {
  const out = run({
    [BUTTON]: '// ui-status: approved\n',
    [ICON]: '// ui-status: pending\n',
    [BROWSE]: '---\nblock-types: [BrowseScreen, Pager]\nui-status: approved\n---\n',
    [INVENTORY]: INV('| `IconButton` | x | approved |\n| `button` | x | |\n| `Ghost` | x | pending |'),
  })
  assert.deepEqual(out.problems, [
    `${INVENTORY}:5: \`IconButton\` is approved here, pending in ${ICON}`,
    `${INVENTORY}:6: \`button\` has no status; its file says approved`,
    `${INVENTORY}:7: \`Ghost\` has a status but no component or pattern file is named that`,
    `${BROWSE}: not in ${INVENTORY}`,
  ])
})

test('a missing inventory fails', () => {
  const out = run({ [BUTTON]: '// ui-status: approved\n' })
  assert.deepEqual(out.problems, [`${INVENTORY}: missing — the catalogue of components and patterns`])
})

test('a path in the catalogue picks one of two same-named files', () => {
  const app = 'apps/web/src/components/form/fields.tsx'
  const other = 'apps/admin/src/components/fields.tsx'
  const out = run({
    [app]: '// ui-status: approved\n',
    [other]: '// ui-status: pending\n',
    [INVENTORY]: INV('| `form/fields` | x | approved |'),
  })
  assert.deepEqual(out.problems, [`${other}: not in ${INVENTORY}`])
})

test('a pattern and a component sharing a name are matched by kind', () => {
  const notice = 'src/components/failure-notice.tsx'
  const ref = '.claude/skills/ui-patterns/references/failure-notice.md'
  const out = run({
    [notice]: '// ui-status: pending\n',
    [ref]: '---\nblock-types: [BrowseScreen, Pager]\nui-status: approved\n---\n',
    [INVENTORY]: INV('| `failure-notice.md` | x | approved |\n| `FailureNotice` | x | pending |'),
  })
  assert.deepEqual(out.problems, [])
  assert.deepEqual(out.pending, [`${notice} (component)`])
})

test('component and pattern recognition, and name keys', () => {
  assert.ok(isComponent('apps/web/src/components/x.tsx'))
  assert.ok(!isComponent('apps/web/src/components/x.test.tsx'))
  assert.ok(!isComponent('apps/web/src/routes/x.tsx'))
  assert.ok(!isComponent('apps/web/src/components/x.ts'))
  assert.ok(!isComponent('apps/web/src/features/orders/components/x.tsx'))
  assert.ok(isPattern(BROWSE))
  assert.ok(!isPattern('.claude/skills/ui-patterns/references/sub/x.md'))
  assert.ok(!isPattern('.claude/skills/ui-patterns/references/README.md'))
  assert.equal(key('IconButton'), key('icon-button.tsx'))
  assert.deepEqual(catalogueRows('| `a` | b | **Pending** |\n|---|---|---|\n| plain | x |'), [{ name: 'a', status: 'pending', line: 1 }])
})

test('a component line names a block type from the list or <none>; a vendored atom needs none', () => {
  const rows = [
    '| Component | Use for | Type | Status |',
    '|---|---|---|---|',
    '| `IconButton` | x | | approved |',
    '| `review-dialog` | x | ReviewDialog | approved |',
    '| `fact-list` | x | <none> | approved |',
    '| `invoice-dialog` | x | InvoiceDialog | approved |',
    '',
    '| Atom | Status |',
    '|---|---|',
    '| `button` | approved |',
  ].join('\n')
  const out = run({
    [BUTTON]: '// ui-status: approved\n',
    [ICON]: '// ui-status: approved\n',
    'packages/ui/src/components/review-dialog.tsx': '// ui-status: approved\n',
    'packages/ui/src/components/fact-list.tsx': '// ui-status: approved\n',
    'packages/ui/src/components/invoice-dialog.tsx': '// ui-status: approved\n',
    [INVENTORY]: `# UI Inventory\n\n${rows}\n`,
  })
  assert.deepEqual(out.problems, [
    `${INVENTORY}:5: \`IconButton\` has no block type — name its type from the block-type list in a Type column, or <none>`,
    `${INVENTORY}:8: \`invoice-dialog\` names block type \`InvoiceDialog\`, which is not on the block-type list`,
  ])
})

test('a pattern carries block-types: types from the list, or cross-cutting', () => {
  const ref = (n) => `.claude/skills/ui-patterns/references/${n}.md`
  const out = run({
    [ref('loading-states')]: '---\nblock-types: cross-cutting\nui-status: approved\n---\n',
    [ref('client-row')]: '---\nblock-types: [Row, ClientRow]\nui-status: approved\n---\n',
    [ref('sorting')]: '---\nui-status: approved\n---\n',
    [INVENTORY]: INV('| `loading-states.md` | x | approved |\n| `client-row.md` | x | approved |\n| `sorting.md` | x | approved |'),
  })
  assert.deepEqual(out.problems, [
    `${ref('client-row')}: block-types names \`ClientRow\`, which is not on the block-type list`,
    `${ref('sorting')}: no block-types line — list the block types it governs in its frontmatter, or cross-cutting`,
  ])
  assert.deepEqual(patternBlockTypes('---\nblock-types: [A, B]\n---\n'), ['A', 'B'])
  assert.equal(patternBlockTypes('# no frontmatter\n'), null)
})

test('screen content in a feature folder is not a part, so it needs no status and no inventory line', () => {
  const out = run({
    [ICON]: '// ui-status: approved\n',
    'apps/web/src/features/orders/ReviewBody.tsx': 'export const R = () => null\n',
    'apps/web/src/features/orders/components/Summary.tsx': 'export const S = () => null\n',
    [INVENTORY]: INV('| `IconButton` | x | approved |'),
  })
  assert.deepEqual(out.problems, [])
  assert.equal(out.counts.components, 1)
})
