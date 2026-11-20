import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile, execFileSync, spawnSync } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { captureScript, classesIn, isMarker, inlineAssets, inlineImages, page, rewriteUrls, slug, styles, swapClasses, withAncestors } from './render-comparison.mjs'

const SCRIPT = new URL('./render-comparison.mjs', import.meta.url).pathname

test('classes are read from class attributes, and swapped whole, there only', () => {
  const html = '<div class="card p-4 shadow-card"><p class=\'p-4x\' data-x="p-4">p-4</p></div>'
  assert.deepEqual(classesIn(html), ['card', 'p-4', 'shadow-card', 'p-4x'])
  assert.deepEqual(['group', 'group/row', 'peer', 'lucide', 'lucide-star', 'grouped', 'lucid'].filter(isMarker), ['group', 'group/row', 'peer', 'lucide', 'lucide-star'])
  assert.deepEqual(classesIn('<i class="[&amp;_svg]:size-4 data-[state=&quot;open&quot;]:flex"></i>'), ['[&_svg]:size-4', 'data-[state="open"]:flex'])
  assert.equal(swapClasses(html, [['p-4', 'p-2 gap-1'], ['shadow-card', 'shadow-raised']]), '<div class="card p-2 gap-1 shadow-raised"><p class="p-4x" data-x="p-4">p-4</p></div>', 'a class that only starts the same, an attribute and the text are left alone')
})

test('a stylesheet\'s assets are rewritten one by one; a data address is left alone', () => {
  const css = '@font-face{src:url("./a.woff2") format("woff2"),url(b.woff)}.x{background:url(data:image/png;base64,AA)}'
  assert.equal(rewriteUrls(css, (t) => `/abs/${t.replace('./', '')}`), '@font-face{src:url("/abs/a.woff2") format("woff2"),url("/abs/b.woff")}.x{background:url(data:image/png;base64,AA)}')
})

test('a class is styled when the stylesheet holds its selector, variants and fractions included', () => {
  const css = '.type-title{font-size:1px}.hover\\:bg-accent:hover{color:red}.w-1\\/2{width:50%}'
  assert.ok(styles(css, 'type-title') && styles(css, 'hover:bg-accent') && styles(css, 'w-1/2'))
  assert.ok(!styles(css, 'type-titel'))
})

test('a page holds the stylesheets and each option under its name; one unnamed option is the page itself', () => {
  const many = page({ html: { class: 'root', 'data-theme': 'light' }, body: { class: 'app' }, css: ['.a{}'], columns: [{ name: 'Today', html: '<b class="a">x</b>' }, { name: 'Bolder', html: '<b class="a">y</b>', vars: { '--w': '700' } }] })
  assert.match(many, /<html class="root" data-theme="light">/)
  assert.match(many, /<body class="app">/)
  assert.match(many, /<div data-cmp-option="Bolder" style="--w: 700"><p data-cmp-name data-cmp-label="2 of 2 — Bolder">2 of 2 — Bolder<\/p><div data-cmp-window><div><b class="a">y<\/b><\/div><\/div><\/div>/, 'each option is numbered, so how many there are is on the page')
  const alone = page({ title: 'Menu', css: [], columns: [{ name: 'Bolder', html: '<b>y</b>', of: [2, 3], edits: [{ select: 'b', add: 'x' }] }] })
  assert.match(alone, /<title>2 of 3 — Bolder · Menu<\/title>/)
  assert.match(alone, /data-cmp-edits="\[\{&quot;select&quot;:&quot;b&quot;,&quot;add&quot;:&quot;x&quot;\}\]"><p data-cmp-name data-cmp-label="2 of 3 — Bolder">/, 'an option written alone still says which of how many it is')
  assert.match(many, /data-cmp-theme/)
  const one = page({ body: { class: 'app' }, css: ['.a{}'], columns: [{ name: '', html: '<main>whole</main>', vars: { '--w': '1' } }] })
  assert.match(one, /<body class="app">\n<main>whole<\/main>\n<\/body>/, 'nothing is added to a whole screen')
  assert.ok(!/data-cmp/.test(one))
  assert.match(page({ title: 'Orders', css: [], columns: [{ name: '', title: 'Wide rail', html: '<main></main>', of: [2, 2] }] }), /<title>2 of 2 — Wide rail · Orders<\/title>/, 'a whole screen says its place in its title, the only place nothing is added to the app')
  assert.match(one, /<html style="--w: 1">/)
  assert.equal(slug('Section title (new)'), 'section-title-new')
})

test('a section is wrapped in its ancestors, each held at the width it measured', () => {
  const capture = { section: '<section class="panel">x</section>', ancestors: [{ tag: 'main', attrs: { class: 'content' }, width: 960 }, { tag: 'div', attrs: { class: 'narrow', style: 'color: red' }, width: 520.456 }] }
  assert.equal(withAncestors(capture), '<main class="content" style="width: 960px; max-width: none; box-sizing: border-box"><div class="narrow" style="color: red; width: 520.46px; max-width: none; box-sizing: border-box"><section class="panel">x</section></div></main>')
})

test('fonts and images served over the network are carried in the page; one that cannot be fetched keeps its address and is reported', async () => {
  const fetcher = async (url) => (url.endsWith('gone.woff2') ? { ok: false, status: 404 } : { ok: true, headers: { get: () => 'font/woff2' }, arrayBuffer: async () => new TextEncoder().encode('F').buffer })
  const r = await inlineAssets('@font-face{src:url(/f/a.woff2),url("gone.woff2")}', 'http://localhost:3001/assets/app.css', fetcher)
  assert.equal(r.css, '@font-face{src:url("data:font/woff2;base64,Rg=="),url("http://localhost:3001/assets/gone.woff2")}')
  assert.deepEqual(r.missed, ['http://localhost:3001/assets/gone.woff2'])
  const local = await inlineAssets('.x{background:url(img/a.png)}', 'file:///site/app.css', fetcher)
  assert.equal(local.css, '.x{background:url("file:///site/img/a.png")}', 'a file on disk keeps its full address')
  const img = await inlineImages('<img alt="" src="/logo.png"><img src="data:x">', 'http://localhost:3001/account', fetcher)
  assert.equal(img.html, '<img alt="" src="data:font/woff2;base64,Rg=="><img src="data:x">')
})

// The join that matters: a real browser runs the capture on a real page, and the page built
// from it draws the section as the original did.
const browser = spawnSync('agent-browser', ['--version'], { encoding: 'utf8' })
test('a section captured from a running page draws as it did there', { skip: browser.status === 0 ? false : 'agent-browser is not installed on this machine, so no browser can run the capture' }, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'render-cmp-'))
  fs.writeFileSync(path.join(dir, 'app.css'), 'body.app{font-family:Georgia,serif;color:rgb(20,40,80);margin:0}.shell{display:grid;grid-template-columns:240px 1fr;min-height:100vh}.item{color:rgb(1,2,3)}.loud{color:rgb(200,0,0)}.content{padding:24px}.narrow{max-width:520px;font-size:15px}.panel{border:1px solid #999;padding:16px}.panel:hover{background:rgb(255,240,200)}.title{font-size:22px}.roomy{padding:32px}')
  fs.writeFileSync(path.join(dir, 'index.html'), '<!doctype html><html lang="en" data-theme="light"><head><link rel="stylesheet" href="app.css"><style>.spaced{letter-spacing:1px}</style></head><body class="app"><div class="shell"><nav>nav</nav><main class="content"><div class="narrow"><section id="target" class="panel spaced"><h2 class="title">Account</h2><p class="item" id="one">one</p><p class="item" id="two">two</p><input id="f" value="start"></section><p>sibling</p></div></main></div></body></html>')
  const server = http.createServer((req, res) => {
    const file = path.join(dir, req.url === '/' ? 'index.html' : req.url.slice(1))
    res.setHeader('content-type', file.endsWith('.css') ? 'text/css' : 'text/html')
    res.end(fs.readFileSync(file))
  })
  await new Promise((r) => server.listen(0, '127.0.0.1', r))
  const session = `render-comparison-test-${process.pid}`
  // Never the blocking form: the page is served from this process while the browser loads it.
  const run = (bin, args, input) => new Promise((resolve, reject) => {
    const child = execFile(bin, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }, (err, stdout, stderr) => (err ? reject(new Error(`${bin} ${args.join(' ')}: ${stderr || err.message}`)) : resolve(stdout)))
    if (input !== undefined) child.stdin.end(input)
  })
  const ab = (...args) => run('agent-browser', ['--session', session, ...args])
  const evalRaw = (script) => run('agent-browser', ['--session', session, 'eval', '--stdin', '--json'], script)
  const evalJson = async (script) => JSON.parse(JSON.parse(await evalRaw(script)).data.result)
  const read = (root) => `JSON.stringify((()=>{const e=document.querySelector(${JSON.stringify(`${root} #target`)}),c=getComputedStyle(e);const z=parseFloat((e.closest('[data-cmp-window]')||{style:{}}).style.zoom||1);return {width:Math.round(e.getBoundingClientRect().width/z),font:c.fontFamily,color:c.color,size:c.fontSize,spacing:c.letterSpacing,pad:c.paddingTop,title:getComputedStyle(e.querySelector('h2')).fontSize,value:e.querySelector('input').value,scripts:e.querySelectorAll('script').length}})())`
  try {
    await ab('open', `http://127.0.0.1:${server.address().port}/`)
    await ab('set', 'viewport', '1200', '700')
    await ab('fill', '#f', 'typed by hand')
    // A script inside the section, put there by the page as an app's own would be: a capture carries none.
    assert.equal(await evalJson(`(() => { const s = document.createElement('script'); s.textContent = 'window.ran = 1'; document.querySelector('#target').append(s); return JSON.stringify(document.querySelectorAll('#target script').length) })()`), 1)
    const original = await evalJson(read(''))
    fs.writeFileSync(path.join(dir, 'capture.json'), await evalRaw(captureScript('#target')))
    fs.writeFileSync(path.join(dir, 'spec.json'), JSON.stringify({ options: [{ name: 'Today' }, { name: 'Roomy', swap: [['panel', 'panel roomy']] }, { name: 'One loud', edits: [{ select: '#two', swap: [['item', 'loud']] }] }] }))
    const out = await run(process.execPath, [SCRIPT, 'captured', '--repo', dir, '--capture', path.join(dir, 'capture.json'), '--spec', path.join(dir, 'spec.json'), '--out', path.join(dir, 'out.html')])
    assert.match(out, /2 stylesheet\(s\), 3 ancestor\(s\) held at their measured width, 3 option\(s\)/)
    for (const name of ['out.html', 'out-today.html', 'out-roomy.html', 'out-one-loud.html']) assert.ok(fs.existsSync(path.join(dir, name)), `${name}: the options together, and each alone for a second screen`)
    server.close()
    await ab('open', `file://${path.join(dir, 'out.html')}`)
    await ab('set', 'viewport', '1440', '900')
    const today = await evalJson(read('[data-cmp-option="Today"]'))
    // The shell is 1200 wide and a screen tall; three of them would stack far below the fold.
    const seen = await evalJson(`JSON.stringify([...document.querySelectorAll('[data-cmp-option]')].map((o) => { const r = o.getBoundingClientRect(), w = o.querySelector('[data-cmp-window]').getBoundingClientRect(), t = o.querySelector('#target').getBoundingClientRect(); return { top: Math.round(r.top), inView: r.left >= 0 && r.right <= innerWidth && r.bottom <= innerHeight, cropped: w.width < 700 && w.height < 400, whole: t.left >= w.left && t.right <= w.right && t.top >= w.top && t.bottom <= w.bottom, label: o.querySelector('[data-cmp-name]').textContent } }))`)
    assert.deepEqual(seen.map((o) => [o.inView, o.cropped, o.whole]), [[true, true, true], [true, true, true], [true, true, true]], `every option is on screen at once, cropped to the piece, the piece whole inside its window: ${JSON.stringify(seen)}`)
    assert.equal(new Set(seen.map((o) => o.top)).size, 1, 'in one row')
    assert.deepEqual(seen.map((o) => o.label.slice(0, 6)), ['1 of 3', '2 of 3', '3 of 3'])
    assert.match(seen[0].label, /^1 of 3 — Today — shown at \d\d%$/, 'scaled to fit the row, and the page says by how much')
    const colours = await evalJson(`JSON.stringify(['Today', 'One loud'].map((n) => ['#one', '#two'].map((id) => getComputedStyle(document.querySelector('[data-cmp-option="' + n + '"] ' + id)).color)))`)
    assert.deepEqual(colours, [['rgb(1, 2, 3)', 'rgb(1, 2, 3)'], ['rgb(1, 2, 3)', 'rgb(200, 0, 0)']], 'an edit changes the one element it selects, not every element of that class')
    assert.deepEqual(today, { ...original, scripts: 0 }, 'with the app stopped: the same width, inherited font and colour, the value typed into the field, and no script')
    assert.equal(original.width, 520)
    assert.equal((await evalJson(read('[data-cmp-option="Roomy"]'))).pad, '32px', 'an option is the same section with a class swapped')
    await ab('hover', '[data-cmp-option="Today"] #target')
    assert.equal(JSON.parse(await evalRaw('getComputedStyle(document.querySelector(\'[data-cmp-option="Today"] #target\')).backgroundColor')).data.result, 'rgb(255, 240, 200)', 'hover comes from the real stylesheet')
  } finally {
    server.close()
    spawnSync('agent-browser', ['close', '--session', session])
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test('the command says what a capture could not find, and what it needs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'render-cmp-'))
  fs.writeFileSync(path.join(dir, 'c.json'), JSON.stringify({ success: true, data: { result: JSON.stringify({ error: 'no element matches #nope' }) } }))
  const r = spawnSync(process.execPath, [SCRIPT, 'captured', '--repo', dir, '--capture', path.join(dir, 'c.json'), '--out', path.join(dir, 'o.html')], { encoding: 'utf8' })
  assert.equal(r.status, 2)
  assert.match(r.stderr, /the capture failed in the page: no element matches #nope/)
  assert.match(execFileSync(process.execPath, [SCRIPT, 'capture-script', '--selector', 'main > section'], { encoding: 'utf8' }), /\("main > section"\)\n$/)
})
