import { test } from 'node:test'
import assert from 'node:assert/strict'
import { arithmetic, candidates, declarations, hunks, ownSelector, pairLines, resolveVars, themeVars, toPx } from './compare-ui-values.mjs'

test('candidates are the words of every string literal on a line', () => {
  assert.deepEqual(candidates(`<p className="text-sm font-medium" data-x='a b'>`), ['text-sm', 'font-medium', 'a', 'b'])
  assert.deepEqual(candidates('cn(`p-2 ${x}`, "mt-1")'), ['p-2', 'mt-1'])
})

test('lengths become px; arithmetic is evaluated; bare numbers keep their precision', () => {
  assert.equal(toPx('0.875rem'), '14px')
  assert.equal(toPx('calc(0.25rem * 3)'), '12px')
  assert.equal(toPx('calc(1rem - 2px)'), '14px')
  assert.equal(toPx('calc(1.25 / 0.875)'), String(1.25 / 0.875))
  assert.equal(toPx('oklch(0.42 0 0)'), 'oklch(0.42 0 0)')
})

test('var() resolves through the map, nested, with fallbacks', () => {
  const vars = new Map([['--a', 'var(--b)'], ['--b', '1rem']])
  assert.equal(resolveVars('var(--a)', vars), '1rem')
  assert.equal(resolveVars('var(--tw-leading, var(--b))', vars), '1rem')
  assert.equal(resolveVars('var(--none)', vars), '<undefined --none>')
})

test('theme variables come from :root, universal defaults and @property, never the dark block', () => {
  const css = `@layer theme { :root, :host { --text-sm: 0.875rem; } }
:root { --fg: black; }
.dark { --fg: white; }
@property --tw-border-style { syntax: "*"; inherits: false; initial-value: solid; }
@layer properties { *, ::before { --tw-shadow: 0 0 #0000; } }`
  const vars = themeVars(css)
  assert.equal(vars.get('--text-sm'), '0.875rem')
  assert.equal(vars.get('--fg'), 'black')
  assert.equal(vars.get('--tw-border-style'), 'solid')
  assert.equal(vars.get('--tw-shadow'), '0 0 #0000')
})

test('a utility\'s declarations, with their variant context, custom properties included', () => {
  const css = `@layer utilities {
  .text-sm { font-size: var(--text-sm); }
  .hover\\:bg-x { &:hover { @media (hover: hover) { background-color: var(--x); } } }
  .shadow-md { --tw-shadow: 0 1px red; box-shadow: var(--tw-shadow); }
}`
  assert.deepEqual([...declarations(css, 'text-sm')], [['|font-size', 'var(--text-sm)']])
  assert.deepEqual([...declarations(css, 'hover:bg-x')], [['&:hover @media (hover: hover)|background-color', 'var(--x)']])
  assert.deepEqual([...declarations(css, 'shadow-md')], [['|--tw-shadow', '0 1px red'], ['|box-shadow', 'var(--tw-shadow)']])
})

test('diff hunks carry the file, the new-side line, and the removed and added lines', () => {
  const diff = `diff --git a/src/a.tsx b/src/a.tsx
--- a/src/a.tsx
+++ b/src/a.tsx
@@ -3 +3 @@
-<p className="text-sm">
+<p className="type-meta">
@@ -9,0 +10,2 @@
+one
+two`
  assert.deepEqual(hunks(diff), [
    { file: 'src/a.tsx', line: 3, removed: ['<p className="text-sm">'], added: ['<p className="type-meta">'] },
    { file: 'src/a.tsx', line: 10, removed: [], added: ['one', 'two'] },
  ])
})

test('arithmetic evaluates + - * / and parentheses, and refuses anything else', () => {
  assert.equal(arithmetic('(4 * 3) - 2'), 10)
  assert.equal(arithmetic('1.25 / 0.875'), 1.25 / 0.875)
  assert.equal(arithmetic('-(2 + 2)'), -4)
  assert.equal(arithmetic('2 + x'), null)
})

test('a class matches its own selector, never a longer class it prefixes', () => {
  const own = ownSelector('.p-2')
  assert.equal(own.within('.p-2'), true)
  assert.equal(own.within('.p-2:hover'), true)
  assert.equal(own.within('.p-20'), false)
  assert.equal(own.within('.p-2-x'), false)
  assert.equal(own.replaced('.p-2:hover, .p-2 > *'), '&:hover, & > *')
})

test('an escaped character after the match means a longer class', () => {
  assert.equal(ownSelector('.py-2').within('.py-2\\.5'), false)
  assert.equal(ownSelector('.py-1').within('.py-1\\.5'), false)
  assert.equal(ownSelector('.py-2\\.5').within('.py-2\\.5'), true)
})

test('lines pair by their shape; a line with no partner is left over, never merged', () => {
  const removed = ['<div className="p-2">', '<span className="text-sm">a</span>']
  const added = ['<div className="p-3">', '<Icon className="size-4" />', '<span className="type-meta">a</span>']
  const { pairs, leftover } = pairLines(removed, added)
  assert.deepEqual(pairs, [[0, 0], [1, 2]])
  assert.deepEqual(leftover, [{ side: 'added', index: 1 }])
})

test('an equal-sized gap between matches pairs one to one', () => {
  const { pairs, leftover } = pairLines(['a("x")', 'b("y")'], ['c("x")', 'd("y")'])
  assert.deepEqual(pairs, [[0, 0], [1, 1]])
  assert.deepEqual(leftover, [])
})
