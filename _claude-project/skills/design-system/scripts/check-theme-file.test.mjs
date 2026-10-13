// node --test .claude/skills/design-system/scripts/check-theme-file.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import { checkThemeFile } from './check-theme-file.mjs'

const tokens = new Map([
  ['--blue', '#1b6fe8'],
  ['--primary', 'var(--blue)'],
  ['--status-danger', 'oklch(0.55 0.2 25)'],
  ['--step-12', '12px'],
])

test('a theme file whose settings override existing tokens, each colour with its dark value, is clean', () => {
  const { problems, blocks, variables } = checkThemeFile(
    `/* accent */
html[data-accent="green"] { --primary: #1f8a4c; }
html[data-theme="dark"][data-accent="green"] { --primary: #4cc27f; }
html[data-colorblind="protanopia"],
html[data-colorblind="deuteranopia"] {
  --status-danger: #d97a00;
}
.dark [data-colorblind="protanopia"], .dark [data-colorblind="deuteranopia"] { --status-danger: #f0a040; }
html[data-font-size="large"] { --step-12: 14px; }
`,
    tokens,
  )
  assert.deepEqual(problems, [])
  assert.equal(blocks, 7)
  assert.equal(variables, 7)
})

test('a variable the token stylesheets do not declare fails by name', () => {
  const { problems } = checkThemeFile('html[data-font-size="large"] { --stpe-12: 14px; }', tokens)
  assert.deepEqual(problems, ['html[data-font-size="large"]  --stpe-12  — not a token the token stylesheets declare; a setting overrides an existing token'])
})

test('a colour with no dark value for its setting fails, even when another setting has one', () => {
  const { problems } = checkThemeFile(
    `html[data-accent="green"] { --primary: #1f8a4c; }
html[data-accent="purple"] { --primary: #7a4cc2; }
html[data-theme="dark"][data-accent="purple"] { --primary: #a07ae0; }`,
    tokens,
  )
  assert.deepEqual(problems, ['html[data-accent="green"]  --primary  — a colour with no dark value for this setting; override it again under the dark theme, even with the same value'])
})

test('a size needs no dark value', () => {
  assert.deepEqual(checkThemeFile('html[data-font-size="small"] { --step-12: 11px; }', tokens).problems, [])
})
