import { after, test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { catalogueRows, checkUiStatus, INVENTORY, isComponent, isPattern, key, NOT_APPLICABLE } from './check-ui-status.mjs'

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

const INV = (rows) => `# UI Inventory\n\n| Component | Use for | Status |\n|---|---|---|\n${rows}\n`

test('everything approved and catalogued passes, with counts', () => {
  const out = run({
    [BUTTON]: '// ui-status: approved\nexport function Button() {}\n',
    [ICON]: '// ui-status: approved\n',
    [BROWSE]: '---\nui-status: approved\n---\n# Browse\n',
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
    [BROWSE]: '---\nui-status: pending\n---\n',
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
    [BROWSE]: '---\nui-status: draft\n---\n',
    [INVENTORY]: INV('| `button` | x | approved |\n| `IconButton` | x | approved |\n| `browse-layout.md` | x | approved |'),
  })
  assert.deepEqual(out.problems, [
    `${BUTTON}: no ui-status line`,
    `${ICON}: 2 ui-status lines (lines 1, 2); a file carries one`,
    `${BROWSE}:2: ui-status "draft" is neither approved nor pending`,
  ])
})

test('the catalogue must list every part with the status its file carries', () => {
  const out = run({
    [BUTTON]: '// ui-status: approved\n',
    [ICON]: '// ui-status: pending\n',
    [BROWSE]: '---\nui-status: approved\n---\n',
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
    [ref]: '---\nui-status: approved\n---\n',
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
  assert.ok(isPattern(BROWSE))
  assert.ok(!isPattern('.claude/skills/ui-patterns/references/sub/x.md'))
  assert.ok(!isPattern('.claude/skills/ui-patterns/references/README.md'))
  assert.equal(key('IconButton'), key('icon-button.tsx'))
  assert.deepEqual(catalogueRows('| `a` | b | **Pending** |\n|---|---|---|\n| plain | x |'), [{ name: 'a', status: 'pending', line: 1 }])
})
