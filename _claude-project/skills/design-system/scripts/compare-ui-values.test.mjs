import { test } from 'node:test'
import assert from 'node:assert/strict'
import { INITIAL, arithmetic, candidates, cssEvents, variants, declarations, explainMoves, hunks, ownSelector, pairLines, resolveVars, themeVars, toPx } from './compare-ui-values.mjs'

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
  assert.deepEqual([...declarations(css, 'hover:bg-x')], [['&:hover » @media (hover: hover)|background-color', 'var(--x)']])
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

const look = () => new Map([['|border-width', '1px'], ['|border-radius', '6px'], ['|padding-inline', '12px']])

test('a shared look pulled out of three components into one place is a move, not a change', () => {
  const diffs = [
    { where: 'textarea.tsx:12', lost: look(), gained: new Map() },
    { where: 'input.tsx:9', lost: look(), gained: new Map() },
    { where: 'select.tsx:30', lost: look(), gained: new Map() },
    { where: 'field.ts:3', lost: new Map(), gained: look() },
  ]
  const { moved, remaining } = explainMoves(diffs)
  assert.deepEqual(moved.map((m) => `${m.from}>${m.to}`), ['textarea.tsx:12>field.ts:3', 'input.tsx:9>field.ts:3', 'select.tsx:30>field.ts:3'])
  assert.deepEqual(remaining, [])
})

test('a value that changed in place is never explained by a move elsewhere', () => {
  const diffs = [
    { where: 'a.tsx:1', lost: new Map(), gained: new Map(), changed: new Map([['|font-size', ['13px', '12px']]]) },
    { where: 'b.tsx:1', lost: new Map(), gained: new Map([['|font-size', '13px']]) },
  ]
  const { moved, remaining } = explainMoves(diffs)
  assert.deepEqual(moved, [])
  assert.equal(remaining.length, 2)
})

test('a line that changed one value still moves the styles it lost outright', () => {
  const type = new Map([['|font-size', '16px'], ['|line-height', '24px']])
  const { moved, remaining } = explainMoves([
    { where: 'input.tsx:35', lost: new Map(type), gained: new Map(), changed: new Map([['|height', ['28px', '36px']]]) },
    { where: 'input.tsx:14', lost: new Map(), gained: new Map(type) },
  ])
  assert.deepEqual(moved, [{ from: 'input.tsx:35', to: 'input.tsx:14', styles: 2 }])
  assert.deepEqual(remaining.map((d) => [...d.changed]), [[['|height', ['28px', '36px']]]])
})

test('what moved is explained and the style that differs stays listed, on both sides', () => {
  const extra = look()
  extra.set('|color', 'red')
  const target = look()
  target.set('|gap', '4px')
  const { moved, remaining } = explainMoves([
    { where: 'a.tsx:1', lost: extra, gained: new Map() },
    { where: 'b.tsx:1', lost: look(), gained: new Map() },
    { where: 'field.ts:1', lost: new Map(), gained: target },
  ])
  assert.deepEqual(moved.map((m) => m.from), ['a.tsx:1', 'b.tsx:1'])
  assert.deepEqual(remaining.map((d) => d.where), ['a.tsx:1', 'field.ts:1'])
  assert.deepEqual([...remaining[0].lost], [['|color', 'red']])
  assert.deepEqual([...remaining[1].gained], [['|gap', '4px']])
})

test('theme variables follow the cascade: unlayered over layered, a self-reference is no value, dark overrides in dark mode', () => {
  const css = `@layer theme { :root { --c: var(--c); --size: 1rem; } }
:root { --c: red; }
@media (prefers-color-scheme: dark) { :root:not(.light) { --c: blue; } }`
  assert.equal(themeVars(css, 'light').get('--c'), 'red')
  assert.equal(themeVars(css, 'dark').get('--c'), 'blue')
  assert.equal(themeVars(css, 'dark').get('--size'), '1rem')
})

test('one shared property is coincidence, not a move', () => {
  const { moved, remaining } = explainMoves([
    { where: 'a.tsx:1', lost: new Map([['|outline-style', 'none'], ['|color', 'red'], ['|gap', '8px']]), gained: new Map() },
    { where: 'b.tsx:1', lost: new Map(), gained: new Map([['|outline-style', 'none']]) },
  ])
  assert.deepEqual(moved, [])
  assert.equal(remaining.length, 2)
})

test('an `initial` variable falls back; a pill radius is one value', () => {
  assert.equal(resolveVars('var(--tw-leading, 20px)', new Map([['--tw-leading', 'initial']])), '20px')
  assert.equal(resolveVars('var(--tw-ring-inset) 0 0', new Map([['--tw-ring-inset', 'initial']])), ' 0 0')
  assert.equal(toPx('calc(infinity * 1px)'), '9999px')
})

test('a property at its CSS initial value counts as unset', () => {
  assert.deepEqual(INITIAL['background-color'], ['transparent'])
  assert.deepEqual(INITIAL['border-color'], ['currentcolor'])
})

test('an either/or class choice is two variants, never both classes at once', () => {
  assert.deepEqual(variants(`className={cn("flex", dense ? "h-7" : "h-9")}`), [['flex', 'h-7'], ['flex', 'h-9']])
  assert.deepEqual(variants(`className={cn("p-2", active && "bg-muted")}`), [['p-2', 'bg-muted'], ['p-2']])
  assert.deepEqual(variants('className="p-2"'), [['p-2']])
  assert.equal(variants('a ? "x" : "y", b ? "x" : "y", c ? "x" : "y", d ? "x" : "y"'), null)
})

test('a Radix runtime variable compares as written, never as undefined', () => {
  assert.equal(resolveVars('var(--radix-select-content-available-height)', new Map()), 'runtime(--radix-select-content-available-height)')
})

test('a token @supports override nested in :root wins in light mode as well as dark', () => {
  const css = `:root {
  --ring: red;
  @supports (color: color-mix(in lab, red, red)) {
    --ring: color-mix(in oklab, red 20%, transparent);
  }
}`
  assert.equal(themeVars(css, 'light').get('--ring'), 'color-mix(in oklab, red 20%, transparent)')
  assert.equal(themeVars(css, 'dark').get('--ring'), 'color-mix(in oklab, red 20%, transparent)')
})

test('braces and semicolons inside strings, comments and url() never break a block', () => {
  const css = `:root {
  --quote: "{;}";
  /* a { comment ; } */
  --icon: url(data:image/svg+xml;utf8,<svg>{}</svg>);
  --escaped: 'a\\'}';
  --after: 4px
}`
  const vars = themeVars(css)
  assert.equal(vars.get('--quote'), '"{;}"')
  assert.equal(vars.get('--icon'), 'url(data:image/svg+xml;utf8,<svg>{}</svg>)')
  assert.equal(vars.get('--after'), '4px')
  assert.deepEqual([...cssEvents('.a { b: c }')].map((e) => e.type), ['open', 'decl', 'close'])
  assert.deepEqual([...declarations('.p-2 { content: "}"; padding: 8px; }', 'p-2')], [['|content', '"}"'], ['|padding', '8px']])
})
