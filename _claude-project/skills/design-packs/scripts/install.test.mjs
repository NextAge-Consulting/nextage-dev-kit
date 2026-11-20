import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { applyInstall, approveInstalled, blockers, carriedHere, compare, compliance, destOf, installedFiles, landedInventory, piecesFor, planInstall, readPack, readProject, roleWork, specifierFor } from './install.mjs'

const KEYS = { DESIGN_UI_PACKAGE: 'packages/ui', DESIGN_FEED_BARREL: 'src/index.ts', DESIGN_TOKEN_FILES: 'src/tokens.css', DESIGN_TYPE_FILE: 'src/type.css', DESIGN_STYLES_FILE: 'src/styles.css', DESIGN_VENDORED_DIR: 'packages/ui/src/components/ui', DESIGN_VENDORED_RESTYLED: 'true', DESIGN_FIELD_LOOK_CLASSES: '', DESIGN_EXEMPT_COMPONENTS: '' }

function tree(files) {
  const dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-install-')))
  for (const [rel, content] of Object.entries(files)) {
    if (content === null) continue
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), typeof content === 'string' ? content : JSON.stringify(content, null, 2))
  }
  return dir
}
// The app the pieces are installed for in these cases.
const APP = { apps: ['apps/shop'] }

const git = (dir, ...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.com', ...args], { encoding: 'utf8' }).trim()

// The receiving project: components in PascalCase, vendored atoms in kebab-case, its own
// class-merge helper under another name, an empty-state block of its own.
const PROJECT = {
  'package.json': { name: 'north', workspaces: ['apps/*', 'packages/*'] },
  '.gitignore': 'node_modules\n',
  '.claude/sync-substitutions.json': KEYS,
  '.claude/rules/project/ui-inventory.md': '# UI Inventory\n\n<!-- project:begin recipes -->\n<!-- project:end recipes -->\n\n<!-- project:begin behaviour-rules -->\n<!-- project:end behaviour-rules -->\n\n<!-- project:begin components -->\n| Component | Use for | Type | Status |\n|---|---|---|---|\n| `EmptyState` | Nothing to show | EmptyState | approved |\n<!-- project:end components -->\n',
  'packages/ui/package.json': { name: '@north/ui', exports: { './components/*': './src/components/*.tsx', './lib/*': './src/lib/*.ts' } },
  'packages/ui/src/tokens.css': ':root {\n  /* a panel */\n  --surface: #fff;\n}\n',
  'packages/ui/src/type.css': '/* running text */\n@utility type-body {\n  font-size: 14px;\n}\n',
  'packages/ui/src/styles.css': '@theme inline {\n  --color-surface: var(--surface);\n}\n',
  'packages/ui/src/lib/cn.ts': 'export function cn(...parts: string[]) {\n  return parts.join(" ")\n}\n',
  'packages/ui/src/components/ui/button.tsx': '// ui-status: approved\n// ui-atom\nexport function Button() {\n  return null\n}\n',
  'packages/ui/src/components/EmptyState.tsx': '// ui-status: approved\n// ui-block: EmptyState\nexport function EmptyState() {\n  return null\n}\n',
  'packages/ui/src/components/PageBanner.tsx': '// ui-status: approved\n// ui-block: PageBanner\nimport { EmptyState } from "./EmptyState"\nexport function PageBanner() {\n  return <EmptyState />\n}\n',
  'packages/web/package.json': { name: '@north/web', dependencies: { '@north/ui': '*' }, exports: { './components/*': './src/components/*.tsx' } },
  'packages/web/src/components/TopBar.tsx': '// ui-status: approved\n// ui-block: AppShell\nexport function TopBar() {\n  return null\n}\n',
  'apps/shop/package.json': { name: 'shop', dependencies: { '@north/ui': '*', '@north/web': '*' } },
  'apps/shop/src/routes/home.tsx': '// ui-content\nimport { EmptyState } from "@north/ui/components/EmptyState"\nexport const Home = EmptyState\n',
}

const WORKSPACES = { 'packages/ui': '@design-pack/ui', 'packages/web': '@design-pack/web' }
const PACK = {
  'packs/back-office.json': { pieces: ['date-entry', 'form-shell'] },
  'pieces/date-entry/piece.json': {
    files: ['references/date-entry.md', 'packages/ui/src/components/date-field.tsx', 'packages/ui/src/components/ui/calendar.tsx', 'packages/ui/src/lib/format.ts'],
    pieces: [],
    atoms: [
      { name: 'button', file: 'packages/ui/src/components/ui/button.tsx', exports: ['Button'] },
      { name: 'utils', file: 'packages/ui/src/lib/utils.ts', exports: ['cn'] },
    ],
    roles: [{ name: '--radius-control', purpose: "a control's corner" }, { name: '--surface', purpose: 'a panel' }, { name: 'type-body', purpose: 'running text' }],
    packages: { datelib: '4.2.0' },
    workspaces: WORKSPACES,
    imports: { '@design-pack/ui/components/ui/calendar': 'packages/ui/src/components/ui/calendar.tsx', '@design-pack/ui/components/ui/button': 'packages/ui/src/components/ui/button.tsx', '@design-pack/ui/lib/utils': 'packages/ui/src/lib/utils.ts' },
  },
  'pieces/date-entry/inventory.md': '| File | Governs | Status |\n|---|---|---|\n| `date-entry.md` | Every date | approved |\n\n| Atom | Use for | Status |\n|---|---|---|\n| `date-field` | Every date | approved |\n| `ui/calendar` | The month grid | approved |\n',
  'pieces/date-entry/references/date-entry.md': '---\nkind: behaviour\ncode: [packages/ui/src/components/date-field.tsx, packages/ui/src/components/ui/calendar.tsx]\nblock-types: cross-cutting\nui-status: approved\n---\n# Date entry\n\nEnter every date with `DateField`.\n',
  'pieces/date-entry/packages/ui/src/components/date-field.tsx': '// ui-status: approved\n// ui-atom\n// ui-behaviour: date-entry.md\n"use client"\nimport { Calendar } from "@design-pack/ui/components/ui/calendar"\nimport { cn } from "@design-pack/ui/lib/utils"\nimport { asDay } from "../lib/format"\nexport function DateField({ value }: { value: Date }) {\n  return <div className={cn("bg-surface type-body")}>{asDay(value)}<Calendar /></div>\n}\n',
  'pieces/date-entry/packages/ui/src/components/ui/calendar.tsx': '// ui-status: approved\n// ui-atom\n// ui-behaviour: date-entry.md\nimport { Button } from "@design-pack/ui/components/ui/button"\nexport function Calendar() {\n  return <Button />\n}\n',
  'pieces/date-entry/packages/ui/src/lib/format.ts': "import { format } from 'datelib'\nexport const asDay = (d: Date) => format(d)\n",
  'pieces/empty-state/piece.json': { files: ['packages/ui/src/components/empty-state.tsx'], pieces: [], atoms: [], roles: [], packages: {}, workspaces: WORKSPACES, imports: {} },
  'pieces/empty-state/inventory.md': '| Component | Use for | Type | Status |\n|---|---|---|---|\n| `empty-state` | What a list says when it has nothing | EmptyState | approved |\n',
  'pieces/empty-state/packages/ui/src/components/empty-state.tsx': '// ui-status: approved\n// ui-block: EmptyState\nexport function EmptyState({ text }: { text: string }) {\n  return <p>{text}</p>\n}\n',
  'pieces/form-shell/piece.json': { files: ['packages/web/src/components/form-shell.tsx'], pieces: ['empty-state'], atoms: [], roles: [], packages: {}, workspaces: WORKSPACES, imports: { '@design-pack/ui/components/empty-state': 'packages/ui/src/components/empty-state.tsx' } },
  'pieces/form-shell/inventory.md': '| Component | Use for | Type | Status |\n|---|---|---|---|\n| `form-shell` | The frame of a record screen | RecordScreen | approved |\n',
  'pieces/form-shell/packages/web/src/components/form-shell.tsx': '// ui-status: approved\n// ui-block: RecordScreen\nimport { EmptyState } from "@design-pack/ui/components/empty-state"\nexport function FormShell() {\n  return <EmptyState text="" />\n}\n',
}

function project(overrides = {}) {
  const dir = tree({ ...PROJECT, ...overrides })
  git(dir, 'init', '-q')
  return dir
}
function pack(overrides = {}) {
  const dir = tree({ ...PACK, ...overrides })
  git(dir, 'init', '-q')
  git(dir, 'add', '-A')
  git(dir, 'commit', '-q', '-m', 'the pack')
  return dir
}

test('an app pack is its pieces, each piece they depend on ahead of it; a swap replaces one listed name', () => {
  const p = readPack(pack())
  assert.deepEqual(piecesFor(p, 'back-office').order.map((x) => x.name), ['date-entry', 'empty-state', 'form-shell'])
  assert.deepEqual(piecesFor(p, 'form-shell').order.map((x) => x.name), ['empty-state', 'form-shell'])
  assert.deepEqual(piecesFor(p, 'back-office', { 'date-entry': 'empty-state' }).order.map((x) => x.name), ['empty-state', 'form-shell'])
  assert.match(piecesFor(p, 'back-office', { nothing: 'empty-state' }).problems[0], /`back-office` does not list `nothing`/)
  assert.match(piecesFor(p, 'gone').problems[0], /`gone` is not a piece of this pack/)
})

test("a file lands in the workspace named as its own, and a component is named as its folder's files are", () => {
  const P = readProject(project())
  const piece = readPack(pack()).piece('date-entry')
  assert.equal(destOf(P, piece, 'packages/ui/src/components/date-field.tsx'), 'packages/ui/src/components/DateField.tsx')
  assert.equal(destOf(P, piece, 'packages/ui/src/components/ui/calendar.tsx'), 'packages/ui/src/components/ui/calendar.tsx')
  assert.equal(destOf(P, piece, 'packages/ui/src/lib/format.ts'), 'packages/ui/src/lib/format.ts')
  assert.equal(destOf(P, piece, 'packages/web/src/components/form-shell.tsx'), 'packages/web/src/components/FormShell.tsx')
  const alone = readProject(project({ 'packages/web/package.json': { name: '@north/web' } }))
  assert.equal(destOf(alone, piece, 'packages/web/src/components/form-shell.tsx'), 'packages/ui/src/components/FormShell.tsx')
})

test('an import names the file it meant: relative inside a workspace, by the package and its exports across them', () => {
  const P = readProject(project())
  assert.equal(specifierFor(P, 'packages/ui/src/components/DateField.tsx', 'packages/ui/src/lib/cn.ts'), '../lib/cn')
  assert.equal(specifierFor(P, 'packages/web/src/components/FormShell.tsx', 'packages/ui/src/components/EmptyState.tsx'), '@north/ui/components/EmptyState')
  assert.equal(specifierFor(P, 'packages/web/src/components/FormShell.tsx', 'packages/ui/src/hooks/useThing.ts'), null)
})

test("what a piece expects is found by its path, or as the one file exporting what it takes; what is not there stops the install, and what lacks an export is listed", () => {
  const from = pack()
  const plan = planInstall(project(), from, 'date-entry', APP)
  assert.deepEqual(plan.expected.map((e) => [e.name, e.found, e.missing]), [['button', 'packages/ui/src/components/ui/button.tsx', []], ['utils', 'packages/ui/src/lib/cn.ts', []]])
  assert.deepEqual(blockers(plan), [])
  const none = planInstall(project({ 'packages/ui/src/lib/cn.ts': 'export const other = 1\n' }), from, 'date-entry', APP)
  assert.match(blockers(none).join('\n'), /date-entry expects this project to have `utils` \(cn\), and no file here is it/)
  const lacking = planInstall(project({ 'packages/ui/src/components/ui/button.tsx': '// ui-status: approved\n// ui-atom\nexport const Other = 1\n' }), from, 'date-entry', APP)
  assert.deepEqual(blockers(lacking), [])
  assert.deepEqual(lacking.expected.find((e) => e.name === 'button').missing, ['Button'])
  const named = planInstall(project({ 'packages/ui/src/lib/cn.ts': 'export const other = 1\n', 'packages/ui/src/lib/merge.ts': 'export const cn = 1\nexport const x = 2\n', 'packages/ui/src/lib/merge2.ts': 'export const cn = 1\n' }), from, 'date-entry', { ...APP, map: { standIn: { 'packages/ui/src/lib/utils.ts': 'packages/ui/src/lib/merge.ts' } } })
  assert.deepEqual(blockers(named), [])
})

test('a helper that exports a name a file of its folder already exports stands beside it, whatever the files are called', () => {
  const dir = project({ 'packages/ui/src/lib/days.ts': 'export const asDay = () => "mine"\nexport const other = 1\n' })
  const plan = planInstall(dir, pack(), 'date-entry', APP)
  assert.deepEqual(plan.beside.map((b) => [b.file, b.existing, b.why]), [['packages/ui/src/lib/format.ts', 'packages/ui/src/lib/days.ts', 'it exports the same name, asDay']])
})

test('the plan says which workspace each library is for, and which landed components no package path reaches', () => {
  const plan = planInstall(project({ 'packages/web/package.json': { name: '@north/web', dependencies: { '@north/ui': '*' }, exports: { './*': './src/*.ts' } } }), pack(), 'back-office', { ...APP, map: { beside: { 'packages/ui/src/components/empty-state.tsx': 'use-existing' } } })
  assert.deepEqual(plan.packages.map((l) => [l.name, l.into]), [['datelib', ['packages/ui']]])
  assert.deepEqual(plan.unexported, ['packages/web/src/components/FormShell.tsx'])
})

test('a pack built for light and dark says so when the project has no dark theme, and nothing when it has', () => {
  const from = pack({ 'pieces/date-entry/piece.json': { ...PACK['pieces/date-entry/piece.json'], themes: ['light', 'dark'] } })
  assert.deepEqual(planInstall(project(), from, 'date-entry', APP).themes, { pack: ['light', 'dark'], project: ['light'], missing: ['dark'] })
  const dark = project({ 'packages/ui/src/tokens.css': ':root {\n  /* a panel */\n  --surface: #fff;\n}\n.dark {\n  --surface: #000;\n}\n' })
  assert.deepEqual(planInstall(dark, from, 'date-entry', APP).themes.missing, [])
  assert.deepEqual(planInstall(project(), pack(), 'date-entry', APP).themes.missing, [])
})

test('a control the pieces expect lands with them where the project has none, and is left alone where it has one', () => {
  const withControl = { ...PACK,
    'pieces/date-entry/piece.json': { ...PACK['pieces/date-entry/piece.json'], atoms: [{ ...PACK['pieces/date-entry/piece.json'].atoms[0], piece: 'button' }, PACK['pieces/date-entry/piece.json'].atoms[1]] },
    'pieces/button/piece.json': { files: ['packages/ui/src/components/ui/button.tsx'], pieces: [], atoms: [], roles: [], packages: {}, workspaces: WORKSPACES, imports: {} },
    'pieces/button/inventory.md': '| Atom | Status |\n|---|---|\n| `ui/button` | approved |\n',
    'pieces/button/packages/ui/src/components/ui/button.tsx': '// ui-status: approved\n// ui-atom\nexport function Button() {\n  return <button type="button" />\n}\n',
  }
  const has = planInstall(project(), tree(withControl), 'date-entry', APP)
  assert.deepEqual(has.pieces.map((p) => p.name), ['date-entry'])
  const none = project({ 'packages/ui/src/components/ui/button.tsx': null })
  const plan = planInstall(none, tree(withControl), 'date-entry', APP)
  assert.deepEqual(plan.pieces.map((p) => p.name), ['date-entry', 'button'])
  assert.deepEqual(blockers(plan), [])
  applyInstall(none, plan)
  assert.match(fs.readFileSync(path.join(none, 'packages/ui/src/components/ui/button.tsx'), 'utf8'), /^\/\/ ui-status: pending\n\/\/ ui-pack: button\/packages\/ui\/src\/components\/ui\/button\.tsx @ /)
})

test("a project is ready only when both checks are clean; what a pack landed is the install's own", async () => {
  const dir = project()
  const clean = { problems: [], counts: { sourceFiles: 3, classesChecked: 9 } }
  const settled = { problems: [], pending: [], counts: { components: 2, references: 1, screens: 0 } }
  const seen = []
  const ready = await compliance(dir, { tokens: async (_, o) => (seen.push(o), clean), status: () => settled })
  assert.deepEqual(ready.problems, [])
  assert.deepEqual([seen[0].all, seen[0].keys.DESIGN_VENDORED_RESTYLED], [true, 'true'], 'the vendored atoms are read whatever the project set')
  const stock = await compliance(dir, {
    tokens: async () => ({ ...clean, problems: ['packages/ui/src/components/ui/card.tsx:16  rounded-xl  — not a radius role'] }),
    status: () => ({ ...settled, pending: ['packages/ui/src/components/Thing.tsx (component)'], problems: ['packages/ui/src/components/Thing.tsx: not in the inventory'] }),
  })
  assert.deepEqual(stock.problems, [
    'token check: packages/ui/src/components/ui/card.tsx:16  rounded-xl  — not a radius role',
    'status check: packages/ui/src/components/Thing.tsx: not in the inventory',
    "awaiting the human's approval: packages/ui/src/components/Thing.tsx (component)",
  ])
  applyInstall(dir, planInstall(dir, pack(), 'date-entry', APP))
  const under = await compliance(dir, {
    tokens: async () => ({ ...clean, problems: ['packages/ui/src/components/DateField.tsx:4  gap-3  — off the scale', 'packages/ui/src/components/ui/card.tsx:16  rounded-xl  — not a radius role'] }),
    status: () => ({ ...settled, pending: ['packages/ui/src/components/DateField.tsx (component)'] }),
  })
  assert.deepEqual(under.problems, ['token check: packages/ui/src/components/ui/card.tsx:16  rounded-xl  — not a radius role'])
  assert.match((await compliance(dir, { tokens: async () => ({ problems: [], counts: null }), status: () => settled })).problems[0], /scanned nothing/)
  // With nothing handed in, it runs the project's own two checks.
  assert.ok(Array.isArray((await compliance(project())).problems))
})

test('a role the pack carries that the project has at another value is named by what differs, with the reason', () => {
  const why = 'a date field is dense'
  const css = { 'packages/ui/src/tokens.css': ':root {\n  /* a panel */\n  --surface: #fff;\n  /* a gap */\n  --gap-related: 0.75rem;\n  /* a step */\n  --step-14: 0.875rem;\n}\n', 'packages/ui/src/type.css': '@utility type-body {\n  font-size: 0.875rem;\n  font-weight: var(--font-weight-body);\n  line-height: 1.5rem;\n}\n' }
  const plan = { project: { css: Object.entries(css) }, roles: [
    { name: '--gap-related', present: true, value: '8px', why },
    { name: '--step-14', present: true, value: '14px', why },
    { name: 'type-body', present: true, value: 'font-size: var(--step-14); font-weight: var(--weight-body); line-height: 20px', why },
    { name: '--surface', present: true },
    { name: '--gap-section', present: false, value: '24px', why },
  ] }
  assert.deepEqual(carriedHere(plan), [
    { name: '--gap-related', pack: '8px', here: '12px', why },
    { name: 'type-body', pack: 'line-height 20px', here: 'line-height 24px', why },
  ], 'the same size written two ways is no difference, and a weight the pack does not carry is not compared')
  assert.deepEqual(carriedHere(planInstall(project(), pack(), 'date-entry', APP)), [])
})

test('a recipe or rule lands governing the apps the pieces are for, and never with no app named', () => {
  const dir = project()
  const unnamed = planInstall(dir, pack(), 'date-entry')
  assert.match(blockers(unnamed).join('\n'), /1 recipe\(s\) and behaviour rule\(s\) land, and no app is named: each governs every app of this project/)
  assert.match(planInstall(dir, pack(), 'date-entry', { apps: ['apps/nowhere'] }).problems.join('\n'), /`apps\/nowhere` is not a workspace of this project/)
  const named = planInstall(dir, pack(), 'date-entry', { apps: ['apps/shop/'] })
  assert.deepEqual([named.apps, blockers(named)], [['apps/shop'], []])
  applyInstall(dir, named)
  assert.match(fs.readFileSync(path.join(dir, '.claude/skills/ui-patterns/references/date-entry.md'), 'utf8'), /^apps: \[apps\/shop\]$/m)
})

test('the plan names the roles and libraries the project lacks', () => {
  const plan = planInstall(project(), pack(), 'date-entry', APP)
  assert.deepEqual(plan.roles.map((r) => [r.name, r.present]), [['--radius-control', false], ['--surface', true], ['type-body', true]])
  assert.deepEqual(plan.packages.map((l) => [l.name, l.version, l.installed]), [['datelib', '4.2.0', null]])
})

test("a file that would stand beside one of the project's own stops the install until a person answers", () => {
  const from = pack()
  const dir = project()
  const plan = planInstall(dir, from, 'form-shell', APP)
  assert.equal(plan.beside.length, 1)
  assert.deepEqual([plan.beside[0].existing, plan.beside[0].why, plan.beside[0].usedBy], ['packages/ui/src/components/EmptyState.tsx', 'the same file', ['apps/shop/src/routes/home.tsx', 'packages/ui/src/components/PageBanner.tsx']])
  assert.match(blockers(plan)[0], /empty-state\/packages\/ui\/src\/components\/empty-state\.tsx would stand beside this project's packages\/ui\/src\/components\/EmptyState\.tsx \(the same file\), imported by 2 file\(s\) — answer `use-existing` or `replace` for/)
  assert.deepEqual(applyInstall(dir, plan).written, [])
  assert.ok(!fs.existsSync(path.join(dir, 'packages/web/src/components/FormShell.tsx')))
  const both = planInstall(dir, from, 'form-shell', { ...APP, map: { beside: { 'packages/ui/src/components/empty-state.tsx': 'keep-both' } } })
  assert.doesNotMatch(blockers(plan)[0], /keep-both/)
  assert.match(blockers(both)[0], /both cannot be kept at packages\/ui\/src\/components\/EmptyState\.tsx/)
})

test('a helper that would overwrite a file of the project\'s own stops the install too', () => {
  const dir = project({ 'packages/ui/src/lib/format.ts': 'export const asDay = () => "mine"\n' })
  const plan = planInstall(dir, pack(), 'date-entry', APP)
  assert.deepEqual(plan.beside.map((b) => [b.existing, b.why]), [['packages/ui/src/lib/format.ts', 'the same file']])
  assert.equal(blockers(plan).length, 1)
  const kept = planInstall(dir, pack(), 'date-entry', { ...APP, map: { beside: { 'packages/ui/src/lib/format.ts': 'use-existing' } } })
  applyInstall(dir, kept)
  assert.equal(fs.readFileSync(path.join(dir, 'packages/ui/src/lib/format.ts'), 'utf8'), '// ui-pack-for: date-entry/packages/ui/src/lib/format.ts\nexport const asDay = () => "mine"\n', 'kept, and marked as taking the pack file\'s place')
})

test("answered use-existing, the project's own file is kept and the piece's imports go to it", () => {
  const dir = project()
  const plan = planInstall(dir, pack(), 'form-shell', { ...APP, map: { beside: { 'packages/ui/src/components/empty-state.tsx': 'use-existing' } } })
  const { written, problems } = applyInstall(dir, plan)
  assert.deepEqual(problems, [])
  assert.deepEqual(written, ['packages/web/src/components/FormShell.tsx', 'packages/ui/src/components/EmptyState.tsx', '.claude/rules/project/ui-inventory.md'])
  assert.match(fs.readFileSync(path.join(dir, 'packages/web/src/components/FormShell.tsx'), 'utf8'), /from "@north\/ui\/components\/EmptyState"/)
  // The project's file is kept as it was, but for the line saying whose place it takes.
  const kept = fs.readFileSync(path.join(dir, 'packages/ui/src/components/EmptyState.tsx'), 'utf8')
  assert.equal(kept.replace('// ui-pack-for: empty-state/packages/ui/src/components/empty-state.tsx\n', ''), PROJECT['packages/ui/src/components/EmptyState.tsx'])
  assert.match(kept, /^\/\/ ui-status: approved\n\/\/ ui-pack-for: empty-state\/packages\/ui\/src\/components\/empty-state\.tsx\n/)
})

test('use-existing means the file of the same place and name, never another block that merely shares its type', () => {
  // A second block of the type, sorting after the one the piece would stand beside.
  const dir = project({ 'packages/ui/src/components/ZeroPanel.tsx': '// ui-status: approved\n// ui-block: EmptyState\nexport function ZeroPanel() {\n  return null\n}\n' })
  const plan = planInstall(dir, pack(), 'form-shell', { ...APP, map: { beside: { 'packages/ui/src/components/empty-state.tsx': 'use-existing' } } })
  assert.deepEqual(plan.beside.map((b) => b.existing).sort(), ['packages/ui/src/components/EmptyState.tsx', 'packages/ui/src/components/ZeroPanel.tsx'])
  applyInstall(dir, plan)
  assert.match(fs.readFileSync(path.join(dir, 'packages/web/src/components/FormShell.tsx'), 'utf8'), /from "@north\/ui\/components\/EmptyState"/)
  assert.ok(!/ui-behaviour/.test(fs.readFileSync(path.join(dir, 'packages/ui/src/components/ZeroPanel.tsx'), 'utf8')))
})

test('a code file lands pending and a rule approved, each pointing at its pack file and version, imports rewritten and code otherwise as it was', () => {
  const from = pack()
  const dir = project()
  const plan = planInstall(dir, from, 'date-entry', APP)
  const { problems } = applyInstall(dir, plan)
  assert.deepEqual(problems, [])
  const version = git(from, 'describe', '--always')
  const field = fs.readFileSync(path.join(dir, 'packages/ui/src/components/DateField.tsx'), 'utf8')
  assert.equal(field, `// ui-status: pending\n// ui-pack: date-entry/packages/ui/src/components/date-field.tsx @ ${version}\n// ui-atom\n// ui-behaviour: date-entry.md\n"use client"\nimport { Calendar } from "./ui/calendar"\nimport { cn } from "../lib/cn"\nimport { asDay } from "../lib/format"\nexport function DateField({ value }: { value: Date }) {\n  return <div className={cn("bg-surface type-body")}>{asDay(value)}<Calendar /></div>\n}\n`)
  assert.match(fs.readFileSync(path.join(dir, 'packages/ui/src/lib/format.ts'), 'utf8'), new RegExp(`^// ui-pack: date-entry/packages/ui/src/lib/format\\.ts @ ${version}\\nimport`))
  const ref = fs.readFileSync(path.join(dir, '.claude/skills/ui-patterns/references/date-entry.md'), 'utf8')
  assert.match(ref, /^code: \[packages\/ui\/src\/components\/DateField\.tsx, packages\/ui\/src\/components\/ui\/calendar\.tsx\]$/m)
  assert.match(ref, /^ui-status: approved$/m)
  assert.match(ref, new RegExp(`^pack: date-entry/references/date-entry\\.md @ ${version}$`, 'm'))
})

test("a piece's inventory lines land in the region their rows belong to: a component's pending, a rule's approved", () => {
  const dir = project()
  applyInstall(dir, planInstall(dir, pack(), 'date-entry', APP))
  const inv = fs.readFileSync(path.join(dir, '.claude/rules/project/ui-inventory.md'), 'utf8')
  assert.match(inv, /<!-- project:begin behaviour-rules -->\n\n\| File \| Governs \| Status \|\n\|---\|---\|---\|\n\| `date-entry\.md` \| Every date \| approved \|\n<!-- project:end behaviour-rules -->/)
  assert.match(inv, /\| `DateField` \| Every date \| pending \|\n\| `calendar` \| The month grid \| pending \|\n<!-- project:end components -->/)
  assert.match(inv, /\| `EmptyState` \| Nothing to show \| EmptyState \| approved \|/)
  assert.equal(landedInventory('', '| File | Page type | Frame | Status |\n|---|---|---|---|\n| `list.md` | BrowseScreen | `list` | deferred `0a1b2c3d` |\n', () => 'recipe'), '\n\n| File | Page type | Frame | Status |\n|---|---|---|---|\n| `list.md` | BrowseScreen | `list` | approved |\n')
})

test('an inventory line is written only for a file that landed, by a name that is its alone, with the reason it was kept beside another', () => {
  const from = pack()
  const used = project()
  applyInstall(used, planInstall(used, from, 'form-shell', { ...APP, map: { beside: { 'packages/ui/src/components/empty-state.tsx': 'use-existing' } } }))
  const inv = fs.readFileSync(path.join(used, '.claude/rules/project/ui-inventory.md'), 'utf8')
  assert.match(inv, /\| `FormShell` \| The frame of a record screen \| RecordScreen \| pending \|/)
  assert.doesNotMatch(inv, /empty-state|What a list says/)
  // The project's own block of the same name sits in another folder: both lines gain their paths.
  const both = project({ 'packages/ui/src/components/EmptyState.tsx': null, 'packages/ui/src/components/portal/EmptyState.tsx': PROJECT['packages/ui/src/components/EmptyState.tsx'], 'packages/ui/src/components/PageBanner.tsx': PROJECT['packages/ui/src/components/PageBanner.tsx'].replace('./EmptyState', './portal/EmptyState'), 'apps/shop/src/routes/home.tsx': '// ui-content\nexport const Home = 1\n' })
  const plan = planInstall(both, from, 'empty-state', { ...APP, map: { beside: { 'packages/ui/src/components/empty-state.tsx': 'keep-both: the portal draws its own' } } })
  assert.deepEqual(blockers(plan), [])
  applyInstall(both, plan)
  const two = fs.readFileSync(path.join(both, '.claude/rules/project/ui-inventory.md'), 'utf8')
  assert.match(two, /\| `packages\/ui\/src\/components\/portal\/EmptyState` \| Nothing to show \| EmptyState \| approved \|/)
  assert.match(two, /\| `packages\/ui\/src\/components\/EmptyState` \| What a list says when it has nothing Kept beside `EmptyState`: the portal draws its own\. \| EmptyState \| pending \|/)
})

test("a file of the project's own that the pieces use as a rule's code is pointed back at the rule", () => {
  const dir = project({ 'packages/ui/src/components/DateField.tsx': '// ui-status: approved\n// ui-atom\nexport function DateField() {\n  return null\n}\n' })
  applyInstall(dir, planInstall(dir, pack(), 'date-entry', { ...APP, map: { beside: { 'packages/ui/src/components/date-field.tsx': 'use-existing' } } }))
  assert.match(fs.readFileSync(path.join(dir, 'packages/ui/src/components/DateField.tsx'), 'utf8'), /^\/\/ ui-status: approved\n\/\/ ui-pack-for: date-entry\/packages\/ui\/src\/components\/date-field\.tsx\n\/\/ ui-behaviour: date-entry\.md\n\/\/ ui-atom\n/)
  assert.match(fs.readFileSync(path.join(dir, '.claude/skills/ui-patterns/references/date-entry.md'), 'utf8'), /^code: \[packages\/ui\/src\/components\/DateField\.tsx, packages\/ui\/src\/components\/ui\/calendar\.tsx\]$/m)
})

test('the plan says what each stand-in must take, and where a lacking role is still used once the files have landed', () => {
  const from = pack({ 'pieces/date-entry/piece.json': { ...PACK['pieces/date-entry/piece.json'], atoms: [{ name: 'button', file: 'packages/ui/src/components/ui/button.tsx', exports: ['Button'], uses: { Button: { variant: ['quiet'], size: ['ghost'] } } }, PACK['pieces/date-entry/piece.json'].atoms[1]], roles: [{ name: '--radius-control', purpose: "a control's corner", classes: ['rounded-control'] }, { name: '--surface', purpose: 'a panel', classes: ['bg-surface'] }] }, 'pieces/date-entry/packages/ui/src/components/date-field.tsx': PACK['pieces/date-entry/packages/ui/src/components/date-field.tsx'].replace('bg-surface type-body', 'bg-surface rounded-control') })
  const dir = project({ 'packages/ui/src/components/ui/button.tsx': '// ui-status: approved\n// ui-atom\nexport function Button({ variant }: { variant?: "ghost" }) {\n  return variant ?? null\n}\n' })
  const before = planInstall(dir, from, 'date-entry', APP)
  assert.deepEqual(before.expected.find((e) => e.name === 'button').unseen, ['Button variant quiet'])
  assert.deepEqual(before.roles.map((r) => [r.name, r.present, r.still]), [['--radius-control', false, []], ['--surface', true, []]])
  applyInstall(dir, before)
  // Still to fit: a class this project's build makes no rule of. One it defines for itself is fitted.
  const after = planInstall(dir, from, 'date-entry', APP)
  assert.deepEqual(roleWork(after, () => false).roles[0].still, ['packages/ui/src/components/DateField.tsx'])
  assert.deepEqual(roleWork(after, (_file, cls) => cls === 'rounded-control').roles[0].still, [])
  assert.deepEqual(after.expected.find((e) => e.name === 'button').unseen, [], 'once the piece is installed the typecheck is the list')
})

test("a recipe lands approved and names no reference screen: the pack's reference page is not one", () => {
  const from = pack({
    'pieces/list/piece.json': { files: ['references/list.md', 'packages/web/src/reference/list-reference.tsx'], pieces: [], atoms: [], roles: [], packages: {}, workspaces: WORKSPACES, imports: {} },
    'pieces/list/inventory.md': '| File | Page type | Frame | Status |\n|---|---|---|---|\n| `list.md` | BrowseScreen | `TopBar` | approved |\n',
    'pieces/list/references/list.md': '---\nkind: recipe\nframe: TopBar\nreference: packages/web/src/reference/list-reference.tsx\nblock-types: [BrowseScreen]\nui-status: approved\n---\n# List\n',
    'pieces/list/packages/web/src/reference/list-reference.tsx': '// ui-recipe: list.md\nexport function ListReference() {\n  return null\n}\n',
  })
  const dir = project()
  applyInstall(dir, planInstall(dir, from, 'list', APP))
  const landed = fs.readFileSync(path.join(dir, '.claude/skills/ui-patterns/references/list.md'), 'utf8')
  assert.ok(!/^reference:/m.test(landed))
  assert.match(landed, /^ui-status: approved$/m)
  assert.ok(fs.existsSync(path.join(dir, 'packages/web/src/reference/list-reference.tsx')))
})

test('a second install finds what the first one landed, leaves it as it has been fitted since, and nothing of it stands beside itself', () => {
  const from = pack()
  const dir = project()
  applyInstall(dir, planInstall(dir, from, 'date-entry', APP))
  const fitted = path.join(dir, 'packages/ui/src/lib/format.ts')
  fs.writeFileSync(fitted, `${fs.readFileSync(fitted, 'utf8')}// fitted here\n`)
  const inventory = fs.readFileSync(path.join(dir, '.claude/rules/project/ui-inventory.md'), 'utf8')
  const again = planInstall(dir, from, 'date-entry', APP)
  assert.ok(again.files.every((f) => f.installed))
  // Its folder's naming may have changed since: the file is still found where it landed.
  fs.renameSync(path.join(dir, 'packages/ui/src/components/DateField.tsx'), path.join(dir, 'packages/ui/src/components/date-entry-field.tsx'))
  assert.ok(planInstall(dir, from, 'date-entry', APP).files.every((f) => f.installed))
  fs.renameSync(path.join(dir, 'packages/ui/src/components/date-entry-field.tsx'), path.join(dir, 'packages/ui/src/components/DateField.tsx'))
  assert.deepEqual(applyInstall(dir, again).written, ['.claude/rules/project/ui-inventory.md'])
  assert.match(fs.readFileSync(fitted, 'utf8'), /fitted here/)
  assert.equal(fs.readFileSync(path.join(dir, '.claude/rules/project/ui-inventory.md'), 'utf8'), inventory)
  assert.deepEqual(again.beside, [])
  assert.deepEqual(blockers(again), [])
  assert.deepEqual(installedFiles(dir).map((i) => i.file).sort(), ['.claude/skills/ui-patterns/references/date-entry.md', 'packages/ui/src/components/DateField.tsx', 'packages/ui/src/components/ui/calendar.tsx', 'packages/ui/src/lib/format.ts'])
})

test('compare shows what the pack has changed in a file since the version it was installed at, and says when it cannot', () => {
  const from = pack()
  const dir = project()
  applyInstall(dir, planInstall(dir, from, 'date-entry', APP))
  assert.ok(compare(dir, from).files.every((f) => f.diff === ''))
  const file = path.join(from, 'pieces/date-entry/packages/ui/src/lib/format.ts')
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('format(d)', 'format(d).trim()'))
  git(from, 'commit', '-q', '-am', 'trim the day')
  const changed = compare(dir, from).files.filter((f) => f.diff)
  assert.deepEqual(changed.map((f) => f.file), ['packages/ui/src/lib/format.ts'])
  assert.match(changed[0].diff, /\+export const asDay = \(d: Date\) => format\(d\)\.trim\(\)/)
  assert.deepEqual(compare(dir, from, 'packages/ui/src/components/DateField.tsx').files.map((f) => f.diff), [''])
  fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('.trim()', '.trim().toLowerCase()'))
  assert.match(compare(dir, from, 'packages/ui/src/lib/format.ts').files[0].diff, /toLowerCase/, 'a change the checkout has not committed shows too')
  const lost = path.join(dir, 'packages/ui/src/lib/format.ts')
  fs.writeFileSync(lost, fs.readFileSync(lost, 'utf8').replace(/@ \S+/, '@ 0000000'))
  assert.match(compare(dir, from, 'packages/ui/src/lib/format.ts').problems[0], /points at date-entry\/packages\/ui\/src\/lib\/format\.ts @ 0000000, which the pack's history does not hold/)
  const bare = pack()
  const other = project()
  applyInstall(other, planInstall(other, bare, 'date-entry', APP))
  git(bare, 'rm', '-q', '-r', '--cached', 'pieces')
  git(bare, 'commit', '-q', '-m', 'nothing held')
  const head = git(bare, 'rev-parse', '--short', 'HEAD').trim()
  const pointed = path.join(other, 'packages/ui/src/lib/format.ts')
  fs.writeFileSync(pointed, fs.readFileSync(pointed, 'utf8').replace(/@ \S+/, `@ ${head}`))
  assert.match(compare(other, bare, 'packages/ui/src/lib/format.ts').problems[0], /does not hold date-entry\/packages\/ui\/src\/lib\/format\.ts — the packs checkout had not committed it/)
})

test("approve, on the human's word: every installed file still pending and its inventory line become approved, and the judge's items resting on those files are cleared", () => {
  const from = pack()
  const dir = project()
  applyInstall(dir, planInstall(dir, from, 'date-entry', APP))
  const field = 'packages/ui/src/components/DateField.tsx'
  const own = 'packages/ui/src/components/EmptyState.tsx'
  fs.writeFileSync(path.join(dir, '.claude/ui-pending.json'), JSON.stringify([
    { question: 'NAMED-FOR-DATA', at: field },
    { question: 'TOKEN-AGAINST-PURPOSE', at: `${field}:4` },
    { question: 'ROLE-NAME', at: 'packages/ui/src/type.css:2' },
    { question: 'NAMED-FOR-DATA', at: own },
    { question: 'ROLE-NAME', at: 'packages/ui/src/tokens.css:3' },
  ]))
  const done = approveInstalled(dir)
  assert.deepEqual(done.problems, [])
  assert.ok(done.files.includes(field))
  assert.match(fs.readFileSync(path.join(dir, field), 'utf8'), /^\/\/ ui-status: approved\n\/\/ ui-pack: /)
  const inv = fs.readFileSync(path.join(dir, '.claude/rules/project/ui-inventory.md'), 'utf8')
  assert.match(inv, /\| `DateField` \| Every date \| approved \|/)
  assert.ok(!/\| pending \|/.test(inv))
  const left = JSON.parse(fs.readFileSync(path.join(dir, '.claude/ui-pending.json'), 'utf8'))
  assert.deepEqual(left.map((i) => i.at), ['packages/ui/src/type.css:2', own, 'packages/ui/src/tokens.css:3'], "the project's own items stay, and so does every item about a role")
  assert.deepEqual([done.cleared, done.kept], [2, 3])
  // A file of the project's own standing in for a pack file is approved with them.
  const stood = project({ 'packages/ui/src/components/EmptyState.tsx': '// ui-status: pending\n// ui-pack-for: empty-state/packages/ui/src/components/empty-state.tsx\n// ui-block: EmptyState\nexport function EmptyState() {\n  return null\n}\n' })
  assert.deepEqual(approveInstalled(stood).files, ['packages/ui/src/components/EmptyState.tsx'])
  // Nothing more to do a second time, and a project with nothing installed says so.
  assert.deepEqual(approveInstalled(dir).files, [])
  assert.match(approveInstalled(project()).problems[0], /nothing installed to approve/)
})

test('a project with no UI package is not one a piece is installed into', () => {
  const dir = project({ '.claude/sync-substitutions.json': { ...KEYS, DESIGN_UI_PACKAGE: '', _intentionally_empty: ['DESIGN_UI_PACKAGE'] } })
  assert.match(planInstall(dir, pack(), 'date-entry', APP).problems[0], /a piece is installed into a UI package/)
})
