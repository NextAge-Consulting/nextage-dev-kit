import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkPage, elementsFor, loadPageChecks, pageRules, parseMarkup, requiredFrom, runPageChecks } from './check-design.mjs'

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

test('a shell does not count as a component the page sits inside', () => {
  const { fails } = checkPage(page('.pg-cols{display:grid;gap:20px}',
    '<x-import component-from-global-scope="NS.AppShell"><div class="pg-cols gap-4">x</div></x-import>'))
  assert.deepEqual(fails, [])
})

test('a component inside a shell still owns its inside', () => {
  const { fails } = checkPage(page('',
    '<x-import component-from-global-scope="NS.AppShell">' + card('<div class="gap-4">x</div>') + '</x-import>'))
  assert.equal(fails.length, 1)
  assert.match(fails[0].msg, /inside NS.CardContent/)
})

test('a component missing a required prop fails; one given it passes', () => {
  const required = requiredFrom({ namespace: 'NS', requiredProps: { DataTable: ['rowKey'] } })
  const missing = checkPage(page('', '<x-import component-from-global-scope="NS.DataTable" rows="{{rows}}"></x-import>'), { required })
  assert.equal(missing.fails.length, 1)
  assert.match(missing.fails[0].msg, /NS\.DataTable is mounted without "row-key"/)
  const given = checkPage(page('', '<x-import component-from-global-scope="NS.DataTable" row-key="{{rowKey}}"></x-import>'), { required })
  assert.deepEqual(given.fails, [])
})

test('without a config no prop is required', () => {
  const { fails } = checkPage(page('', '<x-import component-from-global-scope="NS.DataTable"></x-import>'))
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
  return `<html><body><x-dc><x-import component-from-global-scope="NS.Card"></x-import></x-dc><script type="text/x-dc" data-dc-script data-props=${attr}>class Component extends DCLogic {}</script></body></html>`
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

test('a page that mounts no component fails; one that only embeds another page passes', () => {
  const bare = checkPage('<html><body><x-dc><main class="pg-main"><p>x</p></main></x-dc></body></html>')
  assert.equal(bare.fails.length, 1)
  assert.match(bare.fails[0].msg, /mounts no design-system component/)
  const phone = checkPage('<html><body><x-dc><dc-import src="Orders.dc.html"></dc-import></x-dc></body></html>')
  assert.deepEqual(phone.fails, [])
})

test('data-props that is not JSON fails, with or without --implement', () => {
  const broken = '<html><body><x-dc><x-import component-from-global-scope="NS.Card"></x-import></x-dc><script type="text/x-dc" data-dc-script data-props=\'{"menu":\'>class Component extends DCLogic {}</script></body></html>'
  for (const implement of [false, true]) {
    const { fails } = checkPage(broken, { implement })
    assert.equal(fails.length, 1)
    assert.match(fails[0].msg, /data-props is not JSON/)
  }
})

test('counts what it inspected', () => {
  const { counts } = checkPage(page('.pg-main{display:grid}\n.pg-side{width:200px}', card('<p>x</p>')))
  assert.deepEqual(counts, { elements: 10, components: 3, rules: 2 })
})

test('the command checks every page it is given, the first included, with or without --config', async () => {
  const { execFileSync } = await import('node:child_process')
  const fs = await import('node:fs')
  const os = await import('node:os')
  const path = await import('node:path')
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'check-design-'))
  const bare = path.join(dir, 'Bare.dc.html')
  fs.writeFileSync(bare, '<html><body><x-dc><p>x</p></x-dc></body></html>')
  const script = new URL('./check-design.mjs', import.meta.url).pathname
  let out = ''
  try {
    execFileSync(process.execPath, [script, bare], { encoding: 'utf8' })
  } catch (e) {
    out = e.stdout
  }
  assert.match(out, /Bare\.dc\.html: 1 fail/)
  assert.match(out, /check-design: 1 page\(s\)/)
})

// --- project page checks ------------------------------------------------------

// The case that asked for them: a page sizing a field inside a FormRow.
const fieldWidths = async ({ rules, elementsFor, enclosingComponent, componentName, add }) => {
  for (const rule of rules) {
    const sizing = rule.decls.filter((d) => /^(width|grid-template-columns)$/.test(d.prop))
    if (!sizing.length) continue
    for (const el of elementsFor(rule)) {
      const comp = enclosingComponent(el)
      if (comp && componentName(comp) === 'NS.FormRow') {
        add(rule.line, `"${rule.selector}" sets ${sizing.map((d) => d.prop).join(', ')}`, 'a field in a FormRow brings its own width')
        break
      }
    }
  }
}
const formRow = (inner) => `<x-import component-from-global-scope="NS.FormRow">${inner}</x-import>`

test('elementsFor: a rule lands on the elements carrying each selector\'s last class', () => {
  const src = page('.pg-a, .pg-b .pg-c{display:grid}', '<div class="pg-a"></div><div class="pg-b"><span class="pg-c"></span></div><p class="pg-b"></p>')
  const els = []
  const walk = (n) => { for (const c of n.children) { els.push(c); walk(c) } }
  walk(parseMarkup(src))
  const [rule] = pageRules(src)
  assert.deepEqual(elementsFor(rule, els).map((e) => e.tag).sort(), ['div', 'span'])
})

test('a project page check reports at the page line, naming its file', async () => {
  const src = page('.pg-date{width:150px}', formRow('<div class="pg-date">date</div>'))
  const fails = await runPageChecks(src, [{ file: 'field-widths.mjs', run: fieldWidths }], { page: 'p.dc.html', config: null })
  assert.equal(fails.length, 1)
  assert.equal(fails[0].line, pageRules(src)[0].line)
  assert.match(fails[0].msg, /"\.pg-date" sets width — a field in a FormRow brings its own width \(project check field-widths\.mjs\)/)
})

test('a project page check passes layout it does not own, and never sees a PREVIEW block', async () => {
  const src = page(`.pg-main{grid-template-columns:1fr 2fr}
/* PREVIEW — wider date */
.pg-date{width:200px}
/* END PREVIEW */`, `<main class="pg-main">${formRow('<div class="pg-date">date</div>')}</main>`)
  const seen = []
  const spy = ({ rules }) => { seen.push(...rules.map((r) => r.selector)) }
  const fails = await runPageChecks(src, [{ file: 'a.mjs', run: fieldWidths }, { file: 'b.mjs', run: spy }], {})
  assert.deepEqual(fails, [])
  assert.deepEqual(seen, ['.pg-main'])
})

test('loadPageChecks: every .mjs, sorted; a file exporting no function is a problem; no folder is none', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'page-checks-'))
  try {
    fs.writeFileSync(path.join(dir, 'b.mjs'), 'export default () => {}\n')
    fs.writeFileSync(path.join(dir, 'a.mjs'), 'export default () => {}\n')
    fs.writeFileSync(path.join(dir, 'bad.mjs'), 'export const x = 1\n')
    fs.writeFileSync(path.join(dir, 'notes.md'), 'not a check\n')
    const { checks, problems } = await loadPageChecks(dir)
    assert.deepEqual(checks.map((c) => c.file), ['a.mjs', 'b.mjs'])
    assert.equal(problems.length, 1)
    assert.match(problems[0], /bad\.mjs — a page check default-exports a function/)
    assert.deepEqual(await loadPageChecks(path.join(dir, 'none')), { checks: [], problems: [] })
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('a run with --config finds page-checks beside the config, fails the page, and counts the checks', () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), 'check-design-repo-'))
  try {
    execFileSync('git', ['init', '-q'], { cwd: repo })
    fs.mkdirSync(path.join(repo, '.claude'))
    fs.writeFileSync(path.join(repo, '.claude', 'sync-substitutions.json'), JSON.stringify({
      DESIGN_UI_PACKAGE: 'ui', DESIGN_FEED_BARREL: 'src/index.ts', DESIGN_TOKEN_FILES: 'src/tokens.css', DESIGN_TYPE_FILE: '', DESIGN_STYLES_FILE: '',
    }))
    const ds = path.join(repo, 'ui', 'design-system')
    fs.mkdirSync(path.join(ds, 'page-checks'), { recursive: true })
    const config = path.join(ds, 'design-system.config.mjs')
    fs.writeFileSync(config, `export default ${JSON.stringify({
      title: 'Acme', namespace: 'NS', artifact: '', timeZone: 'America/Chicago', spacing: { steps: [0, 1] },
      css: { build: 'npm run build:css', file: 'dist/feed.css' },
      components: [{ name: 'Button', group: 'Actions', height: 80, doc: { inventory: 'Button' }, render: "h(U.Button, null, 'Save')" }],
    })}\n`)
    const pagePath = path.join(repo, 'p.dc.html')
    fs.writeFileSync(pagePath, page('.pg-date{width:150px}', formRow('<div class="pg-date">date</div>')))
    const script = fileURLToPath(new URL('./check-design.mjs', import.meta.url))
    const run = () => spawnSync(process.execPath, [script, '--config', config, pagePath], { encoding: 'utf8' })

    let r = run()
    assert.equal(r.status, 0, r.stdout + r.stderr)
    assert.match(r.stdout, /; 0 project checks$/m)

    fs.writeFileSync(path.join(ds, 'page-checks', 'field-widths.mjs'), `export default ${fieldWidths.toString()}\n`)
    r = run()
    assert.equal(r.status, 1, r.stdout + r.stderr)
    assert.match(r.stdout, /FAIL p\.dc\.html:\d+ {2}"\.pg-date" sets width .*\(project check field-widths\.mjs\)/)
    assert.match(r.stdout, /; 1 project checks$/m)
  } finally {
    fs.rmSync(repo, { recursive: true, force: true })
  }
})
