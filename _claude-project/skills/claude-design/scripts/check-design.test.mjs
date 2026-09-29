import { test } from 'node:test'
import assert from 'node:assert/strict'
import { checkPage } from './check-design.mjs'

const page = (css, body) => `<!doctype html><html><head></head><body><x-dc><helmet><style>
${css}
</style></helmet>
<x-import component-from-global-scope="NS.TooltipProvider">
${body}
</x-import></x-dc></body></html>`

const card = (inner) => `<x-import component-from-global-scope="NS.Card"><x-import component-from-global-scope="NS.CardContent">${inner}</x-import></x-import>`

test('page layout outside any component passes', () => {
  const { fails } = checkPage(page(
    `body{margin:0;background:var(--surface)}
a:not([data-slot]){color:var(--primary-ink)}
.pg-main{display:grid;grid-template-columns:360px 1fr;gap:24px;padding:24px;max-width:1600px}`,
    `<main class="pg-main">${card('<p>x</p>')}</main>`))
  assert.deepEqual(fails, [])
})

test('a provider does not count as a component the page sits inside', () => {
  const { fails } = checkPage(page('.pg-main{gap:24px}', '<main class="pg-main"></main>'))
  assert.deepEqual(fails, [])
})

test('any inline style fails', () => {
  const { fails } = checkPage(page('', card('<span style="flex-grow: 1;">x</span>')))
  assert.equal(fails.length, 1)
  assert.match(fails[0].msg, /inline style/)
})

test('inline style on a mounted component fails too', () => {
  const { fails } = checkPage(page('', '<x-import component-from-global-scope="NS.Card" style="height: 100%;"></x-import>'))
  assert.equal(fails.length, 1)
})

test('colour, type and shape in a page rule fail wherever they land', () => {
  const { fails } = checkPage(page('.pg-root{background:var(--surface);font-family:var(--font-sans)}', '<div class="pg-root"></div>'))
  assert.equal(fails.length, 1)
  assert.match(fails[0].msg, /background, font-family/)
})

test('spacing reaching inside a component fails; arrangement does not', () => {
  const { fails } = checkPage(page(
    '.pg-pair{display:grid;grid-template-columns:1fr 1fr;width:100%}\n.pg-gap{gap:8px}',
    card('<div class="pg-pair"></div><div class="pg-gap"></div>')))
  assert.equal(fails.length, 1)
  assert.match(fails[0].msg, /"\.pg-gap" reaches inside NS\.CardContent/)
})

test('spacing set on a component fails; placing it does not', () => {
  const { fails } = checkPage(page(
    '.pg-card{max-width:420px;grid-area:main;margin-top:8px}\n.pg-tall{min-height:200px}',
    '<x-import component-from-global-scope="NS.Card" class-name="pg-card"></x-import><x-import component-from-global-scope="NS.Card" class-name="pg-tall"></x-import>'))
  assert.equal(fails.length, 1)
  assert.match(fails[0].msg, /min-height on NS\.Card/)
})

test('a rule styling the inside of a component through a descendant selector fails', () => {
  const { fails } = checkPage(page('.pg-sel button{width:100%}', '<div><x-import component-from-global-scope="NS.Select" class-name="pg-sel"></x-import></div>'))
  assert.equal(fails.length, 1)
  assert.match(fails[0].msg, /styles the inside of NS\.Select/)
})

test('drawing classes on markup inside a component fail', () => {
  const { fails } = checkPage(page('', card('<div class="flex gap-3 text-muted-foreground type-body">x</div>')))
  assert.equal(fails.length, 1)
  assert.match(fails[0].msg, /"gap-3"/)
})

test('bare tag rules fail except the page basics', () => {
  const { fails } = checkPage(page('dl,dd,p{margin:0}\nhtml{scroll-behavior:smooth}', ''))
  assert.equal(fails.length, 3)
})

test('rules in a PREVIEW block are open decisions, not failures', () => {
  const { fails, open } = checkPage(page(
    `/* PREVIEW — menu row height: 40 / 48 … removed when decided */
.gap-menu-a .pg-row{min-height:40px;background:var(--muted)}
/* END PREVIEW */`,
    card('<a class="pg-row">x</a>')))
  assert.deepEqual(fails, [])
  assert.equal(open.length, 1)
  assert.match(open[0].msg, /^PREVIEW — menu row height/)
})

test('a candidate mark is listed as open but exempts nothing', () => {
  const { fails, open } = checkPage(page('', card('<!-- DESIGN-SYSTEM CANDIDATE: a contact row --><div class="gap-3">x</div>')))
  assert.equal(open.length, 1)
  assert.equal(fails.length, 1)
})

test('rules inside @media are checked like any other', () => {
  const { fails } = checkPage(page('@media (min-width:768px){\n  .pg-gap{gap:8px}\n}', card('<div class="pg-gap"></div>')))
  assert.equal(fails.length, 1)
})

const withTweaks = (props, quote = "'") => {
  const json = JSON.stringify(props)
  const attr = quote === "'" ? `'${json}'` : `"${json.replace(/&/g, '&amp;').replace(/"/g, '&quot;')}"`
  return `<html><body><x-dc></x-dc><script type="text/x-dc" data-dc-script data-props=${attr}>class Component extends DCLogic {}</script></body></html>`
}
const gaps = {
  theme: { editor: 'enum', options: ['System', 'Light', 'Dark'], default: 'System', section: 'Preview' },
  menu: { editor: 'enum', options: [], default: 'Approved — Rows inset 8px', section: 'Design system' },
  tabBar: { editor: 'enum', options: [], default: 'Undecided — Current design', section: 'Design system' },
  signIn: { editor: 'enum', options: [], default: 'System as is', section: 'Design system' },
}

test('gap tweaks are read in either quoting, the editor entity-encodes on save', () => {
  for (const q of ["'", '"']) {
    const { tweaks, fails } = checkPage(withTweaks(gaps, q))
    assert.deepEqual(tweaks.map((t) => [t.key, t.state]), [['menu', 'approved'], ['tabBar', 'undecided'], ['signIn', 'rejected']])
    assert.deepEqual(fails, [])
  }
})

test('a gap option without a state prefix fails', () => {
  const { fails } = checkPage(withTweaks({ menu: { editor: 'enum', default: 'Current design', section: 'Design system' } }))
  assert.equal(fails.length, 1)
})

test('--implement fails on every gap still in the design, and on any open preview', () => {
  const { fails } = checkPage(withTweaks(gaps), { implement: true })
  assert.equal(fails.length, 3)
  const clean = checkPage(withTweaks({ theme: gaps.theme }), { implement: true })
  assert.deepEqual(clean.fails, [])
  const preview = checkPage(page('/* PREVIEW — x */\n.a{gap:1px}\n/* END PREVIEW */', ''), { implement: true })
  assert.equal(preview.fails.length, 1)
})
