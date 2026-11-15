import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { generateDesignMd, handWritten, renderDesignMd, tokenFrontmatter, writeDesignMd } from './design-md.mjs'

const model = {
  colorTokens: [
    { name: 'background', value: { light: 'oklch(1 0 0)' }, usage: 'the page' },
    { name: 'primary', value: { light: '#3355aa' }, usage: 'a solid action' },
    { name: 'accent', value: { light: '{primary}' }, usage: 'an alias' },
  ],
  groups: [{ name: 'Body', styles: [{ name: 'body', fontSize: '14px', lineHeight: '20px', fontWeight: 400 }, { name: 'row-title', fontSize: '14px', lineHeight: '20px', fontWeight: 500, family: 'mono', letterSpacing: '0.01em' }] }],
  radius: [{ name: 'radius-control', value: '6px' }],
  spacing: [{ name: 'spacing-4', value: '16px' }, { name: 'spacing-control', value: '32px' }],
  families: { radius: /^radius-/, shadow: /^shadow-/ },
}

test('the token groups come from the model: colours as hex with aliases resolved, type with its fields, radius and spacing by role', () => {
  const lines = tokenFrontmatter(model)
  assert.deepEqual(lines, [
    'colors:',
    '  background: "#ffffff"',
    '  primary: "#3355aa"',
    '  accent: "#3355aa"',
    'typography:',
    '  body:',
    '    fontFamily: "sans"',
    '    fontSize: 14px',
    '    lineHeight: 20px',
    '    fontWeight: 400',
    '  row-title:',
    '    fontFamily: "mono"',
    '    fontSize: 14px',
    '    lineHeight: 20px',
    '    fontWeight: 500',
    '    letterSpacing: 0.01em',
    'rounded:',
    '  control: 6px',
    'spacing:',
    '  4: 16px',
    '  control: 32px',
  ])
})

const EXISTING = `---
name: Acme
colors:
  primary: "#000000"
  stale: "#ff0000"
components:
  button:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.background}"
typography:
  old:
    fontSize: 12px
---

# Acme

## Overview

Trade-focused, utility-first.
`

test('the hand-written parts survive: the components block and the body; the token groups are replaced', () => {
  const { components, body } = handWritten(EXISTING)
  assert.deepEqual(components, ['components:', '  button:', '    backgroundColor: "{colors.primary}"', '    textColor: "{colors.background}"'])
  assert.match(body, /^\n# Acme/)
  const out = renderDesignMd(model, EXISTING)
  assert.match(out, /^---\nname: Acme\ncolors:\n  background: "#ffffff"/)
  assert.doesNotMatch(out, /stale/)
  assert.doesNotMatch(out, /  old:/)
  assert.match(out, /components:\n  button:\n    backgroundColor: "\{colors\.primary\}"/)
  assert.match(out, /---\n\n# Acme\n\n## Overview\n\nTrade-focused, utility-first\.\n$/)
})

test('a project with no design.md gets the format\'s sections as empty headings', () => {
  const out = renderDesignMd(model, null, { title: 'Fixture' })
  assert.match(out, /^---\nname: Fixture\n/)
  for (const s of ['## Overview', '## Colors', '## Typography', '## Layout', '## Elevation & Depth', '## Shapes', '## Components', "## Do's and Don'ts"]) assert.ok(out.includes(s), s)
})

// A repository on disk, with and without a design-system config.
function fixture({ config = false, design = EXISTING } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'design-md-'))
  const files = {
    '.claude/sync-substitutions.json': JSON.stringify({ DESIGN_UI_PACKAGE: 'packages/ui', DESIGN_FEED_BARREL: 'src/index.ts', DESIGN_TOKEN_FILES: 'src/tokens.css', DESIGN_TYPE_FILE: 'src/type.css', DESIGN_STYLES_FILE: 'src/styles.css' }),
    'packages/ui/package.json': '{ "name": "@acme/ui" }\n',
    'packages/ui/src/tokens.css': ':root {\n  /* the page */\n  --background: oklch(1 0 0);\n  /* a solid action */\n  --primary: #3355aa;\n  /* a control corner */\n  --radius-control: 6px;\n  /* publish: off */\n  /* body size */\n  --step-body: 14px;\n  /* publish: on */\n}\n.dark {\n  --background: oklch(0.15 0 0);\n}\n',
    'packages/ui/src/type.css': '/* ─── body ─── */\n/* running text */\n@utility type-body {\n  font-size: var(--step-body);\n  line-height: 20px;\n  font-weight: 400;\n}\n',
    'packages/ui/src/styles.css': '@theme inline {\n  --color-background: var(--background);\n  --color-primary: var(--primary);\n  --radius-control: var(--radius-control);\n}\n',
  }
  if (design !== null) files['design.md'] = design
  if (config) files['packages/ui/design-system/design-system.config.mjs'] = `export default { title: 'Acme', namespace: 'Acme', artifact: '', timeZone: 'America/Chicago', spacing: { steps: [0, 1, 2] }, css: { build: 'true', file: 'dist/feed.css' }, components: [{ name: 'Button', group: 'Actions', height: 80, doc: { design: 'Buttons' }, render: "h(U.Button, null, 'Save')" }] }\n`
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), content)
  }
  execFileSync('git', ['init', '-q'], { cwd: dir })
  return dir
}

test('generated from a repository with no config: the DESIGN_* keys alone; the publish markers decide what is carried', async () => {
  const dir = fixture()
  const r = await generateDesignMd(dir)
  assert.deepEqual(r.problems, [])
  assert.equal(r.current, false)
  assert.match(r.text, /colors:\n  background: "#ffffff"\n  primary: "#3355aa"\n/)
  assert.doesNotMatch(r.text, /step-body/)
  assert.match(r.text, /typography:\n  body:\n    fontFamily: "sans"\n    fontSize: 14px\n    lineHeight: 20px\n    fontWeight: 400\n/)
  assert.match(r.text, /rounded:\n  control: 6px\n/)
  assert.doesNotMatch(r.text, /spacing:/)
  assert.ok(await writeDesignMd(dir))
  assert.equal((await generateDesignMd(dir)).current, true)
  assert.equal(await writeDesignMd(dir), false)
})

test('with a config, the spacing steps are published too', async () => {
  const dir = fixture({ config: true })
  const r = await generateDesignMd(dir)
  assert.deepEqual(r.problems, [])
  assert.match(r.text, /spacing:\n  0: 0px\n  1: 4px\n  2: 8px\n/)
})

test('a missing design key fails by name', async () => {
  const dir = fixture()
  fs.writeFileSync(path.join(dir, '.claude/sync-substitutions.json'), JSON.stringify({ DESIGN_UI_PACKAGE: 'packages/ui' }))
  const r = await generateDesignMd(dir)
  assert.ok(r.problems.some((p) => /DESIGN_TOKEN_FILES/.test(p)), r.problems.join('\n'))
})
