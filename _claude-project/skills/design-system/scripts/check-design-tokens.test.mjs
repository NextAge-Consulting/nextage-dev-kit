import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkDesignTokens, NOT_SET_UP, parityProblems } from './check-design-tokens.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const ENGINE = path.resolve(HERE, '../../claude-design/scripts')

const KEYS = {
  DESIGN_UI_PACKAGE: 'packages/ui',
  DESIGN_FEED_BARREL: 'src/index.ts',
  DESIGN_TOKEN_FILES: 'src/tokens.css',
  DESIGN_TYPE_FILE: 'src/type.css',
  DESIGN_STYLES_FILE: 'src/styles.css',
  DESIGN_SOURCE_DIRS: 'apps/web/src packages/ui/src',
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

const SCREEN = `import { Button } from "@acme/ui/components/button"
import { Spinner } from "@acme/ui/components/spinner"
export function Screen() {
  return (
    <main className="scroll-region bg-background text-foreground">
      <Button className="mt-2 w-full">Save</Button>
      <Spinner className="size-4 text-primary" />
      <p className="type-body font-strong leading-prose font-sans">x</p>
    </main>
  )
}
`

/** A repository on disk: the files given, over a clean baseline. */
function fixture(files = {}, { keys = KEYS } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'design-tokens-'))
  const all = {
    '.claude/sync-substitutions.json': JSON.stringify(keys, null, 2),
    'design.md': DESIGN,
    'packages/ui/src/tokens.css': TOKENS,
    'packages/ui/src/type.css': TYPE,
    'packages/ui/src/styles.css': STYLES,
    'packages/ui/src/components/button.tsx': BUTTON,
    'apps/web/src/screen.tsx': SCREEN,
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
const screen = (body, imports = '') => ({ 'apps/web/src/screen.tsx': `${imports}\nexport function S() {\n  return ${body}\n}\n` })

test('a clean project passes and says how much it inspected', async () => {
  const { problems, counts, notes } = await run()
  assert.deepEqual(problems, [])
  assert.equal(counts.sourceFiles, 3)
  assert.equal(counts.stylesheets, 3)
  assert.ok(counts.classesChecked > 10)
  assert.match(notes.join(' '), /no claude-design config/)
})

test('no source files fails instead of passing', async () => {
  const { problems } = await run({ 'apps/web/src/screen.tsx': null, 'packages/ui/src/components/button.tsx': null, 'packages/ui/src/components/field.tsx': null })
  assert.match(problems.at(-1), /scanned 0 source file\(s\).*nothing to check/)
})

test('a stylesheet named by two keys is read once', async () => {
  const { counts } = await run({}, { keys: { ...KEYS, DESIGN_TOKEN_FILES: 'src/tokens.css src/styles.css' } })
  assert.equal(counts.stylesheets, 3)
})

test('a missing design key fails by name', async () => {
  const keys = { ...KEYS }
  delete keys.DESIGN_SOURCE_DIRS
  const { problems } = await run({}, { keys })
  assert.deepEqual(problems, ['DESIGN_SOURCE_DIRS: not set in .claude/sync-substitutions.json'])
})

test('a source dir that does not exist fails by name', async () => {
  const { problems } = await run({}, { keys: { ...KEYS, DESIGN_SOURCE_DIRS: 'apps/web/src apps/gone/src' } })
  assert.ok(problems.some((p) => /apps\/gone\/src {2}— a DESIGN_SOURCE_DIRS entry, not found/.test(p)))
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

test('roles the CSS defines pass: a leading token, 0.5, a radius corner, a colour with opacity', async () => {
  const { problems } = await run(screen('<div className="leading-prose p-0.5 rounded-t-panel text-foreground/60 rounded-none" />'))
  assert.deepEqual(problems, [])
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

test('a call site that repaints a component fails; placing it passes; an exempt component passes', async () => {
  const imports = 'import { Button } from "@acme/ui/components/button"\nimport { PopoverTrigger } from "@acme/ui/components/popover"'
  const bad = await run(screen('<><Button className="p-2 mt-1" /><PopoverTrigger className="p-2" /></>', imports))
  assert.equal(bad.problems.length, 1)
  assert.match(bad.problems[0], /<Button> p-2 {2}— a call site places a component/)
})

test('a call site may set a width or bound a height, never fix a height', async () => {
  const imports = 'import { Button } from "@acme/ui/components/button"'
  const { problems } = await run(screen('<><Button className="h-8 w-8" /><Button className="w-full h-full max-h-60" /></>', imports))
  assert.equal(problems.length, 1)
  assert.match(problems[0], /<Button> h-8 {2}— a call site places a component/)
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
  const { problems } = await run({ 'apps/web/src/screen.tsx': src })
  assert.deepEqual(problems.map((p) => p.split('  ')[1]), ['text-sm'])
})

test('a class constant is checked where it is declared, used here or in another file', async () => {
  const { problems } = await run({
    'apps/web/src/styles.ts': 'export const cell = "px-[10px]"\nexport const notClasses = "text-only"\n',
    'apps/web/src/screen.tsx': 'import { cell } from "./styles"\nexport const S = () => <td className={cn(cell)} />\n',
  })
  assert.deepEqual(problems.map((p) => p.split('  ')[1]), ['px-[10px]'])
})

test('a var() that resolves to nothing fails', async () => {
  const { problems } = await run({ 'packages/ui/src/styles.css': `${STYLES}\n.x { color: var(--nowhere); }\n` })
  assert.ok(problems.some((p) => /--nowhere {2}— referenced but never defined/.test(p)))
})

test('a token nothing reaches fails, unless it is marked not-yet-built', async () => {
  const unused = await run({ 'packages/ui/src/tokens.css': TOKENS.replace(':root {', ':root {\n  /* a colour for later */\n  --later: #ff0000;') })
  assert.ok(unused.problems.some((p) => /--later {2}— defined but nothing reaches it/.test(p)))
  const marked = await run({ 'packages/ui/src/tokens.css': TOKENS.replace(':root {', ':root {\n  --later: #ff0000; /* not-yet-built: the dashboard */') })
  assert.deepEqual(marked.problems, [])
})

test('a role named by its size fails where it is defined, in every family', async () => {
  const { problems } = await run({
    'packages/ui/src/styles.css': STYLES.replace('@theme inline {', '@theme inline {\n  --radius-md: 4px;\n  --font-weight-semibold: 600;\n  --shadow-lg: 0 0 4px black;'),
    'packages/ui/src/type.css': `${TYPE}\n@utility type-sm {\n  font-size: 14px;\n}\n`,
  })
  const named = problems.filter((p) => /named by its size/.test(p))
  assert.equal(named.length, 4)
  assert.match(named.join('\n'), /packages\/ui\/src\/styles\.css:2 {2}--radius-md {2}— a radius role named by its size/)
  assert.match(named.join('\n'), /--font-weight-semibold {2}— a weight role named by its size/)
  assert.match(named.join('\n'), /--shadow-lg {2}— a shadow role named by its size/)
  assert.match(named.join('\n'), /type-sm {2}— a type role named by its size/)
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

test('design.md: a missing frontmatter key, a role without an entry, an unknown quoted class, an off-grid pixel', async () => {
  const design = DESIGN.replace('  formControl:\n    fontSize: 14px\n', '').replace('a 14px body.', 'a 14px body, `rounded.huge`, {colors.secondary}, `type-caption`, 15px padding.')
  const { problems } = await run({ 'design.md': design })
  const text = problems.join('\n')
  assert.match(text, /type-form-control {2}— a type role with no typography entry/)
  assert.match(text, /rounded\.huge {2}— no such key in the frontmatter/)
  assert.match(text, /\{colors\.secondary\} {2}— no such key/)
  assert.match(text, /type-caption {2}— no such type role/)
  assert.match(text, /15px {2}— off the grid/)
  assert.equal(problems.length, 5)
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
  families: { skip: /^(size-|step-|weight-|leading-)/ },
  spacing: { steps: [0, 1, 2] },
  css: { build: 'true', file: 'dist/feed.css' },
  components: [{ name: 'Button', group: 'Actions', height: 80, doc: { source: 'components/button.tsx' }, render: "h(U.Button, null, 'Save')" }],
}
`

async function withConfig(extra = {}) {
  const dir = fixture({
    'packages/ui/package.json': '{ "name": "ui" }\n',
    'packages/ui/design-system/design-system.config.mjs': CONFIG,
    ...extra,
  })
  execFileSync('git', ['init', '-q'], { cwd: dir })
  return dir
}

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
