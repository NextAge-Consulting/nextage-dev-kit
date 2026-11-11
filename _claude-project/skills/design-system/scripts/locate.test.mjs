import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { loadTypeScript } from './check-design-tokens.mjs'
import { locate, readRepo } from './locate.mjs'

const KEYS = { DESIGN_UI_PACKAGE: 'packages/ui', DESIGN_FEED_BARREL: 'src/index.ts', DESIGN_TOKEN_FILES: 'src/tokens.css', DESIGN_TYPE_FILE: 'src/type.css', DESIGN_STYLES_FILE: 'src/styles.css', DESIGN_VENDORED_DIR: 'packages/ui/src/components/ui', DESIGN_VENDORED_RESTYLED: 'true', DESIGN_FIELD_LOOK_CLASSES: '', DESIGN_EXEMPT_COMPONENTS: '' }

const TOKENS = `:root {
  /* the page */
  --background: oklch(0.98 0 0);
  /* a field's error, under the field */
  --feedback-danger: oklch(0.5 0.2 25);
  /* a control corner */
  --radius-control: 6px;
  /* a panel corner */
  --radius-panel: 8px;
  /* the larger corner, for panels */
  --radius-big: 12px;
}
`
const TYPE = `/* ─── body ─── */
/* running text */
@utility type-body {
  font-size: 14px;
  line-height: 20px;
  font-weight: 400;
}
/* a line under a field saying how to fill it */
@utility type-hint {
  font-size: 12px;
  line-height: 16px;
  font-weight: 400;
}
`
const STYLES = `@theme inline {
  --color-background: var(--background);
  --color-feedback-danger: var(--feedback-danger);
  --radius-control: var(--radius-control);
  --radius-panel: var(--radius-panel);
  --radius-big: var(--radius-big);
}
`
const CARD = `// ui-status: approved
// ui-block: FieldGroup
export function Card({ className, children }: { className?: string; children?: unknown }) {
  return <div className={cn("rounded-panel border bg-background p-4", className)}>{children}</div>
}
`
const BANNER = `// ui-status: approved
// ui-block: PageBanner
export function PageBanner({ children }: { children?: unknown }) {
  return <div role="status" className="rounded-control border p-2 text-feedback-danger">{children}</div>
}
`
const NOTICE = `// ui-status: pending
// ui-block: ErrorState
export function NoticeBox({ children }: { children?: unknown }) {
  return <div role="status" className="rounded-control border p-2">{children}</div>
}
`
const RULE = `---
kind: behaviour
code: [packages/ui/src/components/card.tsx]
block-types: [FieldGroup]
ui-status: approved
---
# Field groups

A failed save shows its line above the actions.
`
const RULE2 = `---
kind: behaviour
code: [packages/ui/src/components/card.tsx]
block-types: cross-cutting
ui-status: approved
---
# Saving

A failed save shows a banner at the top of the form.
`
const RECIPE = `---
kind: recipe
frame: card
reference: apps/web/src/routes/orders.tsx
block-types: [RecordScreen]
ui-status: approved
---
# Record screen
`
const SCREEN = `// ui-recipe: record.md
import { Card } from "@acme/ui/components/card"
import { PageBanner } from "@acme/ui/components/page-banner"
export function Orders() {
  return (
    <Card className="mt-4 p-2">
      <PageBanner>Saving failed</PageBanner>
      <div className="rounded-panel border bg-background p-4 shadow-card">
        <p className="type-hint">a</p>
      </div>
    </Card>
  )
}
`
const INV = `# UI Inventory

| Component | Use for | Type | Status |
|---|---|---|---|
| \`card\` | a titled group | FieldGroup | approved |
| \`page-banner\` | a standing message | PageBanner | approved |
| \`notice-box\` | a notice | ErrorState | pending |

| File | Governs | Status |
|---|---|---|
| \`field-groups.md\` | x | approved |
| \`saving.md\` | x | approved |
| \`record.md\` | x | approved |
`

function fixture() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'locate-'))
  const files = {
    '.claude/sync-substitutions.json': JSON.stringify(KEYS),
    'package.json': '{ "workspaces": ["apps/*", "packages/*"] }\n',
    'packages/ui/package.json': '{ "name": "@acme/ui" }\n',
    'apps/web/package.json': '{ "name": "web", "dependencies": { "@acme/ui": "*" } }\n',
    'packages/ui/src/tokens.css': TOKENS,
    'packages/ui/src/type.css': TYPE,
    'packages/ui/src/styles.css': STYLES,
    'packages/ui/src/components/card.tsx': CARD,
    'packages/ui/src/components/page-banner.tsx': BANNER,
    'apps/web/src/routes/orders.tsx': SCREEN,
    '.claude/skills/ui-patterns/references/field-groups.md': RULE,
    '.claude/skills/ui-patterns/references/saving.md': RULE2,
    '.claude/skills/ui-patterns/references/record.md': RECIPE,
    '.claude/rules/project/ui-inventory.md': INV,
  }
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), content)
  }
  const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args], { encoding: 'utf8' })
  git('init', '-q')
  git('add', '-A')
  git('commit', '-qm', 'base')
  return { dir, git }
}

const byQ = (list) => Object.fromEntries([...new Set(list.map((c) => c.question ?? c.finding))].map((q) => [q, list.filter((c) => (c.question ?? c.finding) === q)]))

test('a whole audit locates every kind of candidate, each with its question\'s fields', () => {
  const { dir } = fixture()
  loadTypeScript(dir)
  const R = readRepo(dir, { all: true })
  const all = [...locate(R)]
  const q = byQ(all)
  assert.deepEqual(q['ROLE-NAME'].map((c) => c.candidate.name).sort(), ['--radius-big', '--radius-control', '--radius-panel', 'type-body', 'type-hint'])
  assert.equal(q['ROLE-NAME'].find((c) => c.candidate.name === '--radius-big').candidate.purpose, 'the larger corner, for panels')
  assert.equal(q['DUPLICATE-ROLE'].length, 4)
  assert.ok(q['DUPLICATE-ROLE'].some((c) => c.candidate.a.name === '--radius-control' && c.candidate.b.name === '--radius-panel'))
  assert.deepEqual(q['NAMED-FOR-DATA'].map((c) => c.candidate.name).sort(), ['Card', 'PageBanner'])
  assert.equal(q['NAMED-FOR-DATA'][0].candidate.blockType, 'FieldGroup')
  assert.ok(q['RULE-REACH'].some((c) => c.candidate.block.name === 'Card' && /Field groups/.test(c.candidate.rule)))
  assert.ok(q['RULE-CONFLICT'].some((c) => c.candidate.surface === 'FieldGroup' && /Field groups/.test(c.candidate.a.text) && /Saving/.test(c.candidate.b.text)), 'a cross-cutting rule pairs with a typed one on its surface')
  assert.ok(q['RULE-CONFLICT'].some((c) => c.candidate.surface === 'RecordScreen'), 'the recipe pairs with the cross-cutting rule')
  assert.ok(q['FOLLOWS-RULE'].some((c) => /Saving/.test(c.candidate.rule) && /Orders/.test(c.candidate.screen)))
  assert.ok(q['FOLLOWS-RULE'].some((c) => /Record screen/.test(c.candidate.rule)), 'the recipe itself governs')
  const repaint = q['REPAINT'].map((c) => c.candidate.class)
  assert.deepEqual(repaint, ['p-2'], `placement and mechanical classes are not candidates: ${repaint}`)
  assert.equal(q['SCREEN-BOX'].length, 1)
  assert.match(q['SCREEN-BOX'][0].candidate.tag, /rounded-panel border bg-background/)
  assert.match(q['SCREEN-BOX'][0].candidate.blockTypes, /PageBanner: /)
  const tap = q['TOKEN-AGAINST-PURPOSE']
  assert.ok(tap.some((c) => c.candidate.token === 'text-feedback-danger' && /block/.test(c.candidate.where)))
  assert.ok(tap.some((c) => c.candidate.token === 'type-hint' && /screen/.test(c.candidate.where)))
  assert.equal(q['DUPLICATE-BLOCK']?.length ?? 0, 0, 'with no new block there is no duplicate question in an audit of existing blocks… every block is a candidate only when it is new or audited; see the next test')
})

test('a change locates only what it touched; a new block is a candidate against its neighbours and a second of its type is a finding', () => {
  const { dir, git } = fixture()
  loadTypeScript(dir)
  const base = git('rev-parse', 'HEAD').trim()
  fs.writeFileSync(path.join(dir, 'packages/ui/src/components/notice-box.tsx'), NOTICE)
  fs.writeFileSync(path.join(dir, 'packages/ui/src/components/alert-two.tsx'), BANNER.replace('PageBanner(', 'AlertTwo(').replace('// ui-status: approved', '// ui-status: pending'))
  fs.writeFileSync(path.join(dir, 'apps/web/src/routes/orders.tsx'), SCREEN.replace('<p className="type-hint">a</p>', '<p className="type-hint">a</p>\n        <Card className="rounded-none">b</Card>'))
  const R = readRepo(dir, { base })
  const all = [...locate(R)]
  const q = byQ(all)
  assert.deepEqual(q['REPAINT'].map((c) => [c.candidate.class, c.at]), [['rounded-none', 'apps/web/src/routes/orders.tsx:10']], 'only the changed call site, not the untouched p-2')
  assert.equal(q['ROLE-NAME'], undefined, 'no stylesheet changed')
  assert.ok(q['DUPLICATE-BLOCK'].some((c) => c.candidate.new.name === 'NoticeBox' && c.candidate.existing.name === 'PageBanner'), 'ErrorState is a neighbour of PageBanner')
  assert.ok(q['SECOND-BLOCK'].some((c) => /AlertTwo is a second block of type PageBanner/.test(c.text)))
  assert.ok(q['NAMED-FOR-DATA'].map((c) => c.candidate.name).includes('NoticeBox'))
  assert.ok(q['FOLLOWS-RULE'].every((c) => /…|Orders/.test(c.candidate.screen)))
})

test('a comment-only change touches nothing: a header added to every file judges nothing', () => {
  const { dir, git } = fixture()
  loadTypeScript(dir)
  const base = git('rev-parse', 'HEAD').trim()
  const files = ['packages/ui/src/components/card.tsx', 'packages/ui/src/components/page-banner.tsx', 'apps/web/src/routes/orders.tsx']
  for (const f of files) fs.writeFileSync(path.join(dir, f), `// ui-pointer: added\n/**\n * A block comment.\n */\n${fs.readFileSync(path.join(dir, f), 'utf8')}`)
  assert.deepEqual([...locate(readRepo(dir, { base }))], [], 'comments on three files: no candidate')
  const screen = path.join(dir, 'apps/web/src/routes/orders.tsx')
  fs.writeFileSync(screen, fs.readFileSync(screen, 'utf8').replace('<p className="type-hint">a</p>', '<p className="type-hint">a</p>\n        <Card className="rounded-none">b</Card>'))
  const q = byQ([...locate(readRepo(dir, { base }))])
  assert.deepEqual(q['REPAINT'].map((c) => c.candidate.class), ['rounded-none'], 'the one code change is judged')
  assert.equal(q['NAMED-FOR-DATA'], undefined, 'the blocks that gained only a comment are untouched')
})

test('a reference that names its apps meets only references and screens of those apps', () => {
  const { dir } = fixture()
  const w = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), text)
  }
  w('apps/shop/package.json', '{ "name": "shop", "dependencies": { "@acme/ui": "*" } }\n')
  w('apps/property/package.json', '{ "name": "property", "dependencies": { "@acme/ui": "*" } }\n')
  w('apps/shop/src/routes/cart.tsx', SCREEN.replace('record.md', 'shop-record.md').replace('Orders', 'Cart'))
  w('apps/property/src/routes/units.tsx', SCREEN.replace('record.md', 'office-record.md').replace('Orders', 'Units'))
  w('.claude/skills/ui-patterns/references/shop-record.md', RECIPE.replace('reference: apps/web/src/routes/orders.tsx', 'reference: apps/shop/src/routes/cart.tsx\napps: [apps/shop, apps/dealer]').replace('# Record screen', '# Shop record'))
  w('.claude/skills/ui-patterns/references/office-record.md', RECIPE.replace('reference: apps/web/src/routes/orders.tsx', 'reference: apps/property/src/routes/units.tsx\napps: [apps/property]').replace('# Record screen', '# Office record'))
  w('.claude/skills/ui-patterns/references/shop-saving.md', RULE2.replace('block-types: cross-cutting', 'block-types: cross-cutting\napps: [apps/shop]').replace('# Saving', '# Shop saving'))
  loadTypeScript(dir)
  const q = byQ([...locate(readRepo(dir, { all: true }))])
  const pairs = q['RULE-CONFLICT'].map((c) => [c.candidate.a.file, c.candidate.b.file].sort().join('+'))
  assert.ok(!pairs.includes('office-record.md+shop-record.md'), 'two recipes for different apps never meet')
  assert.ok(!pairs.includes('office-record.md+shop-saving.md'), 'a shop rule and a property recipe never meet')
  assert.ok(pairs.includes('shop-record.md+shop-saving.md'), 'two references sharing an app still pair')
  assert.ok(pairs.includes('saving.md+shop-saving.md'), 'a reference for every app pairs with one for some')
  const follows = (screen) => q['FOLLOWS-RULE'].filter((c) => c.candidate.screen.includes(screen)).map((c) => c.candidate.rule.match(/^# (.+)$/m)[1]).sort()
  assert.deepEqual(follows('Cart'), ['Field groups', 'Saving', 'Shop record', 'Shop saving'])
  assert.deepEqual(follows('Units'), ['Field groups', 'Office record', 'Saving'], 'a property screen is not checked against the shop rule')
  assert.deepEqual(follows('Orders'), ['Field groups', 'Record screen', 'Saving'], 'the web app is outside the shop rule')
})

test('the layers can be asked for one at a time, and the command prints JSON lines', () => {
  const { dir } = fixture()
  loadTypeScript(dir)
  const R = readRepo(dir, { all: true })
  assert.ok([...locate(R, { layer: 'tokens' })].every((c) => ['ROLE-NAME', 'DUPLICATE-ROLE'].includes(c.question)))
  assert.ok([...locate(R, { layer: 'screens' })].every((c) => ['FOLLOWS-RULE', 'REPAINT', 'SCREEN-BOX', 'TOKEN-AGAINST-PURPOSE'].includes(c.question)))
  const out = execFileSync(process.execPath, [new URL('./locate.mjs', import.meta.url).pathname, '--repo', dir, '--all', '--layer', 'tokens'], { encoding: 'utf8' })
  const lines = out.trim().split('\n').map((l) => JSON.parse(l))
  assert.ok(lines.length >= 5)
  assert.ok(lines.every((l) => l.question && l.at && l.candidate))
})

test('a project with no UI package does not apply', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'locate-'))
  fs.mkdirSync(path.join(dir, '.claude'))
  fs.writeFileSync(path.join(dir, '.claude/sync-substitutions.json'), JSON.stringify({ DESIGN_UI_PACKAGE: '', _intentionally_empty: ['DESIGN_UI_PACKAGE'] }))
  assert.ok(readRepo(dir, { all: true }).notApplicable)
})

test('an import that binds names is not a change: a screen whose only change is an import judges nothing', () => {
  const { dir, git } = fixture()
  loadTypeScript(dir)
  const base = git('rev-parse', 'HEAD').trim()
  const screen = path.join(dir, 'apps/web/src/routes/orders.tsx')
  const card = path.join(dir, 'packages/ui/src/components/card.tsx')
  fs.writeFileSync(screen, fs.readFileSync(screen, 'utf8').replace('import { Card }', 'import { submitOnce } from "@acme/web/form/submitOnce"\nimport {\n  type Order,\n} from "@acme/web/orders"\nimport { Card }'))
  fs.writeFileSync(card, fs.readFileSync(card, 'utf8').replace('export function Card', 'import { cn } from "../lib/cn"\nexport function Card'))
  assert.deepEqual([...locate(readRepo(dir, { base }))], [], 'imports on a screen and a block: no candidate')
  fs.writeFileSync(screen, fs.readFileSync(screen, 'utf8').replace('import { Card }', 'import "./orders.css"\nimport { Card }'))
  const q = byQ([...locate(readRepo(dir, { base }))])
  assert.ok(q['FOLLOWS-RULE']?.length, 'an import for its effect alone is code, and the screen is judged')
})

test('a changed screen is asked about with its changed lines as the only lines a yes may rest on', () => {
  const { dir, git } = fixture()
  loadTypeScript(dir)
  const base = git('rev-parse', 'HEAD').trim()
  const screen = path.join(dir, 'apps/web/src/routes/orders.tsx')
  fs.writeFileSync(screen, fs.readFileSync(screen, 'utf8').replace('<PageBanner>Saving failed</PageBanner>', '<PageBanner>Saving did not work</PageBanner>'))
  const follows = byQ([...locate(readRepo(dir, { base }))])['FOLLOWS-RULE']
  assert.deepEqual(follows.map((c) => c.about).sort(), ['field-groups.md', 'record.md', 'saving.md'], 'one candidate per governing rule, each naming its rule')
  for (const c of follows) {
    assert.deepEqual(c.anchor, { file: 'apps/web/src/routes/orders.tsx', lines: [[7, '      <PageBanner>Saving did not work</PageBanner>']] })
    assert.equal(c.at, 'apps/web/src/routes/orders.tsx:7', 'never the header line')
    assert.match(c.candidate.screen, /rounded-panel border/, 'the lines around the change stay, as context')
  }
  const whole = byQ([...locate(readRepo(dir, { all: true }), { layer: 'screens' })])['FOLLOWS-RULE'][0]
  assert.deepEqual(whole.anchor.lines.map(([n]) => n), [2, 3, 4, 5, 6, 7, 8, 9, 10, 11], 'an audited screen: every line holding code, the header comment and bare brackets left out')
})
