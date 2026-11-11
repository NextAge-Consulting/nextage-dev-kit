import { after, test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { catalogueRows, checkUiStatus, excepted, fingerprint, frontmatter, headers, INVENTORY, isComponent, isPattern, isScreen, key, lineCode, NOT_APPLICABLE, patternBlockTypes } from './check-ui-status.mjs'

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
  return checkUiStatus(r.dir, { files: r.files, sourceDirs: null })
}

const BUTTON = 'packages/ui/src/components/ui/button.tsx'
const ICON = 'packages/ui/src/components/icon-button.tsx'
const BROWSE = '.claude/skills/ui-patterns/references/browse-layout.md'
const SAVING = '.claude/skills/ui-patterns/references/saving.md'
const SCREEN = 'apps/web/src/routes/orders.tsx'
const FRAME = 'packages/ui/src/components/browse-screen.tsx'

const atom = (status = 'approved') => `// ui-status: ${status}\nexport function Button() {}\n`
const block = (type, status = 'approved', rules = '') => `// ui-status: ${status}\n// ui-block: ${type}\n${rules ? `// ui-behaviour: ${rules}\n` : ''}export function X() {}\n`
const recipe = (status = 'approved', frame = 'browse-screen', ref = SCREEN) => `---\nkind: recipe\nframe: ${frame}\nreference: ${ref}\nblock-types: [BrowseScreen, Pager]\nui-status: ${status}\n---\n# Browse\n`
const rule = (code, status = 'approved') => `---\nkind: behaviour\ncode: [${code}]\nblock-types: cross-cutting\nui-status: ${status}\n---\n# Saving\n`
const screen = (recipeFile = 'browse-layout.md') => `// ui-recipe: ${recipeFile}\nexport const Route = () => null\n`

const INV = (rows) =>
  `# UI Inventory\n\n| Component | Use for | Status | Type |\n|---|---|---|---|\n${rows.split('\n').map((r) => `${r} ModalShell |`).join('\n')}\n`
const CLEAN = {
  [BUTTON]: atom(),
  [ICON]: block('ModalShell'),
  [FRAME]: block('BrowseScreen'),
  [BROWSE]: recipe(),
  [SCREEN]: screen(),
}
const CLEAN_INV = `# UI Inventory\n\n| Component | Use for | Status | Type |\n|---|---|---|---|\n| \`IconButton\` | icon-only | approved | ModalShell |\n| \`browse-screen\` | the browse frame | approved | BrowseScreen |\n\n| Atom | Status |\n|---|---|\n| \`button\` | approved |\n\n| File | Governs | Status |\n|---|---|---|\n| \`browse-layout.md\` | lists | approved |\n`

test('everything approved, catalogued and pointed passes, with counts', () => {
  const out = run({ ...CLEAN, [INVENTORY]: CLEAN_INV })
  assert.deepEqual(out.pending, [])
  assert.deepEqual(out.problems, [])
  assert.deepEqual(out.counts, { components: 3, references: 1, screens: 1, stylesheets: 0, catalogue: 4, deferredLines: 0, judged: 0 })
})

test('no component or reference files: does not apply', () => {
  assert.equal(run({ 'src/index.ts': 'export {}\n' }).notApplicable, NOT_APPLICABLE)
})

test('pending components, references and tokens are listed', () => {
  const out = run({
    ...CLEAN,
    [ICON]: block('ModalShell', 'pending'),
    [BROWSE]: recipe('pending'),
    'packages/ui/src/tokens.css': ':root {\n  /* a hover fill inside a card · ui-status: pending */\n  --card-hover: oklch(0.9 0 0);\n}\n',
    [INVENTORY]: CLEAN_INV.replace('icon-only | approved', 'icon-only | pending').replace('lists | approved', 'lists | pending'),
  })
  assert.deepEqual(out.problems, [])
  assert.deepEqual(out.pending, [`${ICON} (component)`, `${BROWSE} (reference)`, 'packages/ui/src/tokens.css:2 (token --card-hover)'])
})

test('a file with no status, two, or an unknown value fails', () => {
  const out = run({
    ...CLEAN,
    [BUTTON]: 'export function Button() {}\n',
    [ICON]: '// ui-status: approved\n// ui-status: pending\n// ui-block: ModalShell\n',
    [BROWSE]: recipe('draft'),
    [INVENTORY]: CLEAN_INV,
  })
  assert.deepEqual(out.problems.slice(0, 3), [
    `${BUTTON}: no ui-status line`,
    `${ICON}: 2 ui-status lines (lines 1, 2); a file carries one`,
    `${BROWSE}:6: ui-status "draft" is not approved, pending or deferred`,
  ])
})

test('the catalogue must list every file with the status its file carries', () => {
  const out = run({
    ...CLEAN,
    [ICON]: block('ModalShell', 'pending'),
    [INVENTORY]: INV('| `IconButton` | x | approved |\n| `button` | x | |\n| `Ghost` | x | pending |\n| `browse-screen` | x | approved |'),
  })
  assert.deepEqual(out.problems, [
    `${INVENTORY}:5: \`IconButton\` is approved here, pending in ${ICON}`,
    `${INVENTORY}:6: \`button\` has no status; its file says approved`,
    `${INVENTORY}:7: \`Ghost\` has a status but no component or reference file is named that`,
    `${INVENTORY}:8: \`browse-screen\` names block type \`ModalShell\`, which is not on the block-type list`.replace('names block type `ModalShell`, which is not on the block-type list', 'is approved here, approved in ' + FRAME).replace(/.*/, `${FRAME}: \`// ui-block: BrowseScreen\` but its inventory line says ModalShell (${INVENTORY}:8)`),
    `${BROWSE}: not in ${INVENTORY}`,
  ])
})

test('a missing inventory fails', () => {
  const out = run({ ...CLEAN })
  assert.deepEqual(out.problems, [`${INVENTORY}: missing — the catalogue of components, recipes and rules`])
})

test('a path in the catalogue picks one of two same-named files', () => {
  const app = 'apps/web/src/components/form/fields.tsx'
  const other = 'apps/admin/src/components/fields.tsx'
  const out = run({ ...CLEAN, [app]: block('FieldGroup'), [other]: block('FieldGroup', 'pending'), [INVENTORY]: `${CLEAN_INV}\n| Component | Use for | Status | Type |\n|---|---|---|---|\n| \`form/fields\` | x | approved | FieldGroup |\n` })
  assert.deepEqual(out.problems, [`${other}: not in ${INVENTORY}`])
})

test('a reference and a component sharing a name are matched by kind', () => {
  const notice = 'src/components/failure-notice.tsx'
  const ref = '.claude/skills/ui-patterns/references/failure-notice.md'
  const out = run({
    ...CLEAN,
    [notice]: block('PageBanner', 'pending'),
    [ref]: rule(notice).replace('# Saving', '# Failure notice'),
    [INVENTORY]: `${CLEAN_INV}\n| Component | Use for | Status | Type |\n|---|---|---|---|\n| \`FailureNotice\` | x | pending | PageBanner |\n\n| File | Governs | Status |\n|---|---|---|\n| \`failure-notice.md\` | x | approved |\n`,
  })
  assert.deepEqual(out.problems, [`${ref}: lists \`${notice}\` as its code, which does not point back with \`// ui-behaviour\` or \`// ui-behaviour-code: failure-notice.md\``])
  assert.deepEqual(out.pending, [`${notice} (component)`])
})

test('component, screen and reference recognition, and name keys', () => {
  assert.ok(isComponent('apps/web/src/components/x.tsx'))
  assert.ok(!isComponent('apps/web/src/components/x.test.tsx'))
  assert.ok(!isComponent('apps/web/src/routes/x.tsx'))
  assert.ok(!isComponent('apps/web/src/components/x.ts'))
  assert.ok(!isComponent('apps/web/src/features/orders/components/x.tsx'))
  assert.ok(isScreen('apps/web/src/routes/x.tsx', null))
  assert.ok(isScreen('apps/web/src/features/orders/components/x.tsx', null))
  assert.ok(!isScreen('apps/web/src/routes/x.test.tsx', null))
  assert.ok(isScreen('apps/web/src/routes/x.tsx', ['apps/web/src']))
  assert.ok(!isScreen('apps/mail/src/routes/x.tsx', ['apps/web/src']))
  assert.ok(isPattern(BROWSE))
  assert.ok(!isPattern('.claude/skills/ui-patterns/references/sub/x.md'))
  assert.ok(!isPattern('.claude/skills/ui-patterns/references/README.md'))
  assert.equal(key('IconButton'), key('icon-button.tsx'))
  assert.deepEqual(catalogueRows('| `a` | b | **Pending** |\n|---|---|---|\n| plain | x |'), [{ name: 'a', status: 'pending', line: 1 }])
  assert.deepEqual(frontmatter('---\nkind: recipe\nframe: x\n---\nbody'), { kind: 'recipe', frame: 'x' })
  assert.equal(frontmatter('# none'), null)
  assert.deepEqual(patternBlockTypes('---\nblock-types: [A, B]\n---\n'), ['A', 'B'])
  assert.equal(patternBlockTypes('# no frontmatter\n'), null)
})

test('headers: every pointer form, in a line comment or a block comment, within the first lines', () => {
  const h = headers('// ui-status: approved\n/* ui-block: Row */\n// ui-behaviour: saving.md, loading.md\n// ui-behaviour-code: sorting.md\nexport const x = 1\n')
  assert.deepEqual(h, { block: 'Row', atom: false, behaviour: ['saving.md', 'loading.md'], behaviourCode: ['sorting.md'], recipe: null, content: false })
  assert.equal(headers('// ui-atom\n').atom, true)
  assert.equal(headers('// ui-recipe: browse-layout.md\n').recipe, 'browse-layout.md')
  assert.equal(headers('// ui-content\n').content, true)
  assert.equal(headers(`${'\n'.repeat(20)}// ui-block: Row\n`).block, null)
})

test('a block names a type on the list or is an atom; a vendored atom carries no type; the header agrees with the inventory', () => {
  const out = run({
    ...CLEAN,
    [BUTTON]: '// ui-status: approved\n// ui-block: Row\n',
    [ICON]: '// ui-status: approved\n',
    'packages/ui/src/components/review-dialog.tsx': block('ReviewDialog'),
    'packages/ui/src/components/fact-list.tsx': block('FactList'),
    'packages/ui/src/components/invoice-dialog.tsx': block('InvoiceDialog'),
    'packages/ui/src/components/both.tsx': '// ui-status: approved\n// ui-atom\n// ui-block: Row\n',
    [INVENTORY]: `# UI Inventory\n\n| Component | Use for | Type | Status |\n|---|---|---|---|\n| \`IconButton\` | x | | approved |\n| \`review-dialog\` | x | ReviewDialog | approved |\n| \`fact-list\` | x | <none> | approved |\n| \`invoice-dialog\` | x | InvoiceDialog | approved |\n| \`both\` | x | Row | approved |\n| \`browse-screen\` | x | BrowseScreen | approved |\n\n| Atom | Status |\n|---|---|\n| \`button\` | approved |\n\n| File | Governs | Status |\n|---|---|---|\n| \`browse-layout.md\` | x | approved |\n`,
  })
  assert.deepEqual(out.problems, [
    `${BUTTON}: a vendored atom carries \`// ui-atom\`, never a block type`,
    `${ICON}: no header — \`// ui-block: <Type>\` from the block-type list, or \`// ui-atom\``,
    'packages/ui/src/components/invoice-dialog.tsx: `// ui-block: InvoiceDialog` is not on the block-type list',
    'packages/ui/src/components/both.tsx: both `// ui-atom` and `// ui-block`; a file is one or the other',
    `${INVENTORY}:5: \`IconButton\` has no block type — name its type from the block-type list in a Type column`,
    `${INVENTORY}:7: \`fact-list\` names block type \`<none>\`, which is not on the block-type list`,
    `${INVENTORY}:8: \`invoice-dialog\` names block type \`InvoiceDialog\`, which is not on the block-type list`,
  ])
})

test("a project's own atom, outside the vendored folder, is listed with no block type", () => {
  const own = 'packages/ui/src/components/date-field.tsx'
  const out = run({
    ...CLEAN,
    [own]: '// ui-status: approved\n// ui-atom\nexport function DateField() {}\n',
    [INVENTORY]: `${CLEAN_INV}\n| Atom | Use for | Status |\n|---|---|---|\n| \`date-field\` | every date input | approved |\n`,
  })
  assert.deepEqual(out.problems, [])
})

test('a reference is a recipe or a behaviour rule, with the pointers of its kind, and block-types from the list or cross-cutting', () => {
  const ref = (n) => `.claude/skills/ui-patterns/references/${n}.md`
  const out = run({
    ...CLEAN,
    [ref('loading-states')]: '---\nkind: behaviour\ncode: [packages/ui/src/components/icon-button.tsx]\nblock-types: cross-cutting\nui-status: approved\n---\n',
    [ref('client-row')]: '---\nkind: recipe\nframe: nowhere\nreference: apps/web/src/routes/missing.tsx\nblock-types: [Row, ClientRow]\nui-status: approved\n---\n',
    [ref('sorting')]: '---\nui-status: approved\n---\n',
    [ref('bare')]: '---\nkind: recipe\nblock-types: [Row]\nui-status: approved\n---\n',
    [ref('empty-rule')]: '---\nkind: behaviour\nblock-types: [Row]\nui-status: approved\n---\n',
    [ICON]: block('ModalShell', 'approved', 'loading-states.md'),
    [INVENTORY]: `${CLEAN_INV}\n| File | Governs | Status |\n|---|---|---|\n| \`loading-states.md\` | x | approved |\n| \`client-row.md\` | x | approved |\n| \`sorting.md\` | x | approved |\n| \`bare.md\` | x | approved |\n| \`empty-rule.md\` | x | approved |\n`,
  })
  assert.deepEqual(out.problems, [
    `${ref('client-row')}: block-types names \`ClientRow\`, which is not on the block-type list`,
    `${ref('client-row')}: frame \`nowhere\` names no component file`,
    `${ref('client-row')}: reference \`apps/web/src/routes/missing.tsx\` is not a file in this repository`,
    `${ref('sorting')}: no block-types line — list the block types it governs in its frontmatter, or cross-cutting`,
    `${ref('sorting')}: no \`kind:\` in its frontmatter — a reference is \`kind: recipe\` or \`kind: behaviour\``,
    `${ref('bare')}: a recipe names its frame — \`frame: <component>\``,
    `${ref('bare')}: a recipe names one reference screen — \`reference: <screen file>\``,
    `${ref('empty-rule')}: a behaviour rule lists its code — \`code: [<files>]\``,
  ])
})

test('apps: names workspaces the root package.json declares, and a recipe\'s reference screen is in one of them', () => {
  const ref = (n) => `.claude/skills/ui-patterns/references/${n}.md`
  const SHOP = 'apps/shop/src/routes/cart.tsx'
  const out = run({
    ...CLEAN,
    'package.json': '{ "workspaces": ["apps/*", "packages/*"] }\n',
    'apps/shop/package.json': '{ "name": "shop" }\n',
    'apps/dealer/package.json': '{ "name": "dealer" }\n',
    [SHOP]: screen('cart.md'),
    [ref('cart')]: `---\nkind: recipe\nframe: browse-screen\nreference: ${SHOP}\nblock-types: [BrowseScreen]\napps: [apps/shop, apps/dealer]\nui-status: approved\n---\n`,
    [ref('office-cart')]: `---\nkind: recipe\nframe: browse-screen\nreference: ${SHOP}\nblock-types: [BrowseScreen]\napps: [apps/property]\nui-status: approved\n---\n`,
    [ref('checkout')]: `---\nkind: behaviour\ncode: [packages/ui/src/components/icon-button.tsx]\nblock-types: cross-cutting\napps:\nui-status: approved\n---\n`,
    [ICON]: block('ModalShell', 'approved', 'checkout.md'),
    [INVENTORY]: `${CLEAN_INV}\n| File | Governs | Status |\n|---|---|---|\n| \`cart.md\` | x | approved |\n| \`office-cart.md\` | x | approved |\n| \`checkout.md\` | x | approved |\n`,
  })
  assert.deepEqual(out.problems.sort(), [
    `${ref('checkout')}: \`apps:\` names no workspace — list the apps it governs, or leave the line out to govern every app`,
    `${ref('office-cart')}: apps names \`apps/property\`, which is not a workspace the root package.json declares`,
    `${ref('office-cart')}: reference \`${SHOP}\` is not in an app its \`apps:\` line names`,
  ])
})

test('behaviour rules and their code point at each other, from a block header or a code module', () => {
  const guard = 'packages/web/src/lib/unsaved-guard.ts'
  const out = run({
    ...CLEAN,
    [SAVING]: rule(`${ICON}, ${guard}, packages/ui/src/components/never.tsx`),
    [ICON]: block('ModalShell', 'approved', 'saving.md, missing.md'),
    [guard]: '// ui-behaviour-code: saving.md\nexport const guard = 1\n',
    'packages/web/src/lib/stray.ts': '// ui-behaviour-code: saving.md\nexport const stray = 1\n',
    [FRAME]: block('BrowseScreen', 'approved', 'browse-layout.md'),
    [INVENTORY]: `${CLEAN_INV}\n| File | Governs | Status |\n|---|---|---|\n| \`saving.md\` | x | approved |\n`,
  })
  assert.deepEqual(out.problems, [
    `${SAVING}: code \`packages/ui/src/components/never.tsx\` is not a file in this repository`,
    `${ICON}: \`// ui-behaviour: missing.md\` names no reference file`,
    `${FRAME}: \`// ui-behaviour: browse-layout.md\` names a reference that is not a behaviour rule`,
    `${SAVING}: lists \`packages/ui/src/components/never.tsx\` as its code, which does not point back with \`// ui-behaviour\` or \`// ui-behaviour-code: saving.md\``,
    `packages/web/src/lib/stray.ts: points at saving.md, whose \`code:\` list does not name it`,
  ])
})

test('every screen names its recipe or is content; a feature file is a screen too', () => {
  const out = run({
    ...CLEAN,
    'apps/web/src/features/orders/ReviewBody.tsx': '// ui-content\nexport const R = () => null\n',
    'apps/web/src/features/orders/components/Summary.tsx': 'export const S = () => null\n',
    'apps/web/src/routes/users.tsx': '// ui-recipe: nowhere.md\nexport const U = () => null\n',
    'apps/web/src/routes/both.tsx': '// ui-recipe: browse-layout.md\n// ui-content\nexport const B = () => null\n',
    'apps/web/src/routes/rule.tsx': '// ui-recipe: saving.md\nexport const C = () => null\n',
    [SAVING]: rule(ICON),
    [ICON]: block('ModalShell', 'approved', 'saving.md'),
    [INVENTORY]: `${CLEAN_INV}\n| File | Governs | Status |\n|---|---|---|\n| \`saving.md\` | x | approved |\n`,
  })
  assert.deepEqual(out.problems, [
    "apps/web/src/features/orders/components/Summary.tsx: no header — `// ui-recipe: <recipe>.md`, or `// ui-content` for one screen's content",
    'apps/web/src/routes/users.tsx: `// ui-recipe: nowhere.md` names no reference file',
    'apps/web/src/routes/both.tsx: both `// ui-recipe` and `// ui-content`; a screen follows a recipe, a feature file is content',
    'apps/web/src/routes/rule.tsx: `// ui-recipe: saving.md` names a reference that is not a recipe',
  ])
  assert.equal(out.counts.screens, 6)
  assert.equal(out.counts.components, 3)
})

test('a fingerprint is the first eight hex digits of the SHA-256; a line fingerprint ignores its comments', () => {
  assert.equal(fingerprint('abc'), 'ba7816bf')
  assert.equal(lineCode('  <Card className="p-2"> {/* design-deferred 1a2b3c4d */}  '), '<Card className="p-2">')
  assert.equal(lineCode('  --x: 1px; /* design-deferred 1a2b3c4d */'), '--x: 1px;')
  assert.equal(lineCode('foo() // design-accepted — reason'), 'foo()')
})

test('a deferred file blocks nothing, needs no reason and is listed apart, until its file changes', () => {
  const iconText = `// ui-status: deferred\n// ui-block: ModalShell\nexport function IconButton() {}\n`
  const browseText = recipe('deferred')
  const lines = (icon, browse) => CLEAN_INV.replace('icon-only | approved', `icon-only | deferred \`${icon}\``).replace('lists | approved', `lists | deferred \`${browse}\``)
  const set = run({ ...CLEAN, [ICON]: iconText, [BROWSE]: browseText, [INVENTORY]: lines(fingerprint(iconText), fingerprint(browseText)) })
  assert.deepEqual(set.pending, [])
  assert.deepEqual(set.problems, [])
  assert.deepEqual(set.deferred, [`${ICON} (component) — ${INVENTORY}:5`, `${BROWSE} (reference) — ${INVENTORY}:14`])

  const changed = run({ ...CLEAN, [ICON]: `${iconText}// edited\n`, [BROWSE]: browseText, [INVENTORY]: lines(fingerprint(iconText), fingerprint(browseText)) })
  assert.equal(changed.pending.length, 1)
  assert.match(changed.pending[0], /icon-button\.tsx \(component\), changed since it was deferred/)
  assert.deepEqual(changed.deferred, [`${BROWSE} (reference) — ${INVENTORY}:14`])
})

test('a deferred inventory line with no fingerprint fails', () => {
  const out = run({ ...CLEAN, [ICON]: block('ModalShell', 'deferred'), [INVENTORY]: CLEAN_INV.replace('icon-only | approved', 'icon-only | deferred') })
  assert.deepEqual(out.problems, [`${INVENTORY}:5: \`IconButton\` is deferred with no fingerprint — record the file's fingerprint on its line (--fingerprint)`])
})

test('a deferred line is set aside until its code changes; one with no fingerprint fails; accepted lines need nothing', () => {
  const code = '  <Card className="p-2">'
  const fp = fingerprint(lineCode(code))
  const base = { ...CLEAN, [INVENTORY]: CLEAN_INV }
  const ok = run({ ...base, [SCREEN]: `${screen()}export const S = () => (\n${code} {/* design-deferred ${fp} */}\n  <p>{/* design-accepted — the brand's own badge */}</p>\n)\n` })
  assert.deepEqual(ok.problems, [])
  assert.deepEqual(ok.pending, [])
  assert.deepEqual(ok.deferred, [`${SCREEN}:4 (line)`])
  assert.equal(ok.counts.deferredLines, 1)

  const changed = run({ ...base, [SCREEN]: `${screen()}export const S = () => (\n  <Card className="p-4"> {/* design-deferred ${fp} */}\n)\n` })
  assert.equal(changed.pending.length, 1)
  assert.match(changed.pending[0], new RegExp(`${SCREEN}:4 \\(line\\), changed since it was deferred`))

  const bare = run({ ...base, 'packages/ui/src/tokens.css': ':root {\n  --x: 1px; /* design-deferred */\n}\n' })
  assert.deepEqual(bare.problems, ['packages/ui/src/tokens.css:2: `design-deferred` with no fingerprint — record the line\'s fingerprint (--line-fingerprint)'])
})

test('the judge\'s ledger: an item is pending while its line stands unchanged and unanswered; answered or changed lines drop out', () => {
  const code = '  <Card className="p-2">'
  const fp = fingerprint(lineCode(code))
  const base = { ...CLEAN, [INVENTORY]: CLEAN_INV, [SCREEN]: `${screen()}export const S = () => (\n${code}\n  <p className="type-hint">x</p>\n)\n` }
  const ledger = (items) => ({ ...base, '.claude/ui-pending.json': `${JSON.stringify(items)}\n` })
  const live = run(ledger([{ question: 'REPAINT', at: `${SCREEN}:4`, quote: 'p-2', fingerprint: fp }, { question: 'REPAINT', at: `${SCREEN}:5`, quote: 'type-hint', fingerprint: 'deadbeef' }]))
  assert.deepEqual(live.problems, [])
  assert.deepEqual(live.pending, [`${SCREEN}:4 (judge REPAINT) — p-2`])
  assert.equal(live.counts.judged, 1)
  const answered = run({ ...ledger([{ question: 'REPAINT', at: `${SCREEN}:4`, quote: 'p-2', fingerprint: fp }]), [SCREEN]: `${screen()}export const S = () => (\n${code} {/* design-accepted — the brand's own card */}\n)\n` })
  assert.deepEqual(answered.pending, [])
  const broken = run(ledger('nope').valueOf() === undefined ? {} : { ...base, '.claude/ui-pending.json': 'nope\n' })
  assert.deepEqual(broken.problems, ['.claude/ui-pending.json: not JSON — the judge\'s ledger cannot be read'])
})

test('a marker on a comment-only line answers for the line beneath it: accepted, deferred, and a ledger item', () => {
  const code = '  <Card className="p-2">'
  const fp = fingerprint(lineCode(code))
  const base = { ...CLEAN, [INVENTORY]: CLEAN_INV }
  const lines = ['a()', '{/* design-accepted — reason */}', code, 'b() // design-accepted — reason', 'c()']
  assert.equal(excepted(lines, 3), true)
  assert.equal(excepted(lines, 4), true)
  assert.equal(excepted(lines, 5), false, 'a marker trailing a line of code answers for that line alone')
  assert.equal(excepted(lines, 1), false)

  const deferred = run({ ...base, [SCREEN]: `${screen()}export const S = () => (\n  {/* design-deferred ${fp} */}\n${code}\n)\n` })
  assert.deepEqual(deferred.problems, [])
  assert.deepEqual(deferred.pending, [])
  assert.deepEqual(deferred.deferred, [`${SCREEN}:4 (line)`])
  const changed = run({ ...base, [SCREEN]: `${screen()}export const S = () => (\n  {/* design-deferred ${fp} */}\n  <Card className="p-4">\n)\n` })
  assert.match(changed.pending[0], /changed since it was deferred/)

  const item = { question: 'FOLLOWS-RULE', at: `${SCREEN}:5`, about: 'saving.md', quote: 'p-2', fingerprint: fp }
  const live = run({ ...base, [SCREEN]: `${screen()}export const S = () => (\n  <p />\n${code}\n)\n`, '.claude/ui-pending.json': `${JSON.stringify([item])}\n` })
  assert.deepEqual(live.pending, [`${SCREEN}:5 (judge FOLLOWS-RULE, saving.md) — p-2`])
  const answered = run({ ...base, [SCREEN]: `${screen()}export const S = () => (\n  {/* design-accepted — the brand's own card */}\n${code}\n)\n`, '.claude/ui-pending.json': `${JSON.stringify([item])}\n` })
  assert.deepEqual(answered.pending, [])
})
