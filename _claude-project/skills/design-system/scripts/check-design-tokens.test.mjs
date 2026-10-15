import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkDesignTokens, NOT_SET_UP, parityProblems, purposesOf } from './check-design-tokens.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ENGINE = path.resolve(HERE, '../../claude-design/scripts')

const KEYS = {
  DESIGN_UI_PACKAGE: 'packages/ui',
  DESIGN_FEED_BARREL: 'src/index.ts',
  DESIGN_TOKEN_FILES: 'src/tokens.css',
  DESIGN_TYPE_FILE: 'src/type.css',
  DESIGN_STYLES_FILE: 'src/styles.css',
  DESIGN_VENDORED_DIR: 'packages/ui/src/components/ui',
  DESIGN_VENDORED_RESTYLED: 'true',
  DESIGN_FIELD_LOOK_CLASSES: 'border-input bg-field type-form-control',
  DESIGN_EXEMPT_COMPONENTS: 'PopoverTrigger Spinner',
}

const TOKENS = `:root {
  /* ─── ramp ─── */
  /* the brand blue */
  --blue: oklch(0.5 0.1 250);
  /* the page */
  --background: oklch(0.98 0 0);
  /* body text */
  --foreground: oklch(0.2 0 0);
  /* a solid action */
  --primary: var(--blue);
  /* a field's border */
  --input: oklch(0.8 0 0);
  /* a field's fill */
  --field: oklch(1 0 0);
  /* a control's corner */
  --radius-control: 6px;
  /* a panel's corner */
  --radius-panel: 8px;
  /* the one lift */
  --shadow-overlay: 0 4px 12px oklch(0 0 0 / 0.2);
  /* publish: off — consumed by the type roles and spacing aliases */
  /* a field's height */
  --size-control: 32px;
  /* body size */
  --step-body: 14px;
  /* body weight */
  --weight-body: 400;
  /* strong weight */
  --weight-strong: 600;
  /* prose leading */
  --leading-prose: 1.6;
  /* publish: on */
}

.dark {
  --blue: oklch(0.7 0.1 250);
  --background: oklch(0.15 0 0);
  --foreground: oklch(0.95 0 0);
  --input: oklch(0.3 0 0);
  --field: oklch(0.2 0 0);
}
`

const TYPE = `/* ─── body ─── */
/* running text */
@utility type-body {
  font-size: var(--step-body);
  line-height: 20px;
  font-weight: var(--weight-body);
}
/* the text a field shows */
@utility type-form-control {
  font-size: var(--step-body);
  line-height: 20px;
  font-weight: var(--weight-body);
}
`

const STYLES = `@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-primary: var(--primary);
  --color-input: var(--input);
  --color-field: var(--field);
  --radius-control: var(--radius-control);
  --radius-panel: var(--radius-panel);
  --shadow-overlay: var(--shadow-overlay);
  --spacing-control: var(--size-control);
  --font-weight-body: var(--weight-body);
  --font-weight-strong: var(--weight-strong);
  --font-sans: system-ui;
  --leading-prose: var(--leading-prose);
}
@utility scroll-region {
  overflow-y: auto;
}
`

const DESIGN = `---
name: Fixture
colors:
  primary: "#3355aa"
typography:
  body:
    fontSize: 14px
  formControl:
    fontSize: 14px
rounded:
  control: 6px
  panel: 8px
---

# Fixture

## Overview

Rows use \`type-body\` on \`rounded-panel\` cards, \`{colors.primary}\` for actions, a 32px control, a 14px body.
`

const BUTTON = `export function Button({ className, ...props }: { className?: string }) {
  return <button className={cn("rounded-control bg-primary text-foreground type-body px-3 h-control shadow-overlay", className)} {...props} />
}
`

const PAGE = `export function Page({ children }: { children?: unknown }) {
  return <main className="scroll-region bg-background text-foreground">{children}</main>
}
export function Lead({ children }: { children?: unknown }) {
  return <p className="type-body font-strong leading-prose font-sans">{children}</p>
}
`

const SCREEN = `import { Button } from "@acme/ui/components/button"
import { Spinner } from "@acme/ui/components/spinner"
import { Lead, Page } from "@acme/ui/components/page"
export function Screen() {
  return (
    <Page>
      <div className="flex flex-col gap-2 mt-4 w-full">
        <Button className="mt-2 w-full">Save</Button>
        <Spinner className="size-4 text-primary" />
        <Lead>x</Lead>
      </div>
    </Page>
  )
}
`

/** A repository on disk: the files given, over a clean baseline. */
function fixture(files = {}, { keys = KEYS } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'design-tokens-'))
  const all = {
    '.claude/sync-substitutions.json': JSON.stringify(keys, null, 2),
    'design.md': DESIGN,
    'package.json': '{ "workspaces": ["apps/*", "packages/*"] }\n',
    'packages/ui/package.json': '{ "name": "@acme/ui" }\n',
    'apps/web/package.json': '{ "name": "web", "dependencies": { "@acme/ui": "*" } }\n',
    'packages/ui/src/tokens.css': TOKENS,
    'packages/ui/src/type.css': TYPE,
    'packages/ui/src/styles.css': STYLES,
    'packages/ui/src/components/button.tsx': BUTTON,
    'apps/web/src/screen.tsx': SCREEN,
    'packages/ui/src/components/page.tsx': PAGE,
    'packages/ui/src/components/field.tsx': 'export const field = "rounded-panel border-input bg-field font-body font-strong font-sans bg-background leading-prose"\n',
    ...files,
  }
  for (const [rel, content] of Object.entries(all)) {
    if (content === null) continue
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), content)
  }
  return dir
}

const run = async (files, opts) => checkDesignTokens(fixture(files, opts))
const PIECE = 'apps/web/src/components/piece.tsx'
const screen = (body, imports = '') => ({ [PIECE]: `${imports}\nexport function S() {\n  return ${body}\n}\n` })

test('a clean project passes and says how much it inspected', async () => {
  const { problems, counts, notes } = await run()
  assert.deepEqual(problems, [])
  assert.equal(counts.sourceFiles, 4)
  assert.equal(counts.stylesheets, 3)
  assert.ok(counts.classesChecked > 10)
  assert.match(notes.join(' '), /no claude-design config/)
})

test('no source files fails instead of passing', async () => {
  const { problems } = await run({ 'apps/web/src/screen.tsx': null, 'packages/ui/src/components/page.tsx': null, 'packages/ui/src/components/button.tsx': null, 'packages/ui/src/components/field.tsx': null })
  assert.match(problems.at(-1), /scanned 0 source file\(s\).*nothing to check/)
})

test('a stylesheet named by two keys is read once', async () => {
  const { counts } = await run({}, { keys: { ...KEYS, DESIGN_TOKEN_FILES: 'src/tokens.css src/styles.css' } })
  assert.equal(counts.stylesheets, 3)
})

test('a missing design key fails by name', async () => {
  const keys = { ...KEYS }
  delete keys.DESIGN_TOKEN_FILES
  const { problems } = await run({}, { keys })
  assert.deepEqual(problems, ['DESIGN_TOKEN_FILES: not set in .claude/sync-substitutions.json'])
})

test('every app depending on the UI package is checked without being listed; one that does not is not read', async () => {
  const { problems } = await run({
    'apps/admin/package.json': '{ "name": "admin", "devDependencies": { "@acme/ui": "*" } }\n',
    'apps/admin/src/screen.tsx': 'export const S = () => <p className="text-sm" />\n',
    'apps/worker/package.json': '{ "name": "worker" }\n',
    'apps/worker/src/mail.tsx': 'export const M = () => <p className="text-sm" />\n',
  })
  assert.ok(problems.some((p) => p.startsWith('apps/admin/src/screen.tsx:1  text-sm')), problems.join('\n'))
  assert.ok(!problems.some((p) => p.startsWith('apps/worker/')), problems.join('\n'))
})

test('a UI package its dependants cannot be found by fails by name', async () => {
  const { problems } = await run({ 'packages/ui/package.json': '{}\n' })
  assert.ok(problems.some((p) => /packages\/ui\/package\.json {2}— has no "name"/.test(p)), problems.join('\n'))
})

for (const [name, cls, why] of [
  ['arbitrary text size', 'text-[13px]', /no arbitrary text/],
  ['raw text size', 'text-sm', /not a type role/],
  ['palette colour', 'text-blue-500', /not a theme colour/],
  ['unknown type role', 'type-caption', /no such type role/],
  ['raw leading', 'leading-none', /line height and tracking/],
  ['arbitrary radius', 'rounded-[6px]', /no arbitrary rounded/],
  ['unknown radius', 'rounded-lg', /not a radius role/],
  ['bare radius', 'rounded', /not a radius role/],
  ['raw weight', 'font-semibold', /not a weight role/],
  ['unknown shadow', 'shadow-lg', /not a shadow role/],
  ['unknown text shadow', 'text-shadow-lg', /not a text-shadow role/],
  ['dark variant', 'dark:bg-background', /no `dark:`/],
  ['bare scroll', 'overflow-y-auto', /`scroll-region`/],
  ['arbitrary border width', 'border-[3px]', /no arbitrary line width/],
  ['arbitrary spacing', 'gap-[6px]', /no arbitrary spacing/],
  ['half step', 'p-1.5', /off the 4px grid/],
]) {
  test(`${name} fails: ${cls}`, async () => {
    const { problems } = await run(screen(`<div className="${cls}" />`))
    assert.ok(problems.length >= 1, `no problem for ${cls}`)
    assert.match(problems.join('\n'), why)
  })
}

test('roles the CSS defines pass: a leading token, a radius corner, a colour with opacity', async () => {
  const { problems } = await run(screen('<div className="leading-prose p-1 rounded-t-panel text-foreground/60 rounded-none" />'))
  assert.deepEqual(problems, [])
})

test('spacing between the steps of the scale fails: the kit default has no 20px, no 40px and no 2px', async () => {
  const { problems, notes } = await run(screen('<div className="p-5 gap-10 mt-0.5 px-6 gap-2" />'))
  assert.deepEqual(problems.map((p) => p.split('  ')[1]).sort(), ['gap-10', 'mt-0.5', 'p-5'])
  assert.match(problems.join('\n'), /not a step of the spacing scale \(0, 4, 8, 12, 16, 24, 32, 48px\)/)
  assert.ok(notes.some((n) => /spacing scale: .* from the kit's default/.test(n)))
})

test("a project's own spacing steps replace the kit's", async () => {
  const dir = await withConfig({ 'packages/ui/design-system/design-system.config.mjs': CONFIG.replace('steps: [0, 1, 2, 3, 4, 6, 8, 12]', 'steps: [0, 1, 2, 3, 4, 5, 6, 8, 12]'), ...screen('<div className="p-5 gap-10" />') })
  const { problems, notes } = await checkDesignTokens(dir)
  assert.deepEqual(problems.filter((p) => /spacing scale/.test(p)).map((p) => p.split('  ')[1]), ['gap-10'])
  assert.ok(notes.some((n) => /from packages\/ui\/design-system\/design-system\.config\.mjs/.test(n)))
})

test('spacing between the steps on an untouched line is left alone; the changed line is judged', async () => {
  const dir = fixture({ 'apps/web/src/routes/orders.tsx': 'export const S = () => <>\n  <div className="p-5" />\n</>\n' })
  const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args])
  git('init', '-q')
  git('add', '-A')
  git('commit', '-qm', 'base')
  const base = String(git('rev-parse', 'HEAD')).trim()
  fs.writeFileSync(path.join(dir, 'apps/web/src/routes/orders.tsx'), 'export const S = () => <>\n  <div className="p-5" />\n  <p className="gap-5">new</p>\n</>\n')
  const { problems } = await checkDesignTokens(dir, { base })
  assert.deepEqual(problems.filter((p) => /spacing scale/.test(p)).map((p) => p.split('  ').slice(0, 2).join(' ')), ['apps/web/src/routes/orders.tsx:3 gap-5'])
})

test('a text shadow is never read as a type size', async () => {
  const { problems } = await run(screen('<div className="text-shadow-lg text-shadow-none" />'))
  assert.equal(problems.length, 1)
  assert.doesNotMatch(problems[0], /type role/)
})

test('a comment line describing a rule is not a violation', async () => {
  const { problems } = await run(screen('<div />\n  // never text-sm here'))
  assert.deepEqual(problems, [])
})

test('an SVG attribute in a string is not a class', async () => {
  const { problems } = await run({ 'apps/web/src/icon.ts': 'export const svg = `<text x="16" text-anchor="middle">A</text>`\n' })
  assert.deepEqual(problems, [])
})

test('a call site may set a width or bound a height, never fix a height or size; an exempt component may', async () => {
  const imports = 'import { Button } from "@acme/ui/components/button"\nimport { PopoverTrigger } from "@acme/ui/components/popover"'
  const { problems } = await run(screen('<><Button className="h-8 w-8" /><Button className="w-full h-full max-h-60 p-2" /><Button className="size-6" /><PopoverTrigger className="h-8" /></>', imports))
  assert.deepEqual(problems.map((p) => p.split('  ')[1]), ['<Button> h-8', '<Button> size-6'])
  assert.match(problems[0], /a call site never fixes how tall a component is/)
})

test('a call site repainting a component with a colour role fails; an exempt component and a non-colour class pass', async () => {
  const imports = 'import { Button } from "@acme/ui/components/button"\nimport { PopoverTrigger } from "@acme/ui/components/popover"'
  const { problems } = await run(screen('<><Button className="mt-2 text-primary" /><Button className="hover:bg-background/80" /><Button className="text-wrap" /><PopoverTrigger className="text-primary" /></>', imports))
  assert.deepEqual(problems.map((p) => p.split('  ')[1]), ['<Button> text-primary', '<Button> hover:bg-background/80'])
  assert.match(problems[0], /never repaints a component's colour/)
})

test('a single-quoted className at a call site is read like a double-quoted one', async () => {
  const imports = 'import { Button } from "@acme/ui/components/button"'
  const { problems } = await run(screen(`<Button className='h-8 mt-1' />`, imports))
  assert.equal(problems.length, 1)
  assert.match(problems[0], /<Button> h-8 {2}— a call site never fixes/)
})

test('a call site picking a size by magnitude fails; a role-named size passes', async () => {
  const imports = 'import { Button } from "@acme/ui/components/button"'
  const { problems } = await run(screen('<><Button size="sm" /><Button size={"icon-lg"} /><Button size="toolbar" /><Button size={size} /></>', imports))
  assert.equal(problems.length, 2)
  assert.match(problems[0], /<Button> size="sm" {2}— a size named by magnitude/)
  assert.match(problems[1], /<Button> size="icon-lg" {2}— a size named by magnitude/)
})

test('a raw input painting the field look fails; a checkbox input does not', async () => {
  const { problems } = await run(screen('<><input className="border-input type-form-control" /><input type="checkbox" className="rounded-control" /></>'))
  assert.equal(problems.length, 2)
  assert.ok(problems.every((p) => /field atom/.test(p)))
})

test('vendored atoms: every class rule when restyled; only arbitrary spacing when not', async () => {
  const atom = { 'packages/ui/src/components/ui/badge.tsx': 'export const b = cn("text-sm gap-[3px]")\n' }
  const restyled = await run(atom)
  assert.equal(restyled.problems.length, 2)
  const asShipped = await run(atom, { keys: { ...KEYS, DESIGN_VENDORED_RESTYLED: '' } })
  assert.equal(asShipped.problems.length, 1)
  assert.match(asShipped.problems[0], /gap-\[3px\].*no arbitrary spacing/)
})

test('only class lists are read: imports, URLs, logger names and prop values are not classes', async () => {
  const src = [
    'import { Help } from "./tracking-help-dialog"',
    'const log = createLogger("tracking-service")',
    'const url = "https://example.com/tracking-parcel.html?tracking-id=1"',
    'export const S = () => <Button size="text-meta" className="text-sm" />',
  ].join('\n')
  const { problems } = await run({ [PIECE]: src })
  assert.deepEqual(problems.map((p) => p.split('  ')[1]), ['text-sm'])
})

test('source is read as the compiler reads it: what is not a class list is never checked as one', async () => {
  const src = [
    'import { Help } from "./text-sm-rounded-lg"',
    'const log = logger.child({ name: "text-red" })',
    'const url = "https://example.com/rounded-lg/text-sm.html"',
    'const svg = <svg><text textAnchor="middle" fontSize="text-sm">A</text></svg>',
    'export const S = ({ x }) => <Chart label="text-sm rounded-lg" className={cn(/* text-sm */ x === "rounded-lg" ? "type-body" : "")} />',
  ].join('\n')
  const { problems } = await run({ [PIECE]: src })
  assert.deepEqual(problems, [])
})

test('a class constant is checked where it is declared, used here or in another file', async () => {
  const { problems } = await run({
    'apps/web/src/styles.ts': 'export const cell = "px-[10px]"\nexport const notClasses = "text-only"\n',
    [PIECE]: 'import { cell } from "./styles"\nexport const S = () => <td className={cn(cell)} />\n',
  })
  assert.deepEqual(problems.map((p) => p.split('  ')[1]), ['px-[10px]'])
})

test('a function a class list calls is checked — directly, through a variable or a class prop — as a declaration, a block arrow or an expression arrow', async () => {
  const { problems } = await run({
    'apps/web/src/tone.ts': [
      'export function toneFor(late: boolean): string {',
      '  if (late) return "text-blue-500"',
      '  return ""',
      '}',
      'export const edge = (x: number) => {',
      '  return x > 1 ? "rounded-lg" : ""',
      '}',
      'export const pad = (n: number) => (n ? "px-[3px]" : "")',
      'export function unused() { return "text-sm" }',
    ].join('\n'),
    [PIECE]: 'import { toneFor, edge, pad } from "./tone"\nexport const S = () => {\n  const tone = toneFor(true)\n  return <Row toneClasses={tone} className={cn(edge(2), pad(1))} />\n}\n',
  })
  assert.deepEqual(problems.map((p) => p.split('  ')[1]).sort(), ['px-[3px]', 'rounded-lg', 'text-blue-500'])
})

test('a var() that resolves to nothing fails', async () => {
  const { problems } = await run({ 'packages/ui/src/styles.css': `${STYLES}\n.x { color: var(--nowhere); width: var(--measured, 100%); }\n` })
  assert.ok(!problems.some((p) => /--measured/.test(p)), 'a var() with a fallback is set at run time, not undefined')
  assert.ok(problems.some((p) => /--nowhere {2}— referenced but never defined/.test(p)))
})

const contrastOf = (problems) => problems.filter((p) => /contrast|names no token/.test(p))
const withTokens = (light, dark = '') => ({ 'packages/ui/src/tokens.css': TOKENS.replace(':root {', `:root {\n${light}`).replace('.dark {', `.dark {\n${dark}`) })

test('contrast: the foreground on background pair is measured in both themes and passes', async () => {
  const { problems, counts } = await run()
  assert.deepEqual(contrastOf(problems), [])
  assert.equal(counts.contrastPairs, 1)
  assert.equal(counts.themes, 2)
  assert.equal(counts.contrastMeasured, 2)
})

test('contrast: a -foreground pair that passes in light and fails in dark fails for dark only', async () => {
  const { problems } = await run(withTokens('  --muted: oklch(0.95 0 0);\n  --muted-foreground: oklch(0.45 0 0);', '  --muted: oklch(0.2 0 0);\n  --muted-foreground: oklch(0.3 0 0);'))
  const found = contrastOf(problems)
  assert.equal(found.length, 1, found.join('\n'))
  assert.match(found[0], /--muted-foreground on --muted \(dark\) {2}— contrast 1\.33:1, below 4\.5:1/)
})

test('contrast: an accepted failure passes at its ratio, and fails once it measures lower', async () => {
  const pair = (r) => withTokens(`  --muted: oklch(0.95 0 0);\n  --muted-foreground: oklch(0.6 0 0); /* contrast-accepted: ${r} — placeholder text only */`)
  assert.deepEqual(contrastOf((await run(pair('3.41'))).problems), [])
  const worse = contrastOf((await run(pair('4.0'))).problems)
  assert.equal(worse.length, 2)
  assert.match(worse[0], /contrast 3\.41:1, below its accepted 4\.00:1 — the colour got worse/)
})

test('contrast: a design.md component pair is measured, and a colour key with no token is reported', async () => {
  const design = DESIGN.replace('colors:\n', 'colors:\n  ink: "#999999"\n  paper: "#ffffff"\n  ghost: "#000000"\n').replace(
    'typography:',
    'components:\n  chip:\n    textColor: "{colors.ink}"\n    backgroundColor: "{colors.paper}"\n  badge:\n    textColor: "{colors.ghost}"\n    backgroundColor: "{colors.paper}"\ntypography:',
  )
  const { problems } = await run({ ...withTokens('  --ink: oklch(0.6 0 0);\n  --paper: oklch(0.95 0 0);'), 'design.md': design })
  const found = contrastOf(problems)
  assert.ok(found.some((p) => /--ink on --paper \(light\) {2}— contrast 3\.41:1/.test(p)), found.join('\n'))
  assert.ok(found.some((p) => /components\.badge\.textColor {2}— \{colors\.ghost\} names no token/.test(p)), found.join('\n'))
})

test('contrast: a camelCase design.md key matches its kebab-case token', async () => {
  const design = DESIGN.replace('colors:\n', 'colors:\n  textMuted: "#999999"\n  surfaceCard: "#ffffff"\n').replace(
    'typography:',
    'components:\n  chip:\n    textColor: "{colors.textMuted}"\n    backgroundColor: "{colors.surfaceCard}"\ntypography:',
  )
  const { problems } = await run({ ...withTokens('  --text-muted: oklch(0.6 0 0);\n  --surface-card: oklch(0.95 0 0);'), 'design.md': design })
  const found = contrastOf(problems)
  assert.ok(found.some((p) => /--text-muted on --surface-card \(light\) {2}— contrast 3\.41:1/.test(p)), found.join('\n'))
  assert.ok(!found.some((p) => /names no token/.test(p)), found.join('\n'))
})

test('contrast: a design.md key matches a --color-<key> token, as a Tailwind v4 theme names it', async () => {
  const design = DESIGN.replace('colors:\n', 'colors:\n  ink: "#999999"\n  paper: "#ffffff"\n').replace(
    'typography:',
    'components:\n  chip:\n    textColor: "{colors.ink}"\n    backgroundColor: "{colors.paper}"\ntypography:',
  )
  const { problems } = await run({ ...withTokens('  --color-ink: oklch(0.6 0 0);\n  --color-paper: oklch(0.95 0 0);'), 'design.md': design })
  const found = contrastOf(problems)
  assert.ok(found.some((p) => /--color-ink on --color-paper \(light\) {2}— contrast 3\.41:1/.test(p)), found.join('\n'))
  assert.ok(!found.some((p) => /names no token/.test(p)), found.join('\n'))
})

test('contrast: a disabled pair is exempt and listed, never measured', async () => {
  const { problems, notes } = await run(withTokens('  --disabled: oklch(0.95 0 0);\n  --disabled-foreground: oklch(0.8 0 0);'))
  assert.deepEqual(contrastOf(problems), [])
  assert.ok(notes.some((n) => /contrast: exempt --disabled-foreground on --disabled/.test(n)), notes.join('\n'))
})

test('contrast: no text pair to measure fails, naming both ways to declare one', async () => {
  const { problems } = await run({ 'packages/ui/src/tokens.css': TOKENS.replaceAll('--foreground', '--body-ink') })
  assert.ok(problems.some((p) => /contrast: no text pairs to measure — name them in design\.md components/.test(p)))
})

test('contrast: translucent colours are laid over what is under them, never skipped when that is opaque', async () => {
  const { problems, notes } = await run(withTokens('  --overlay: oklch(0.98 0 0 / 0.6);\n  --overlay-foreground: oklch(0.2 0 0 / 0.9);'))
  assert.deepEqual(contrastOf(problems), [])
  assert.ok(!notes.some((n) => /skipped --overlay/.test(n)), notes.join('\n'))
  const bare = await run({ 'packages/ui/src/tokens.css': TOKENS.replace('--background: oklch(0.98 0 0)', '--background: oklch(0.98 0 0 / 0.5)') })
  assert.ok(bare.notes.some((n) => /contrast: skipped --foreground on --background \(light\)/.test(n)), bare.notes.join('\n'))
})

test('a token nothing reaches fails, unless it is marked not-yet-built', async () => {
  const unused = await run({ 'packages/ui/src/tokens.css': TOKENS.replace(':root {', ':root {\n  /* a colour for later */\n  --later: #ff0000;') })
  assert.ok(unused.problems.some((p) => /--later {2}— defined but nothing reaches it/.test(p)))
  const marked = await run({ 'packages/ui/src/tokens.css': TOKENS.replace(':root {', ':root {\n  --later: #ff0000; /* not-yet-built: the dashboard */') })
  assert.deepEqual(marked.problems, [])
})

test('a breakpoint used only through its variant prefix or an @variant block is reached; one used nowhere still fails', async () => {
  const { problems } = await run({
    'packages/ui/src/tokens.css': `${TOKENS.replace(':root {', ':root {\n  --breakpoint-phone: 30rem;\n  --breakpoint-tablet: 48rem;\n  --breakpoint-wide: 80rem;\n  --breakpoint-later: 96rem;')}\n@utility sheet {\n  bottom: 0;\n  @variant phone {\n    bottom: auto;\n  }\n}\n`,
    'packages/ui/src/components/bar.tsx': 'export const bar = "grid tablet:grid-cols-2 max-wide:hidden"\n',
  })
  assert.ok(!problems.some((p) => /--breakpoint-(phone|tablet|wide)/.test(p)), problems.join('\n'))
  assert.ok(problems.some((p) => /--breakpoint-later {2}— defined but nothing reaches it/.test(p)))
})

test('a token named by Tailwind\'s variable shorthand is reached; one used nowhere still fails', async () => {
  const { problems } = await run({
    'packages/ui/src/tokens.css': TOKENS.replace(':root {', ':root {\n  --tall: 40px;\n  --hint: #00ff00;\n  --later: #ff0000;'),
    'packages/ui/src/components/bar.tsx': 'export const bar = "min-h-(--tall) hover:bg-(color:--hint)"\n',
  })
  assert.ok(!problems.some((p) => /--tall|--hint/.test(p)), problems.join('\n'))
  assert.ok(problems.some((p) => /--later {2}— defined but nothing reaches it/.test(p)))
})

test('a role named with a t-shirt size fails where it is defined, in every family; other names are the judge\'s', async () => {
  const { problems } = await run({
    'packages/ui/src/styles.css': STYLES.replace('@theme inline {', '@theme inline {\n  --radius-md: 4px;\n  --font-weight-semibold: 600;\n  --shadow-lg: 0 0 4px black;\n  --tracking-2xl: 0.1em;'),
    'packages/ui/src/type.css': `${TYPE}\n@utility type-sm {\n  font-size: 14px;\n}\n`,
  })
  const named = problems.filter((p) => /named by its size/.test(p))
  assert.equal(named.length, 4)
  assert.match(named.join('\n'), /packages\/ui\/src\/styles\.css:2 {2}--radius-md {2}— a radius role named by its size/)
  assert.match(named.join('\n'), /--shadow-lg {2}— a shadow role named by its size/)
  assert.match(named.join('\n'), /--tracking-2xl {2}— a tracking role named by its size/)
  assert.match(named.join('\n'), /type-sm {2}— a type role named by its size/)
  assert.doesNotMatch(named.join('\n'), /semibold/)
})

test('parity: a dark-only token and a ramp colour dark leaves light both fail', () => {
  const css = `:root {\n  /* page */\n  --background: #ffffff;\n  /* a */\n  --blue: #2244aa;\n  /* b */\n  --primary: var(--blue);\n  /* fixed */\n  --chart: #ff0000;\n}\n\n.dark {\n  --ghost: #000000;\n  --background: #111111;\n}\n`
  const { problems, applies } = parityProblems([['tokens.css', css]])
  assert.equal(applies, true)
  assert.equal(problems.length, 2)
  assert.match(problems.join('\n'), /--ghost {2}— declared only for the dark theme/)
  assert.match(problems.join('\n'), /--blue {2}— other tokens build on this colour/)
})

test('parity does not apply without a dark theme, and says so', async () => {
  const { problems, notes } = await run({ 'packages/ui/src/tokens.css': TOKENS.slice(0, TOKENS.indexOf('.dark')) })
  assert.deepEqual(problems, [])
  assert.match(notes.join(' '), /parity: no dark theme/)
})

test('a token file that does not parse fails, and is not reported as having no dark theme', async () => {
  const { problems, notes } = await run({ 'packages/ui/src/tokens.css': `${TOKENS}\n@theme inline {\n  --color-background: var(--background);\n}\n` })
  assert.ok(problems.some((p) => /unrecognised selector: @theme inline/.test(p)))
  assert.doesNotMatch(notes.join(' '), /no dark theme/)
})

test('design.md: a missing frontmatter key, a role without an entry, an unknown quoted class, an off-grid frontmatter pixel', async () => {
  const design = DESIGN.replace('  formControl:\n    fontSize: 14px\n', '').replace('  panel: 8px\n', '  panel: 8px\n  card: 15px\n').replace('a 14px body.', 'a 14px body, `rounded.huge`, {colors.secondary}, `type-caption`, and a 375px phone.')
  const { problems } = await run({ 'design.md': design })
  const text = problems.join('\n')
  assert.match(text, /type-form-control {2}— a type role with no typography entry/)
  assert.match(text, /rounded\.huge {2}— no such key in the frontmatter/)
  assert.match(text, /\{colors\.secondary\} {2}— no such key/)
  assert.match(text, /type-caption {2}— no such type role/)
  assert.match(text, /15px {2}— off the grid/)
  assert.doesNotMatch(text, /375px/, 'a pixel value in the prose is the judge\'s')
  assert.ok(problems.length >= 5)
})

test('design.md: a `---` inside a frontmatter comment does not end the frontmatter', async () => {
  const design = DESIGN.replace('---\n', '---\n# --- the ramp: raw values ---\n')
  const { problems } = await run({ 'design.md': design })
  assert.deepEqual(problems, [])
})

test("the project slot runs every check in the UI package's design-system/checks/", async () => {
  const check = `export default function (api) {
  if (!api.roles.radius.has('control')) throw new Error('roles not passed')
  for (const [file, src] of api.sources) if (src.includes('px-3')) api.add(file, 'px-3', 'the project pads controls with px-4')
}\n`
  const { problems, counts } = await run({ 'packages/ui/design-system/checks/control-padding.mjs': check })
  assert.equal(counts.projectChecks, 1)
  assert.deepEqual(problems, ['packages/ui/src/components/button.tsx  px-3  — the project pads controls with px-4'])
})

test('a project check that exports no function fails by name', async () => {
  const { problems } = await run({ 'packages/ui/design-system/checks/broken.mjs': 'export const x = 1\n' })
  assert.match(problems.join('\n'), /broken\.mjs {2}— a project check default-exports a function/)
})

// ─── generated files: need the engine's config, which needs a git repository ───

const CONFIG = `export default {
  title: 'Fixture',
  namespace: 'FX',
  artifact: '',
  timeZone: 'America/Chicago',
  spacing: { steps: [0, 1, 2, 3, 4, 6, 8, 12] },
  css: { build: 'true', file: 'dist/feed.css' },
  components: [{ name: 'Button', group: 'Actions', height: 80, doc: { source: 'components/button.tsx' }, render: "h(U.Button, null, 'Save')" }],
}
`

async function withConfig(extra = {}) {
  const dir = fixture({
    'packages/ui/design-system/design-system.config.mjs': CONFIG,
    ...extra,
  })
  execFileSync('git', ['init', '-q'], { cwd: dir })
  return dir
}

test('a theme colour no screen uses is reached once the generated safelist ships its class', async () => {
  const dir = await withConfig({
    'packages/ui/src/tokens.css': TOKENS.replace(':root {', ':root {\n  /* a status no screen shows yet */\n  --status-new: oklch(0.6 0.15 250);'),
    'packages/ui/src/styles.css': STYLES.replace('@theme inline {', '@theme inline {\n  --color-status-new: var(--status-new);'),
  })
  const before = await checkDesignTokens(dir)
  assert.ok(before.problems.some((p) => /--color-status-new {2}— defined but nothing reaches it/.test(p)))

  const { readConfig } = await import(path.join(ENGINE, 'config.mjs'))
  const { buildModel } = await import(path.join(ENGINE, 'model.mjs'))
  const { writeGenerated } = await import(path.join(ENGINE, 'generate.mjs'))
  const { ctx } = await readConfig(path.join(dir, 'packages/ui/design-system/design-system.config.mjs'))
  writeGenerated(ctx, buildModel(ctx))
  const after = await checkDesignTokens(dir)
  assert.ok(!after.problems.some((p) => /--color-status-new/.test(p)), after.problems.join('\n'))
})

test('generated files missing, then not imported, then current', async () => {
  const dir = await withConfig()
  const missing = await checkDesignTokens(dir)
  assert.equal(missing.problems.filter((p) => /generated\.\w+ {2}missing/.test(p)).length, 2)

  const { readConfig } = await import(path.join(ENGINE, 'config.mjs'))
  const { buildModel } = await import(path.join(ENGINE, 'model.mjs'))
  const { writeGenerated } = await import(path.join(ENGINE, 'generate.mjs'))
  const { ctx } = await readConfig(path.join(dir, 'packages/ui/design-system/design-system.config.mjs'))
  assert.deepEqual(writeGenerated(ctx, buildModel(ctx)).sort(), ['design-system/safelist.generated.css', 'src/lib/design-tokens.generated.ts'])

  const unimported = await checkDesignTokens(dir)
  assert.equal(unimported.problems.filter((p) => /not imported/.test(p)).length, 2)

  fs.writeFileSync(path.join(dir, 'packages/ui/src/feed.css'), '@import "tailwindcss";\n@import "../design-system/safelist.generated.css";\n')
  fs.writeFileSync(path.join(dir, 'packages/ui/src/lib/utils.ts'), "import { designClassGroups } from './design-tokens.generated'\nexport const groups = designClassGroups\n")
  const current = await checkDesignTokens(dir)
  assert.deepEqual(current.problems, [])
  assert.equal(current.counts.generated, 2)

  fs.writeFileSync(path.join(dir, 'packages/ui/src/type.css'), TYPE.replaceAll('form-control', 'field-text'))
  const stale = await checkDesignTokens(dir)
  assert.ok(stale.problems.some((p) => /design-tokens\.generated\.ts {2}out of date/.test(p)))
})

// ─── whether the check applies: DESIGN_UI_PACKAGE's three states ───

test('DESIGN_UI_PACKAGE empty and listed in _intentionally_empty: does not apply, says why, inspects nothing', async () => {
  const dir = fixture({ 'apps/web/src/screen.tsx': '<div className="text-sm rounded-[3px]" />\n' }, { keys: { DESIGN_UI_PACKAGE: '', _intentionally_empty: ['DESIGN_UI_PACKAGE'] } })
  const r = await checkDesignTokens(dir)
  assert.deepEqual(r.problems, [])
  assert.equal(r.notApplicable, NOT_SET_UP)
  assert.match(r.notApplicable, /has no UI package \(DESIGN_UI_PACKAGE is intentionally empty\)/)
})

test('DESIGN_UI_PACKAGE empty but not listed: fails naming the key and both choices', async () => {
  const { problems, notApplicable } = await run({}, { keys: { ...KEYS, DESIGN_UI_PACKAGE: '' } })
  assert.equal(notApplicable, undefined)
  assert.equal(problems.length, 1)
  assert.match(problems[0], /DESIGN_UI_PACKAGE: empty, and not listed in _intentionally_empty .*set it to the UI package .*or set it to "" and list it in _intentionally_empty/)
})

test('DESIGN_UI_PACKAGE missing: fails naming the key and both choices', async () => {
  const keys = { ...KEYS }
  delete keys.DESIGN_UI_PACKAGE
  const { problems } = await run({}, { keys })
  assert.equal(problems.length, 1)
  assert.match(problems[0], /DESIGN_UI_PACKAGE: not set .*set it to the UI package .*or set it to ""/)
})

const PAINTS = 'a screen or feature file'

test('a screen or feature file places, arranges, draws and picks text roles; a colour it fades fails, wherever the file sits outside a part', async () => {
  const body = '<div className="flex flex-col gap-2 mt-4 w-full md:grid-cols-2 type-body font-strong text-foreground uppercase border-t-2 border-input pt-4 text-foreground/60" />'
  for (const file of ['apps/web/src/routes/orders.tsx', 'apps/web/src/features/orders/review.tsx', 'apps/web/src/features/orders/components/review.tsx']) {
    const { problems } = await run({ [file]: `export const S = () => ${body}\n` })
    const found = problems.filter((p) => p.includes(PAINTS))
    assert.deepEqual(found.map((p) => p.split('  ')[1]), ['<div> text-foreground/60'], file)
  }
})

test('the same look inside a part passes', async () => {
  const { problems } = await run({ 'apps/web/src/components/review-dialog.tsx': 'export const R = () => <div className="flex border-t-2 border-input pt-4 text-foreground/60" />\n' })
  assert.deepEqual(problems.filter((p) => p.includes(PAINTS)), [])
})

test('a glyph a screen colours passes; a colour faded on a third-party component fails', async () => {
  const { problems } = await run({
    'apps/web/src/routes/orders.tsx': 'import { Check } from "lucide-react"\nimport { Link } from "@tanstack/react-router"\nexport const S = () => <><Check className="size-4 text-primary" /><Link className="text-primary mt-2 text-foreground/50" to="/" /></>\n',
  })
  assert.deepEqual(problems.filter((p) => p.includes(PAINTS)).map((p) => p.split('  ')[1]), ['<Link> text-foreground/50'])
})

test('a class constant is read at the call site — declared here or imported — and a fixed height through it fails', async () => {
  const { problems } = await run({
    'apps/web/src/routes/orders.tsx': [
      'import { Button } from "@acme/ui/components/button"',
      'import { TALL } from "./styles"',
      "const DIM = 'h-10 text-foreground/50'",
      'export const S = () => <><Button className={DIM}>a</Button><Button className={cn(TALL, "mt-2")}>b</Button><div className={DIM} /></>',
      '',
    ].join('\n'),
    'apps/web/src/routes/styles.ts': 'export const TALL = "size-12"\n',
  })
  const at = (p) => p.split('  ')[1]
  assert.deepEqual(problems.filter((p) => p.includes('never fixes how tall')).map(at), ['<Button> h-10', '<Button> size-12'])
  assert.deepEqual(problems.filter((p) => p.includes(PAINTS)).map(at), ['<div> text-foreground/50'])
})

test('a frame atom is imported only inside a part, and the finding names the block types that wrap it', async () => {
  const { problems } = await run({
    'apps/web/src/routes/orders.tsx': 'import { Dialog, DialogContent } from "@acme/ui/components/ui/dialog"\nimport * as Sheet from "@radix-ui/react-dialog"\nexport const S = () => null\n',
    'apps/web/src/routes/ask.tsx': 'import { AlertDialog } from "@/components/ui/alert-dialog"\nimport { Button } from "@/components/ui/button"\nexport const S = () => null\n',
    'apps/web/src/components/review-dialog.tsx': 'import { Dialog } from "@acme/ui/components/ui/dialog"\nexport const R = () => null\n',
  })
  const frames = problems.filter((p) => p.includes('a frame atom is used only inside a part'))
  assert.equal(frames.length, 3)
  assert.match(frames[0], /^apps\/web\/src\/routes\/ask\.tsx:1 {2}AlertDialog {2}— .*ConfirmDialog part/)
  assert.match(frames[1], /^apps\/web\/src\/routes\/orders\.tsx:1 {2}Dialog {2}— .*ModalShell \/ EntityModal/)
  assert.match(frames[2], /^apps\/web\/src\/routes\/orders\.tsx:2 {2}Dialog {2}/)
})

test('a template class list is read as its text and the strings in each ${…}; an icon bound from data is a glyph', async () => {
  const { problems } = await run({
    'apps/web/src/routes/orders.tsx': [
      'export const S = ({ busy, item, Icon }) => <>',
      '  <button className={`w-full mt-2 ${busy ? "text-foreground/40" : "hover:underline"}`} />',
      '  <Icon className="size-4 text-primary" />',
      '  <item.icon className="size-6 text-primary" />',
      '</>',
      '',
    ].join('\n'),
  })
  assert.deepEqual(problems.filter((p) => p.includes(PAINTS)).map((p) => p.split('  ')[1]), ['<button> text-foreground/40'])
})

test('a screen may name any colour role, brand colours included; a faded one fails', async () => {
  const { problems } = await run({
    'packages/ui/src/styles.css': STYLES.replace('--color-primary: var(--primary);', '--color-primary: var(--primary);\n  --color-blue: var(--blue);'),
    'apps/web/src/routes/orders.tsx': 'export const S = () => <><p className="type-body text-primary hover:text-foreground">a</p><p className="text-blue">b</p><p className="text-foreground/60">c</p></>\n',
  })
  const found = problems.filter((p) => p.includes(PAINTS))
  assert.deepEqual(found.map((p) => p.split('  ')[1]), ['<p> text-foreground/60'])
  assert.match(found[0], /never fades a colour/)
})

test('the arguments of a helper that returns classes are values, not classes; a class-merge helper\'s arguments are classes', async () => {
  const { problems } = await run({
    'apps/web/src/routes/orders.tsx': 'export const S = ({ o, tz }) => <><p className={colourFor(o.date, "text-foreground/50", tz)} /><p className={cn("text-foreground/60", o.x)} /></>\n',
  })
  assert.deepEqual(problems.filter((p) => p.includes(PAINTS)).map((p) => p.split('  ')[1]), ['<p> text-foreground/60'])
})

test('the screen rules judge only lines changed since the base; untouched lines pass, all: true judges every line', async () => {
  const dir = fixture({ 'apps/web/src/routes/orders.tsx': 'export const S = () => <>\n  <div className="text-foreground/50" />\n</>\n' })
  const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args])
  git('init', '-q')
  git('add', '-A')
  git('commit', '-qm', 'base')
  const base = String(git('rev-parse', 'HEAD')).trim()
  fs.writeFileSync(path.join(dir, 'apps/web/src/routes/orders.tsx'), 'export const S = () => <>\n  <div className="text-foreground/50" />\n  <p className="text-foreground/60">new</p>\n</>\n')
  fs.writeFileSync(path.join(dir, 'apps/web/src/routes/fresh.tsx'), 'export const F = () => <div className="text-foreground/70" />\n')
  const at = (r) => r.problems.filter((p) => p.includes(PAINTS)).map((p) => p.split('  ').slice(0, 2).join(' '))
  const scoped = await checkDesignTokens(dir, { base })
  assert.deepEqual(at(scoped).sort(), ['apps/web/src/routes/fresh.tsx:1 <div> text-foreground/70', 'apps/web/src/routes/orders.tsx:3 <p> text-foreground/60'])
  assert.ok(scoped.notes.some((n) => /screen rules: 1 changed line\(s\) and 1 new file\(s\)/.test(n)))
  const everything = await checkDesignTokens(dir, { all: true })
  assert.equal(at(everything).length, 3)
})

test('a screen moved into a feature folder is judged by its edits, not as a new file', async () => {
  const dir = fixture({ 'apps/web/src/components/Roles.tsx': 'export const R = () => <>\n  <div className="text-foreground/50" />\n</>\n' })
  const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.email=t@example.com', '-c', 'user.name=t', ...args])
  git('init', '-q')
  git('add', '-A')
  git('commit', '-qm', 'base')
  const base = String(git('rev-parse', 'HEAD')).trim()
  fs.rmSync(path.join(dir, 'apps/web/src/components/Roles.tsx'))
  fs.mkdirSync(path.join(dir, 'apps/web/src/features/admin'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'apps/web/src/features/admin/Roles.tsx'), 'export const R = () => <>\n  <div className="text-foreground/50" />\n  <p className="text-foreground/60">new</p>\n</>\n')
  const { problems } = await checkDesignTokens(dir, { base })
  assert.deepEqual(problems.filter((p) => p.includes(PAINTS)).map((p) => p.split('  ').slice(0, 2).join(' ')), ['apps/web/src/features/admin/Roles.tsx:3 <p> text-foreground/60'])
})

test('the role list names every role a screen may write, one family per line', async () => {
  const { roleList } = await import('./check-design-tokens.mjs')
  const list = roleList(fixture())
  assert.match(list, /^type roles: type-body type-form-control$/m)
  assert.match(list, /^radius: rounded-control rounded-panel$/m)
  assert.match(list, /^colours \(bg-, text-, border-\): .*\bprimary\b/m)
  assert.match(list, /^utilities: scroll-region$/m)
})

test('a class list built as an array and joined is read as classes', async () => {
  const { problems } = await run({
    'packages/ui/src/components/banner.tsx': "export const B = ({ on }) => <div className={['flex rounded-lg', 'shadow-lg', on && 'text-sm'].filter(Boolean).join(' ')} />\n",
  })
  assert.deepEqual(problems.map((p) => p.split('  ')[1]).sort(), ['rounded-lg', 'shadow-lg', 'text-sm'])
})

test('purposes: the comment above or beside a token or utility, a re-export taking what it points at, a gap left empty', () => {
  const p = purposesOf([
    ['tokens.css', ':root {\n  /* ─── ramp ─── */\n  /* the page */\n  --background: #fff;\n  --input: #ccc; /* a field\'s border */\n\n  --step-12: 12px;\n}\n'],
    ['type.css', '/* why a field\'s value was refused,\n   and nothing else */\n@utility type-field-error {\n  font-size: var(--step-12);\n}\n'],
    ['styles.css', '@theme {\n  --color-background: var(--background);\n  --color-x: var(--nowhere);\n}\n'],
  ])
  assert.equal(p.get('--background'), 'the page')
  assert.equal(p.get('--input'), "a field's border")
  assert.equal(p.get('--step-12'), '')
  assert.equal(p.get('type-field-error'), "why a field's value was refused, and nothing else")
  assert.equal(p.get('--color-background'), 'the page')
  assert.equal(p.get('--color-x'), '')
})

test('patterns: every type role, token and component a reference names in code exists; a library variable and an accepted line pass', async () => {
  const ref = (body) => ({ '.claude/skills/ui-patterns/references/save-errors.md': `---\nui-status: approved\nblock-types: cross-cutting\n---\n\n${body}\n` })
  const run1 = async (body) => (await run(ref(body))).problems.filter((p) => p.startsWith('.claude/skills/ui-patterns/'))
  assert.deepEqual(await run1('A failed save uses `type-body` and `--radius-panel`, never `type-caption`.'), [
    '.claude/skills/ui-patterns/references/save-errors.md:6  type-caption  — a pattern names a type role the stylesheets do not define',
  ])
  assert.deepEqual(await run1('Corners are `--radius-big`; the menu is `--radix-popover-trigger-width` wide.'), [
    '.claude/skills/ui-patterns/references/save-errors.md:6  --radius-big  — a pattern names a token the stylesheets do not declare',
  ])
  assert.deepEqual(await run1('```tsx\n<Button>Save</Button>\n<Banner tone="error" />\n```'), [
    '.claude/skills/ui-patterns/references/save-errors.md:8  <Banner>  — a pattern names a component the UI source neither defines nor imports',
  ])
  assert.deepEqual(await run1('<!-- design-accepted — the role lands with the next release -->\nUse `type-caption`.'), [])
  assert.deepEqual(await run1('Button labels are `Save` and `Close`; prose `type` words are not roles.'), [])
  assert.deepEqual(await run1('Declare the columns as `Column<Row>[]` and `Map<Key, Value>`.'), [])
  assert.deepEqual(await run1('The label is `Download <Document> PDF` everywhere else.'), [])
  assert.deepEqual((await run1('Show it in `<Banner tone="error">`.')).length, 1)
})

test('patterns: the count says how many references were read, and none is no finding', async () => {
  const { counts } = await run({ '.claude/skills/ui-patterns/references/a.md': 'x\n', '.claude/skills/ui-patterns/references/README.md': 'y\n' })
  assert.equal(counts.patterns, 1)
  assert.equal((await run({})).counts.patterns, 0)
})
