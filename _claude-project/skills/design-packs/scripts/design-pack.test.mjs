import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadTypeScript } from '../../design-system/scripts/check-design-tokens.mjs'
import { businessWords, carriesProblems, classify, codeOnly, coverage, isRepositoryAddress, packReference, packsCheckout, pieceFingerprint, PROOFS, provedState, recordProof, planExtract, preconditions, prove, proveInFixture, readSystem, renamePackage, stubFor, whyCarried, wordHits, wordsOf, workOut, writePiece } from './design-pack.mjs'

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), 'design-pack.mjs')
const KEYS = { DESIGN_UI_PACKAGE: 'packages/ui', DESIGN_FEED_BARREL: 'src/index.ts', DESIGN_TOKEN_FILES: 'src/tokens.css', DESIGN_TYPE_FILE: 'src/type.css', DESIGN_STYLES_FILE: 'src/styles.css', DESIGN_VENDORED_DIR: 'packages/ui/src/components/ui', DESIGN_VENDORED_RESTYLED: 'true', DESIGN_FIELD_LOOK_CLASSES: '', DESIGN_EXEMPT_COMPONENTS: '' }
const TSCONFIG = { compilerOptions: { jsx: 'preserve', module: 'ESNext', moduleResolution: 'Bundler', target: 'ES2022', strict: true, noEmit: true, paths: { '@acme/ui/*': ['./packages/ui/src/*'], '@acme/shared/*': ['./apps/shared/src/*'] } }, include: ['packages', 'apps'] }

const TOKENS = `:root {
  /* a panel's fill */
  --surface: #ffffff;
  /* text on a panel */
  --surface-foreground: #111111;
  /* a control's corner */
  --radius-control: 6px;
  /* a status nothing here uses */
  --status-idle: #777777;
}
`
const TYPE = `/* ─── body ─── */
/* running text */
@utility type-body {
  font-size: 14px;
  line-height: 20px;
  font-weight: 400;
}
`
const STYLES = `@import "./tokens.css";
@import "./type.css";

@theme inline {
  --color-surface: var(--surface);
  --color-status-idle: var(--status-idle);
  --radius-control: var(--radius-control);
}
`
const INVENTORY = `# UI Inventory

| File | Page type | Frame | Status |
|---|---|---|---|
| \`record-layout.md\` | RecordScreen | \`form-shell\` | approved |

| File | Governs | Status |
|---|---|---|
| \`date-entry.md\` | Every date in the Acme order book | approved |
| \`saving.md\` | How a form saves | approved |
| \`loading.md\` | What shows while a screen loads | approved |
| \`unsaved.md\` | Leaving with changes not saved | approved |

| Component | Use for | Type | Status |
|---|---|---|---|
| \`empty-state\` | What a list says when it has nothing | EmptyState | approved |
| \`form-shell\` | The frame of a record screen | RecordScreen | approved |
| \`save-bar\` | A form's actions | FormActions | approved |

| Atom | Use for | Status |
|---|---|---|
| \`date-field\` | Every date | approved |
| \`ui/calendar\` | The month grid a date is picked from | approved |
| \`ui/button\` | A button | approved |
`
const rule = (code, extra = '') => `---\nkind: behaviour\ncode: [${code.join(', ')}]\nblock-types: cross-cutting\n${extra}ui-status: approved\n---\n`

const FILES = {
  'package.json': { name: 'acme-suite', workspaces: ['apps/*', 'packages/*'] },
  'tsconfig.json': TSCONFIG,
  '.gitignore': 'node_modules\n',
  '.claude/sync-substitutions.json': KEYS,
  '.claude/rules/project/ui-inventory.md': INVENTORY,
  '.claude/skills/ui-patterns/references/date-entry.md': `${rule(['packages/ui/src/components/date-field.tsx', 'packages/ui/src/components/ui/calendar.tsx'], 'apps: [apps/office]\n')}# Date entry\n\nEnter every date in the Acme order book with \`DateField\`.\n`,
  '.claude/skills/ui-patterns/references/saving.md': `${rule(['packages/ui/src/components/save-bar.tsx', 'packages/ui/src/components/form-shell.tsx'])}# Saving\n\nSave is offered once something has changed.\n`,
  '.claude/skills/ui-patterns/references/loading.md': `${rule(['packages/ui/src/components/form-shell.tsx'])}# Loading\n\nA skeleton holds the screen's shape.\n`,
  '.claude/skills/ui-patterns/references/unsaved.md': `${rule(['packages/ui/src/lib/unsaved-guard.ts'])}# Unsaved changes\n\nLeaving with changes not saved asks first.\n`,
  '.claude/skills/ui-patterns/references/record-layout.md': '---\nkind: recipe\nframe: form-shell\nreference: apps/office/src/routes/orders.tsx\nblock-types: [RecordScreen]\nui-status: approved\n---\n# Record screen\n\nThe actions slot takes `save-bar`; an empty list shows `empty-state`.\n',
  'packages/ui/package.json': { name: '@acme/ui' },
  'packages/ui/src/tokens.css': TOKENS,
  'packages/ui/src/type.css': TYPE,
  'packages/ui/src/styles.css': STYLES,
  'packages/ui/src/lib/class-groups.generated.ts': 'export const groups = {}\n',
  'packages/ui/src/lib/utils.ts': "import { groups } from './class-groups.generated'\nexport function cn(...parts: string[]) {\n  return parts.concat(Object.keys(groups)).join(' ')\n}\n",
  'packages/ui/src/lib/format.ts': "import { format } from 'datelib'\nexport const asDay = (d: Date) => format(d)\n",
  'packages/ui/src/lib/unsaved-guard.ts': "// ui-behaviour-code: unsaved.md\nimport { asDay } from './format'\n// Asks before the Acme order form is left.\nexport function confirmLeave(changed: boolean, at: Date): string | null {\n  return changed ? `Leave? Changed ${asDay(at)}` : null\n}\n",
  'packages/ui/src/components/ui/button.tsx': '// ui-status: approved\n// ui-atom\nexport function Button(props: { label: string }) {\n  return <button type="button">{props.label}</button>\n}\n',
  'packages/ui/src/components/ui/calendar.tsx': '// ui-status: approved\n// ui-atom\n// ui-behaviour: date-entry.md\nimport { Button } from "@acme/ui/components/ui/button"\nexport function Calendar() {\n  return <Button label="Today" />\n}\n',
  'packages/ui/src/components/date-field.tsx': '// ui-status: approved\n// ui-atom\n// ui-behaviour: date-entry.md\nimport { Calendar } from "@acme/ui/components/ui/calendar"\nimport { cn } from "@acme/ui/lib/utils"\nimport { asDay } from "../lib/format"\n// The order book reads its dates here.\nexport function DateField({ value }: { value: Date }) {\n  return <div className={cn("rounded-control bg-surface type-body")}>{asDay(value)}<Calendar /></div>\n}\nexport function DateZone({ children }: { children?: unknown }) {\n  return <>{children}</>\n}\n',
  'packages/ui/src/components/empty-state.tsx': '// ui-status: approved\n// ui-block: EmptyState\nexport function EmptyState({ text }: { text: string }) {\n  return <p className="type-body">{text}</p>\n}\n',
  'packages/ui/src/components/save-bar.tsx': '// ui-status: approved\n// ui-block: FormActions\n// ui-behaviour: saving.md\nimport { Button } from "./ui/button"\nexport function SaveBar() {\n  return <Button label="Save" />\n}\n',
  'packages/ui/src/components/form-shell.tsx': '// ui-status: approved\n// ui-block: RecordScreen\n// ui-behaviour: saving.md, loading.md\nimport { SaveBar } from "./save-bar"\nexport function FormShell({ children }: { children?: unknown }) {\n  return <form>{children}<SaveBar /></form>\n}\n',
  'apps/office/package.json': { name: 'office', dependencies: { '@acme/ui': '*' } },
  'apps/office/src/routes/__root.tsx': '// ui-content\nimport { DateZone } from "@acme/ui/components/date-field"\nexport function Root() {\n  return <DateZone />\n}\n',
  'apps/office/src/routes/orders.tsx': '// ui-recipe: record-layout.md\nimport { FormShell } from "@acme/ui/components/form-shell"\nexport function Orders() {\n  return <FormShell />\n}\n',
  'apps/office/src/features/invoices/list.tsx': '// ui-content\nexport const invoiceColumns = ["number"]\n',
  'apps/shared/package.json': { name: '@acme/shared' },
  'apps/shared/src/db.ts': 'export const rows = []\n',
  'node_modules/datelib/package.json': { name: 'datelib', version: '4.2.0' },
  'node_modules/react/package.json': { name: 'react', version: '19.0.0' },
  'node_modules/datelib/index.d.ts': 'export declare function format(d: Date): string\n',
  'node_modules/datelib/index.js': 'export const format = (d) => String(d)\n',
}

/** What Tailwind's build would say each class reads, for a project with no Tailwind installed. */
const tokensOf = (_file, cls) => ({ 'bg-surface': ['--surface'], 'rounded-control': ['--radius-control'] })[cls] ?? []

function project(overrides = {}) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-test-')))
  for (const [rel, content] of Object.entries({ ...FILES, ...overrides })) {
    if (content === null) continue
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), typeof content === 'string' ? content : JSON.stringify(content, null, 2))
  }
  const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', ...args], { stdio: 'ignore' })
  git('init', '-q')
  git('add', '-A')
  git('commit', '-q', '-m', 'the project')
  return dir
}

const extract = (dir, name, opts = {}) => planExtract(dir, name, { tokensOf, ...opts })

test('a rule travels with the code that carries it, the helper that code imports, and nothing the project keeps', async () => {
  const x = await extract(project(), 'date-entry', { allow: ['acme'] })
  assert.deepEqual(x.problems, [])
  assert.deepEqual(x.json.files, ['references/date-entry.md', 'packages/ui/src/components/date-field.tsx', 'packages/ui/src/components/ui/calendar.tsx', 'packages/ui/src/lib/format.ts'])
  assert.deepEqual(x.json.pieces, [])
  assert.deepEqual(x.json.packages, { datelib: '4.2.0', react: '19.0.0' }, 'markup needs React though no file imports it by name')
  assert.deepEqual(x.json.workspaces, { 'packages/ui': '@design-pack/ui' })
  assert.deepEqual(x.json.themes, ['light'])
  assert.deepEqual(x.json.imports, { '@design-pack/ui/components/ui/button': 'packages/ui/src/components/ui/button.tsx', '@design-pack/ui/components/ui/calendar': 'packages/ui/src/components/ui/calendar.tsx', '@design-pack/ui/lib/utils': 'packages/ui/src/lib/utils.ts' })
})

test('an atom that does not carry the rule is expected, with the exports taken; so is a helper built on a generated file', async () => {
  const x = await extract(project(), 'date-entry', { allow: ['acme'] })
  assert.deepEqual(x.json.atoms, [
    { name: 'button', file: 'packages/ui/src/components/ui/button.tsx', exports: ['Button'], piece: 'button' },
    { name: 'utils', file: 'packages/ui/src/lib/utils.ts', exports: ['cn'] },
  ])
})

test('a piece records the variants and options it passes to a file it expects, and nothing any element takes', async () => {
  const calendar = FILES['packages/ui/src/components/ui/calendar.tsx'].replace('<Button label="Today" />', '<Button label="Today" variant="quiet" size={"icon-affix"} className="mt-2" aria-label="x" />')
  const x = await extract(project({ 'packages/ui/src/components/ui/calendar.tsx': calendar }), 'date-entry', { allow: ['acme'] })
  assert.deepEqual(x.json.atoms[0].uses, { Button: { size: ['icon-affix'], variant: ['quiet'] } })
})

test('the roles are the type roles, and the tokens the build says each class reads', async () => {
  const x = await extract(project(), 'date-entry', { allow: ['acme'] })
  assert.deepEqual(x.json.roles, [
    { name: '--radius-control', purpose: "a control's corner", classes: ['rounded-control'] },
    { name: '--surface', purpose: "a panel's fill", classes: ['bg-surface'] },
    { name: 'type-body', purpose: 'running text', classes: ['type-body'] },
  ])
})

test('a role carries a value only where the pack names it, with the reason; the kit chooses none', async () => {
  const bare = await extract(project(), 'date-entry', { allow: ['acme'] })
  assert.ok(bare.json.roles.every((r) => !('value' in r) && !('why' in r)))
  const carries = [{ roles: ['type-*', '--radius-control'], why: 'a date field is dense' }]
  const x = await extract(project(), 'date-entry', { allow: ['acme'], carries })
  assert.deepEqual(x.json.roles, [
    { name: '--radius-control', purpose: "a control's corner", classes: ['rounded-control'], value: '6px', why: 'a date field is dense' },
    { name: '--surface', purpose: "a panel's fill", classes: ['bg-surface'] },
    { name: 'type-body', purpose: 'running text', classes: ['type-body'], value: 'font-size: 14px; line-height: 20px; font-weight: 400', why: 'a date field is dense' },
  ])
  assert.deepEqual([whyCarried(carries, 'type-body'), whyCarried(carries, '--radius-controls'), whyCarried(carries, '--surface')], ['a date field is dense', null, null])
  assert.deepEqual(carriesProblems(undefined), [])
  assert.match(carriesProblems([{ roles: ['--gap-*'] }])[0], /no `why` — a pack carries a value only with the reason/)
  assert.match(carriesProblems([{ why: 'compact' }])[0], /`roles` names the roles whose values travel/)
})

test('--from: an address is cloned, a folder is read where it stands', () => {
  for (const a of ['https://example.com/team/packs.git', 'ssh://git@example.com/team/packs', 'git@example.com:team/packs.git', 'file:///tmp/packs']) assert.ok(isRepositoryAddress(a), a)
  for (const a of ['../packs', '/Users/me/packs', 'packs', 'C:/work/packs']) assert.ok(!isRepositoryAddress(a), a)
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-from-')))
  assert.equal(packsCheckout(dir), dir, 'a folder is used as it is')
  execFileSync('git', ['-C', dir, 'init', '--quiet'])
  fs.mkdirSync(path.join(dir, 'pieces'))
  const cloned = packsCheckout(`file://${dir}`)
  assert.notEqual(cloned, dir)
  assert.ok(fs.existsSync(path.join(cloned, '.git')), 'an address is cloned to a folder of its own')
  fs.rmSync(dir, { recursive: true, force: true })
  fs.rmSync(cloned, { recursive: true, force: true })
})

test('the command line: compare and install each reach the packs checkout named by --from', () => {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-cli-')))
  fs.mkdirSync(path.join(root, 'project'))
  fs.mkdirSync(path.join(root, 'packs'))
  execFileSync('git', ['-C', path.join(root, 'project'), 'init', '--quiet'])
  const cli = fileURLToPath(new URL('./design-pack.mjs', import.meta.url))
  const run = (...args) => spawnSync(process.execPath, [cli, ...args, '--from', path.join(root, 'packs'), '--repo', path.join(root, 'project')], { encoding: 'utf8' })
  const compared = run('compare')
  assert.equal(compared.status, 1, 'comparing nothing is a failure, never a pass')
  assert.match(compared.stdout, /0 installed file\(s\) read/)
  assert.match(compared.stderr, /carries a pack pointer — nothing was compared/)
  // A project that is not ready is refused by name, never by a crash.
  const installed = run('install', 'a-piece', '--app', 'apps/web')
  assert.equal(installed.status, 1)
  assert.match(installed.stderr, /this project is not ready to take a piece/)
  assert.doesNotMatch(installed.stderr + compared.stderr, /ReferenceError/)
  fs.rmSync(root, { recursive: true, force: true })
})

test('a piece is proved once: its fingerprint is its files and the pieces it depends on, and only a change makes it due again', () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-proved-')))
  const put = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), typeof text === 'string' ? text : JSON.stringify(text))
  }
  put('button/piece.json', { files: ['b.tsx'], pieces: [] })
  put('button/b.tsx', 'export const B = 1\n')
  put('form/piece.json', { files: ['f.tsx'], pieces: ['button'] })
  put('form/f.tsx', 'export const F = 1\n')
  put('chart/piece.json', { files: ['c.tsx'], pieces: [] })
  put('chart/c.tsx', 'export const C = 1\n')
  assert.deepEqual(provedState(dir), { names: ['button', 'chart', 'form'], stale: ['button', 'chart', 'form'] }, 'never proved: every piece is due')
  for (const n of ['button', 'chart', 'form']) recordProof(dir, n)
  assert.deepEqual(provedState(dir).stale, [], 'proved as they stand: none is due')
  assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(path.join(dir, PROOFS), 'utf8'))), ['button', 'chart', 'form'])
  const before = pieceFingerprint(dir, 'form')
  put('button/b.tsx', 'export const B = 2\n')
  assert.deepEqual(provedState(dir).stale, ['button', 'form'], 'a changed piece is due, and so is each piece built on it; the rest are not')
  assert.notEqual(pieceFingerprint(dir, 'form'), before)
  put('chart/GUIDE.md', '# wiring\n')
  assert.deepEqual(provedState(dir).stale, ['button', 'chart', 'form'], 'any file of a piece counts')
  // Two pieces that depend on each other: each has one fingerprint, whichever is read first.
  put('on/piece.json', { files: ['o.tsx'], pieces: ['off'] })
  put('on/o.tsx', 'export const On = 1\n')
  put('off/piece.json', { files: ['o.tsx'], pieces: ['on'] })
  put('off/o.tsx', 'export const Off = 1\n')
  for (const n of ['button', 'chart', 'form', 'on', 'off']) recordProof(dir, n)
  assert.deepEqual(provedState(dir).stale, [], 'pieces in a loop are proved as they stand once each is recorded')
  put('off/o.tsx', 'export const Off = 2\n')
  assert.deepEqual(provedState(dir).stale, ['off', 'on'], 'and a change to one makes both due')
  fs.rmSync(path.join(dir, 'on'), { recursive: true })
  fs.rmSync(path.join(dir, 'off'), { recursive: true })
  // A piece taken out of the folder leaves the record with the next proof.
  fs.rmSync(path.join(dir, 'chart'), { recursive: true })
  recordProof(dir, 'button')
  assert.deepEqual(Object.keys(JSON.parse(fs.readFileSync(path.join(dir, PROOFS), 'utf8'))), ['button', 'form'])
  fs.rmSync(dir, { recursive: true, force: true })
})

test('coverage: a component is shown when a reference page reaches it through its imports; the rest are named', () => {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-coverage-')))
  const put = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), typeof text === 'string' ? text : JSON.stringify(text))
  }
  put('card/piece.json', { files: ['packages/ui/src/components/card.tsx', 'packages/ui/src/components/card-part.tsx'], imports: {} })
  put('card/packages/ui/src/components/card.tsx', "import { Part } from './card-part'\nexport const Card = Part\n")
  put('card/packages/ui/src/components/card-part.tsx', 'export const Part = null\n')
  put('chart/piece.json', { files: ['packages/ui/src/components/chart.tsx'], imports: {} })
  put('chart/packages/ui/src/components/chart.tsx', 'export const Chart = null\n')
  put('page/piece.json', { files: ['packages/web/src/reference/Form.tsx', 'packages/web/src/reference/shell.tsx'], imports: { '@design-pack/ui/components/card': 'packages/ui/src/components/card.tsx' } })
  put('page/packages/web/src/reference/Form.tsx', "// ui-status: pending\n// ui-recipe: form.md\nimport { Card } from '@design-pack/ui/components/card'\nexport const Form = Card\n")
  put('page/packages/web/src/reference/shell.tsx', '// ui-content\nexport const Shell = null\n')
  assert.deepEqual(coverage(dir), { pieces: 3, pages: ['packages/web/src/reference/Form.tsx'], components: 3, unreached: [{ piece: 'chart', file: 'packages/ui/src/components/chart.tsx' }] })
  fs.rmSync(dir, { recursive: true, force: true })
})

test("code is copied as it is, with the workspace's package name replaced on its imports", async () => {
  const x = await extract(project(), 'date-entry', { allow: ['acme'] })
  const text = x.texts.get('packages/ui/src/components/date-field.tsx')
  assert.match(text, /from "@design-pack\/ui\/components\/ui\/calendar"/)
  assert.match(text, /from "\.\.\/lib\/format"/)
  assert.doesNotMatch(text, /@acme/)
  assert.equal(text.replaceAll('@design-pack/ui', '@acme/ui'), FILES['packages/ui/src/components/date-field.tsx'])
})

test("a reference loses the lines naming the source project's apps and screens, and keeps the rest", () => {
  const out = packReference(FILES['.claude/skills/ui-patterns/references/record-layout.md'])
  assert.doesNotMatch(out, /^reference:/m)
  assert.match(out, /^frame: form-shell$/m)
  assert.doesNotMatch(packReference(FILES['.claude/skills/ui-patterns/references/date-entry.md']), /^apps:/m)
})

test('the inventory lines travel under the heading rows they came from', async () => {
  const x = await extract(project(), 'date-entry', { allow: ['acme'] })
  assert.match(x.inventory, /\| File \| Governs \| Status \|\n\|---\|---\|---\|\n\| `date-entry\.md` /)
  assert.match(x.inventory, /\| Atom \| Use for \| Status \|\n\|---\|---\|---\|\n\| `date-field` .*\n\| `ui\/calendar` /)
  assert.doesNotMatch(x.inventory, /ui\/button|empty-state/)
})

test('a domain word refuses nothing: in code it is named, in a comment or prose it is listed to reword', async () => {
  const x = await extract(project({ 'packages/ui/src/lib/format.ts': "import { format } from 'datelib'\nexport const acmeDay = (d: Date) => format(d)\nexport const asDay = acmeDay\n" }), 'date-entry')
  assert.deepEqual(x.problems, [])
  assert.ok(x.named.includes('packages/ui/src/lib/format.ts:2: `acme` in code'), x.named.join('\n'))
  assert.ok(x.rewrite.includes('packages/ui/src/components/date-field.tsx:7: `order` in a comment'), x.rewrite.join('\n'))
  assert.ok(x.rewrite.some((r) => /^references\/date-entry\.md:\d+: `acme`/.test(r)), x.rewrite.join('\n'))
  assert.ok(x.rewrite.some((r) => /^inventory\.md:\d+: `acme`/.test(r)), x.rewrite.join('\n'))
})

test('the words that name a project come from its packages, its feature folders and its routes, less what the system itself is named with', () => {
  const S = readSystem(project())
  const words = businessWords(S).map((seq) => seq.join(' '))
  for (const w of ['acme', 'acme suite', 'office', 'order', 'invoice']) assert.ok(words.includes(w), `${w} not in ${words.join(', ')}`)
  for (const w of ['ui', 'shared', 'root', 'list', 'date', 'form']) assert.ok(!words.includes(w), `${w} is not a business word`)
  assert.ok(!businessWords(S, { allow: ['office'] }).some((seq) => seq.join(' ') === 'office'))
  assert.ok(businessWords(S, { extra: ['Northwind Traders'] }).some((seq) => seq.join(' ') === 'northwind trader'))
})

test('a word is matched as a whole word of a name, plural or singular, never inside another', () => {
  assert.deepEqual(wordsOf('MeterReadings useACMEClient'), ['meter', 'reading', 'use', 'acme', 'client'])
  const hits = (text) => wordHits(text, [['order'], ['meter', 'reading']]).map((h) => `${h.line} ${h.word} ${h.where}`)
  assert.deepEqual(hits('const orders = 1 // every meter reading'), ['1 order code', '1 meter reading comment'])
  assert.deepEqual(hits('const reorder = border /* fine */'), [])
  assert.deepEqual(hits('/*\n * the Orders screen\n */\nconst a = 1'), ['2 order comment'])
})

test('an atom the project made travels with what imports it, or brings the piece of the rule it carries', () => {
  const badge = '// ui-status: approved\n// ui-atom\nexport function Dot() {\n  return <i />\n}\n'
  const uses = (file) => `// ui-status: approved\n// ui-block: EmptyState\nimport { Dot } from "./${file}"\nexport function EmptyState() {\n  return <Dot />\n}\n`
  const made = workOut(readSystem(project({ 'packages/ui/src/components/dot.tsx': badge, 'packages/ui/src/components/empty-state.tsx': uses('dot') })), 'empty-state')
  assert.deepEqual(made.files, ['packages/ui/src/components/dot.tsx', 'packages/ui/src/components/empty-state.tsx'])
  assert.deepEqual([...made.atoms.keys()], [])
  const ruled = workOut(readSystem(project({ 'packages/ui/src/components/empty-state.tsx': `// ui-status: approved\n// ui-block: EmptyState\nimport { DateField } from "./date-field"\nexport function EmptyState() {\n  return <DateField value={new Date()} />\n}\n` })), 'empty-state')
  assert.deepEqual(ruled.pieces, ['date-entry'])
  assert.deepEqual(ruled.files, ['packages/ui/src/components/empty-state.tsx'])
})

test('an atom the project made that a rule tells a builder to use is a piece the rule brings, unless a component already carries it', () => {
  const quiet = '// ui-status: approved\n// ui-atom\nexport function QuietValue() {\n  return <i />\n}\n'
  const saving = FILES['.claude/skills/ui-patterns/references/saving.md'].replace(/\n$/, '\nShow a value that cannot change as `QuietValue`.\n')
  const S = readSystem(project({ 'packages/ui/src/components/quiet-value.tsx': quiet, '.claude/skills/ui-patterns/references/saving.md': saving }))
  const alone = workOut(S, 'quiet-value')
  assert.deepEqual([alone.kind, alone.files], ['atom', ['packages/ui/src/components/quiet-value.tsx']])
  assert.ok(workOut(S, 'saving').pieces.includes('quiet-value'))
  // Imported by a block, it travels with the block and is no piece of its own.
  const block = '// ui-status: approved\n// ui-block: EmptyState\nimport { QuietValue } from "./quiet-value"\nexport function EmptyState() {\n  return <QuietValue />\n}\n'
  const carried = readSystem(project({ 'packages/ui/src/components/quiet-value.tsx': quiet, 'packages/ui/src/components/empty-state.tsx': block, '.claude/skills/ui-patterns/references/saving.md': saving }))
  assert.ok(!workOut(carried, 'saving').pieces.includes('quiet-value'))
})

test('a file carrying several rules is its own piece: it depends on each of them, and they name it a carrier', async () => {
  const dir = project()
  const S = readSystem(dir)
  assert.equal(classify(S, 'packages/ui/src/components/form-shell.tsx').piece, 'form-shell')
  assert.equal(classify(S, 'packages/ui/src/components/save-bar.tsx').piece, 'saving')
  const saving = workOut(S, 'saving')
  assert.deepEqual(saving.files, ['packages/ui/src/components/save-bar.tsx'])
  assert.deepEqual(saving.pieces, [])
  assert.deepEqual(saving.carriers, ['form-shell'])
  const shell = workOut(S, 'form-shell')
  assert.equal(shell.kind, 'block')
  assert.deepEqual(shell.files, ['packages/ui/src/components/form-shell.tsx'])
  assert.deepEqual(shell.pieces, ['loading', 'saving'])
})

test('a recipe is installed with its frame and every block its instructions name', async () => {
  const x = await extract(project(), 'record-layout')
  assert.deepEqual(x.problems, [])
  assert.deepEqual(x.json.files, ['references/record-layout.md'])
  assert.deepEqual(x.json.pieces, ['empty-state', 'form-shell', 'saving'])
  assert.deepEqual(x.json.workspaces, {})
})

test('a name that is not a piece is refused, saying which piece holds it', () => {
  const S = readSystem(project())
  assert.match(workOut(S, 'save-bar').problems[0], /travels in the piece `saving`, whose rule it carries — extract that/)
  assert.match(workOut(S, 'date-field').problems[0], /travels in the piece `date-entry`/)
  const control = workOut(S, 'button')
  assert.deepEqual([control.kind, control.files], ['control', ['packages/ui/src/components/ui/button.tsx']])
  assert.match(workOut(S, 'nothing').problems[0], /names no recipe or behaviour rule .* and no block of the system/)
})

test('a piece that imports business code, a screen, a generated file or nothing at all is refused, naming each', () => {
  const block = (imports) => `// ui-status: approved\n// ui-block: EmptyState\n${imports}\nexport function EmptyState() {\n  return <p />\n}\n`
  const problems = (imports) => workOut(readSystem(project({ 'packages/ui/src/components/empty-state.tsx': block(imports) })), 'empty-state').problems.join('\n')
  assert.match(problems('import { rows } from "@acme/shared/db"'), /imports `apps\/shared\/src\/db\.ts`, and it is the project's own code, outside the workspaces its UI lives in — a pack holds no business code/)
  assert.match(problems('import { invoiceColumns } from "../../../../apps/office/src/features/invoices/list"'), /imports `apps\/office\/src\/features\/invoices\/list\.tsx`, and it is an app's own code/)
  assert.match(problems('import { groups } from "../lib/class-groups.generated"'), /imports the generated file `packages\/ui\/src\/lib\/class-groups\.generated\.ts`/)
  assert.match(problems('import { gone } from "./gone"'), /imports `\.\/gone`, which resolves to nothing/)
  assert.match(problems('import { x } from "not-installed"'), /imports `not-installed`, which is not installed — its version cannot be read/)
})

test("a rule's code that is the source project's own — an app's wiring, its server half — stays behind, named for the guide", async () => {
  const dir = project({
    '.claude/skills/ui-patterns/references/unsaved.md': `${rule(['packages/ui/src/lib/unsaved-guard.ts', 'apps/office/src/lib/leave.ts', 'packages/ui/src/lib/drafts.server.ts'])}# Unsaved changes\n\nLeaving with changes not saved asks first.\n`,
    'apps/office/src/lib/leave.ts': '// ui-behaviour-code: unsaved.md\nexport const leave = 1\n',
    'packages/ui/src/lib/drafts.server.ts': '// ui-behaviour-code: unsaved.md\nexport const drafts = 1\n',
  })
  const x = await extract(dir, 'unsaved', { allow: ['acme'] })
  assert.deepEqual(x.problems, [])
  assert.deepEqual(x.json.files, ['references/unsaved.md', 'packages/ui/src/lib/format.ts', 'packages/ui/src/lib/unsaved-guard.ts'])
  assert.match(x.texts.get('references/unsaved.md'), /^code: \[packages\/ui\/src\/lib\/unsaved-guard\.ts\]$/m)
  assert.deepEqual(x.wiring, ['apps/office/src/lib/leave.ts: carries the rule out in the source project', 'packages/ui/src/lib/drafts.server.ts: carries the rule out in the source project'])
})

test("a logger or a user-facing error class of the project's own is expected, never held; any other business code refuses the piece", async () => {
  const dir = project({
    'apps/shared/src/logger.ts': 'export const logger = { info() {} }\n',
    'packages/ui/src/lib/format.ts': "import { logger } from '@acme/shared/logger'\nexport const asDay = (d: Date) => (logger.info(), String(d))\n",
  })
  const x = await extract(dir, 'unsaved', { allow: ['acme'] })
  assert.deepEqual(x.problems, [])
  assert.deepEqual(x.json.atoms, [{ name: 'logger', file: 'apps/shared/src/logger.ts', exports: ['logger'] }])
  assert.match(x.texts.get('packages/ui/src/lib/format.ts'), /from '@design-pack\/shared\/logger'/)
  const other = project({ 'packages/ui/src/lib/format.ts': "import { rows } from '@acme/shared/db'\nexport const asDay = (d: Date) => String(d) + rows.length\n" })
  const refused = await extract(other, 'unsaved', { allow: ['acme'] })
  assert.ok(refused.problems.some((p) => /imports `apps\/shared\/src\/db\.ts`.*a pack holds no business code/.test(p)), refused.problems.join('\n'))
})

test("the wiring the source project does with the piece is listed, from its own roots and providers", async () => {
  const x = await extract(project(), 'date-entry', { allow: ['acme'] })
  assert.deepEqual(x.wiring, ['apps/office/src/routes/__root.tsx: DateZone'])
})

test('renaming touches module specifiers only, and only a workspace of the system', () => {
  const ts = loadTypeScript()
  const names = new Map([['@acme/ui', '@design-pack/ui'], ['@acme/shared', null]])
  const src = 'import a from "@acme/ui/x"\nexport * from "@acme/ui"\nconst b = await import("@acme/ui/y")\nconst s = "@acme/ui/z"\nimport c from "@acme/shared/c"\nimport d from "@acme/ui-kit"\n'
  assert.equal(renamePackage(ts, 'f.ts', src, names), 'import a from "@design-pack/ui/x"\nexport * from "@design-pack/ui"\nconst b = await import("@design-pack/ui/y")\nconst s = "@acme/ui/z"\nimport c from "@acme/shared/c"\nimport d from "@acme/ui-kit"\n')
})

test('the same code is the same whatever its comments say, and different once a line of code is', () => {
  const ts = loadTypeScript()
  const a = '// one\nexport function A() {\n  return <p>{/* note */}x</p> // tail\n}\n'
  assert.equal(codeOnly(ts, 'a.tsx', a), codeOnly(ts, 'a.tsx', '// another thing\nexport function A() {\n  return <p>{/* reworded */}x</p>\n}\n'))
  assert.notEqual(codeOnly(ts, 'a.tsx', a), codeOnly(ts, 'a.tsx', a.replace('}x<', '}y<')))
})

test('a stand-in gives each export taken a value, and the source file\'s own types when it has them', () => {
  assert.deepEqual(stubFor(['Button', 'default', '*']), { js: 'export const Button = undefined\nexport default undefined\n', dts: 'export declare const Button: any\nexport type Button = any\ndeclare const stub: any\nexport default stub\n' })
  assert.equal(stubFor(['Button'], 'export declare function Button(): null\n').dts, 'export declare function Button(): null\n')
})

test('the preconditions are a clean tree and nothing pending', () => {
  const dir = project()
  assert.ok(!preconditions(dir).some((p) => /uncommitted/.test(p)))
  fs.writeFileSync(path.join(dir, 'note.txt'), 'x')
  fs.mkdirSync(path.join(dir, 'out/piece'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'out/piece/piece.json'), '{}')
  assert.ok(preconditions(dir).some((p) => /the tree has 2 uncommitted change\(s\)/.test(p)))
  assert.ok(preconditions(dir, { ignore: 'out/' }).some((p) => /the tree has 1 uncommitted change\(s\)/.test(p)))
  const pending = project({ 'packages/ui/src/components/empty-state.tsx': FILES['packages/ui/src/components/empty-state.tsx'].replace('approved', 'pending') })
  assert.ok(preconditions(pending).some((p) => /^pending: packages\/ui\/src\/components\/empty-state\.tsx/.test(p)))
})

// ─── prove ───────────────────────────────────────────────────────────────────

async function extracted(name, opts = {}) {
  const dir = project()
  const x = await extract(dir, name, opts)
  assert.deepEqual(x.problems, [])
  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-out-')), name)
  writePiece(out, x)
  return { dir, out, x }
}

test('prove says what was adjusted in the folder and counts domain words, and refuses on neither', async () => {
  const { dir, out } = await extracted('unsaved', { allow: ['acme'] })
  const file = path.join(out, 'packages/ui/src/lib/unsaved-guard.ts')
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('Leave?', 'Go?'))
  const json = JSON.parse(fs.readFileSync(path.join(out, 'piece.json'), 'utf8'))
  fs.writeFileSync(path.join(out, 'piece.json'), JSON.stringify({ ...json, packages: {} }))
  const { problems, notes } = await prove(dir, out, { tokensOf })
  assert.ok(notes.some((n) => /^domain words: [1-9]\d* place\(s\)/.test(n)), notes.join('\n'))
  assert.ok(notes.some((n) => /^adjusted from the source project: 1 file\(s\) \(packages\/ui\/src\/lib\/unsaved-guard\.ts\), and piece\.json/.test(n)), notes.join('\n'))
  assert.ok(!problems.some((p) => /differs|piece\.json is not/.test(p)), problems.join('\n'))
  assert.ok(!problems.some((p) => /acme/.test(p)), problems.join('\n'))
})

test('a file piece.json lists that is not in the folder stops the proof', async () => {
  const { dir, out } = await extracted('unsaved', { allow: ['acme'] })
  fs.rmSync(path.join(out, 'packages/ui/src/lib/format.ts'))
  const { problems } = await prove(dir, out, { tokensOf, allow: ['acme'] })
  assert.ok(problems.some((p) => /format\.ts: piece\.json lists it, and it is not in the piece folder/.test(p)), problems.join('\n'))
})

test('prove refuses a piece whose dependency is not extracted beside it', async () => {
  const { dir, out } = await extracted('form-shell')
  const { problems } = await prove(dir, out, { tokensOf })
  assert.ok(problems.some((p) => /it depends on the piece `saving`, which is not extracted beside it/.test(p)), problems.join('\n'))
})

// Tailwind for the token check in the fixture, from the global npm root, as TypeScript is
// found; the fixture links it from the source project, so the test project is given it.
const TAILWIND_GLOBAL = (() => {
  try {
    const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()
    return ['tailwindcss', '@tailwindcss/node', '@tailwindcss/oxide'].every((p) => fs.existsSync(path.join(root, p))) ? root : null
  } catch {
    return null
  }
})()
const TAILWIND_SKIP = TAILWIND_GLOBAL ? false : 'the proof compiles the stylesheet with Tailwind, installed globally (npm i -g tailwindcss @tailwindcss/node @tailwindcss/oxide)'
function withTailwind(dir) {
  for (const p of ['tailwindcss', '@tailwindcss/node', '@tailwindcss/oxide']) {
    fs.mkdirSync(path.dirname(path.join(dir, 'node_modules', p)), { recursive: true })
    fs.symlinkSync(path.join(TAILWIND_GLOBAL, p), path.join(dir, 'node_modules', p))
  }
}

test('prove installs the piece in an empty project: it typechecks and passes the token and status checks there, and says what stops the build', { skip: TAILWIND_SKIP }, async () => {
  const { dir, out } = await extracted('unsaved', { allow: ['acme'] })
  const file = path.join(out, 'packages/ui/src/lib/unsaved-guard.ts')
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('the Acme order form', 'a form'))
  withTailwind(dir)
  const { problems, notes } = await prove(dir, out, { tokensOf, allow: ['acme'] })
  assert.deepEqual(problems, ['build: vite is not installed in the source project, so the piece cannot be built'], notes.join('\n'))
  assert.ok(notes.some((n) => /^adjusted from the source project: 0 file\(s\)/.test(n)), notes.join('\n'))
  assert.ok(notes.some((n) => /^typecheck: 2 file\(s\)/.test(n)), notes.join('\n'))
  assert.ok(notes.some((n) => /^token check: the source project declares no spacing scale; 2 source file\(s\) and \d+ classes against the source project's stylesheets, \d+ of its \d+ tokens being ones the piece does not reach/.test(n)), notes.join('\n'))
  assert.ok(notes.some((n) => /^status check: 0 component\(s\), 1 reference\(s\)/.test(n)), notes.join('\n'))
})

test('in the empty project a library piece.json does not name, or an export no stand-in offers, fails the typecheck', { skip: TAILWIND_SKIP }, async () => {
  const { dir, out, x } = await extracted('unsaved', { allow: ['acme'] })
  withTailwind(dir)
  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-fixture-'))
  const { problems } = await proveInFixture(x.S, fixture, [{ dir: out, name: 'unsaved', json: { ...x.json, packages: {} } }])
  assert.ok(problems.some((p) => /^typecheck: packages\/ui\/src\/lib\/format\.ts:1: Cannot find module 'datelib'/.test(p)), problems.join('\n'))
})

test('the command line extracts into the folder named, refuses a dirty tree, and prints what it inspected', () => {
  const dir = project()
  const run = (...args) => {
    try {
      return { code: 0, out: execFileSync('node', [CLI, ...args, '--repo', dir], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }) }
    } catch (err) {
      return { code: err.status, out: `${err.stdout}${err.stderr}` }
    }
  }
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-cli-'))
  // No stylesheet imports tailwindcss in this project, so the roles cannot be read: said, not skipped.
  const first = run('extract', 'unsaved', '--out', out, '--allow', 'acme')
  assert.equal(first.code, 1)
  assert.match(first.out, /no stylesheet imports tailwindcss, so the roles the piece uses cannot be read/)
  assert.equal(run('extract').code, 2)
  fs.writeFileSync(path.join(dir, 'note.txt'), 'x')
  assert.match(run('extract', 'unsaved', '--out', out).out, /the tree has 1 uncommitted change\(s\) — a piece is cut from committed work/)
})
