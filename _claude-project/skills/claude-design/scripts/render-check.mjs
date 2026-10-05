#!/usr/bin/env node
/* Renders every component preview the way the design system page does — React 18
 * first, then bundle.css and bundle.js — and fails on a script error, a React
 * error, a preview that draws nothing anywhere on the page (overlays portal
 * outside the preview's root), an overlay preview whose overlay does not open,
 * or an overlay that opens detached from its trigger. Each preview also renders
 * the way a Design canvas mounts components: children always handed over as an
 * array, and every mounted component wrapped in the editor's display:contents
 * host element — and fails when that render differs from the plain one by a single
 * pixel. A component whose look depends on its siblings or its position (an
 * adjacent-sibling selector, a :first-child or :last-child rule) loses it inside those
 * wrappers without any error: a divider, a row line, a rounded corner quietly goes. A
 * design would then show something the app does not, so it fails here, before any
 * design sees it. Animations and transitions are frozen, so a frame caught mid-spin
 * is never a difference. A preview showing a popup trigger closed is clicked open
 * with a real pointer in the canvas render, and fails when nothing opens or the
 * popup opens away from its trigger. Fails, too, when the config lists no
 * component. Run after build.mjs:
 *
 *   node .claude/skills/claude-design/scripts/render-check.mjs <path/to/design-system.config.mjs>
 *
 * Drives agent-browser's Chromium, headless, in a few named sessions side by side,
 * each rendering its share of the components. A render waits for what the page needs
 * — fonts loaded, two frames painted, an overlay preview's overlay open — never a
 * fixed time. Writes light, dark and canvas screenshots of each preview to
 * <out>/render/ for review. */

import { execFile, execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { promisify } from 'node:util'
import zlib from 'node:zlib'
import { loadConfig } from './config.mjs'

const { CONFIG, REPO, PKG } = await loadConfig(process.argv[2], { tool: 'render-check.mjs' })
const OUT = path.join(PKG, CONFIG.out)
const COMPONENTS_DIR = path.join(OUT, 'project/components')
const RENDER = path.join(OUT, 'render')
const SESSION = `${path.basename(REPO)}-design-system`
// The React the build carries in components/lib — exactly what the page loads.
const REACT = '../project/components/lib/react.production.min.js'
const REACT_DOM = '../project/components/lib/react-dom.production.min.js'

if (!fs.existsSync(path.join(COMPONENTS_DIR, 'bundle.js'))) {
  console.error('render-check: no build found — run build.mjs first')
  process.exit(1)
}

fs.rmSync(RENDER, { recursive: true, force: true })
fs.mkdirSync(RENDER, { recursive: true })

// On Windows npm installs agent-browser as a `.cmd` shim, which only a shell can
// start; each argument is quoted for cmd.exe, and the probe travels as base64 so
// nothing inside it needs quoting at all.
const WINDOWS = process.platform === 'win32'
const LANES = Math.min(4, CONFIG.components.length || 1)
const sessionOf = (lane) => `${SESSION}-${lane}`
const argv = (session, args) => (WINDOWS ? ['--session', session, ...args].map((a) => `"${a}"`) : ['--session', session, ...args])
const CMD = WINDOWS ? 'agent-browser.cmd' : 'agent-browser'
const run = promisify(execFile)
const browser = async (session, args) => (await run(CMD, argv(session, args), { encoding: 'utf8', shell: WINDOWS })).stdout
// The call that starts a session's browser daemon runs with no pipes attached. On
// Windows a child process inherits every inheritable handle its parent holds
// (rust-lang/rust#161158, #54760), so the daemon that first call starts keeps this
// script's stdout pipe open for as long as it runs, and the call never sees EOF.
// Every later call reaches the running daemon and captures output as usual.
const launch = (session) => execFileSync(CMD, argv(session, ['open', 'about:blank']), { stdio: 'ignore', shell: WINDOWS })
const failures = []
const components = CONFIG.components
if (!components.length) {
  console.error('render-check: the config lists no components — nothing to render means nothing was checked')
  process.exit(1)
}

const PROBE = `JSON.stringify({
  errors: window.__errors,
  drawn: [].filter.call(document.body.querySelectorAll("*"), function (el) { var r = el.getBoundingClientRect(); return r.width > 8 && r.height > 8 && el.id !== "root" }).length,
  overlay: [].filter.call(document.querySelectorAll("[data-radix-popper-content-wrapper], [role=dialog], [role=tooltip], [role=menu], [role=listbox]"), function (el) { var r = el.getBoundingClientRect(); return r.width > 8 && r.height > 8 }).length,
  detached: (function () {
    var o = document.querySelector("[data-radix-popper-content-wrapper]");
    var t = document.querySelector("[aria-expanded=true], [data-state=delayed-open], [data-state=instant-open]");
    if (!o || !t) return false;
    var a = o.firstElementChild.getBoundingClientRect(), b = t.getBoundingClientRect();
    if (b.width === 0) return true;
    var gap = Math.min(Math.abs(a.top - b.bottom), Math.abs(b.top - a.bottom));
    return gap > 24 || a.right < b.left || a.left > b.right;
  })()
})`

// The probe, once the page is ready: fonts loaded, two frames painted, and — when an
// overlay is expected — the overlay open, or 1.5s gone without it. One call where a
// fixed wait and a probe took two, and no longer than the page needs.
const settled = (expectOverlay) => `(async function () {
  await document.fonts.ready;
  await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r) }) });
  if (${expectOverlay ? 'true' : 'false'}) {
    var until = Date.now() + 1500;
    while (Date.now() < until && !document.querySelector("[data-radix-popper-content-wrapper], [role=dialog], [role=tooltip], [role=menu], [role=listbox]"))
      await new Promise(function (r) { setTimeout(r, 25) });
    await new Promise(function (r) { requestAnimationFrame(function () { requestAnimationFrame(r) }) });
  }
  return ${PROBE};
})()`
const evalB64 = (session, js) => browser(session, ['eval', '-b', Buffer.from(js).toString('base64')])

// The first closed popup trigger in a preview, marked so the check can click it with a
// real pointer: a Radix menu opens on pointerdown, which a scripted .click() never sends.
const MARK_TRIGGER = `(function () {
  var t = document.querySelector('button[aria-haspopup]:not([aria-expanded=true])');
  if (!t) return 'none';
  t.setAttribute('data-rc-trigger', '');
  return 'marked';
})()`

// A screenshot's pixels, for comparing two renders. Chromium writes 8-bit RGB or RGBA,
// non-interlaced; anything else is a failure to read, never a silent pass.
function decodePng(file) {
  const b = fs.readFileSync(file)
  const idat = []
  let p = 8, w, h, depth, type
  while (p < b.length) {
    const len = b.readUInt32BE(p)
    const kind = b.toString('ascii', p + 4, p + 8)
    const d = b.subarray(p + 8, p + 8 + len)
    if (kind === 'IHDR') { w = d.readUInt32BE(0); h = d.readUInt32BE(4); depth = d[8]; type = d[9] }
    if (kind === 'IDAT') idat.push(d)
    p += 12 + len
  }
  const ch = { 2: 3, 6: 4 }[type]
  if (depth !== 8 || !ch) throw new Error(`${path.basename(file)}: unsupported PNG (depth ${depth}, colour type ${type})`)
  const raw = zlib.inflateSync(Buffer.concat(idat))
  const stride = w * ch
  const px = Buffer.alloc(h * stride)
  let prev = Buffer.alloc(stride)
  for (let y = 0; y < h; y++) {
    const filter = raw[y * (stride + 1)]
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1))
    const cur = px.subarray(y * stride, (y + 1) * stride)
    for (let x = 0; x < stride; x++) {
      const a = x >= ch ? cur[x - ch] : 0, up = prev[x], c = x >= ch ? prev[x - ch] : 0
      let v = line[x]
      if (filter === 1) v += a
      else if (filter === 2) v += up
      else if (filter === 3) v += (a + up) >> 1
      else if (filter === 4) {
        const e = a + up - c, pa = Math.abs(e - a), pb = Math.abs(e - up), pc = Math.abs(e - c)
        v += pa <= pb && pa <= pc ? a : pb <= pc ? up : c
      }
      cur[x] = v & 255
    }
    prev = cur
  }
  return { w, h, ch, px }
}

// The pixels two screenshots disagree on. Colour channels only; alpha is always opaque.
function pixelsDiffering(fileA, fileB) {
  const A = decodePng(fileA), B = decodePng(fileB)
  if (A.w !== B.w || A.h !== B.h) return A.w * A.h
  let n = 0
  for (let i = 0; i < A.w * A.h; i++) {
    for (let k = 0; k < 3; k++) {
      if (A.px[i * A.ch + k] !== B.px[i * B.ch + k]) { n++; break }
    }
  }
  return n
}

// How a canvas hands components their children, and the host it wraps them in.
const CANVAS_H =
  'h = function (t, p) { var k = [].slice.call(arguments, 2); var el = k.length ? React.createElement(t, Object.assign({}, p, { children: k })) : React.createElement(t, p); return typeof t === "string" ? el : React.createElement("div", { className: "sc-host-x", "data-dc-tpl": "t", style: { display: "contents" }, key: p && p.key }, el) }'

/** Render one component in light, dark and canvas mounting; returns its failures. */
async function renderComponent(session, c) {
  const found = []
  const preview = fs.readFileSync(path.join(COMPONENTS_DIR, c.name, 'preview.html'), 'utf8')
  const body = /<body>([\s\S]*)<\/body>/.exec(preview)[1]
  const style = /<style>([\s\S]*?)<\/style>/.exec(preview)?.[1] ?? ''
  for (const mode of ['light', 'dark', 'canvas']) {
    const harness = path.join(RENDER, `${c.name}.${mode}.html`)
    const mount = mode === 'canvas' ? body.replace('h = React.createElement', CANVAS_H) : body
    // A local harness page around this repository's own build output, opened
    // headless by this check and never served — no outside input reaches it.
    fs.writeFileSync(
      harness, // nosemgrep: javascript.lang.security.audit.unknown-value-with-script-tag.unknown-value-with-script-tag
      `<!doctype html><html data-theme="${mode === 'dark' ? 'dark' : 'light'}"><head><meta charset="utf-8">
<script>window.__errors=[];addEventListener('error',function(e){__errors.push(String(e.message))});var ce=console.error;console.error=function(){__errors.push([].slice.call(arguments).join(' '));ce.apply(console,arguments)};</script>
<link rel="stylesheet" href="../project/components/bundle.css"><style>${style}</style>
<style>*,*::before,*::after{animation:none!important;transition:none!important;caret-color:transparent!important}</style>
<script src="${REACT}"></script><script src="${REACT_DOM}"></script>
<script src="../project/components/bundle.js"></script>
</head><body>${mount}</body></html>`,
    )
    await browser(session, ['open', pathToFileURL(harness).href])
    const report = JSON.parse(JSON.parse(await evalB64(session, settled(c.cardMode === 'overlay'))))
    await browser(session, ['screenshot', path.join(RENDER, `${c.name}.${mode}.png`)])
    if (report.errors.length) found.push(`${c.name} (${mode}): ${report.errors[0].slice(0, 200)}`)
    else if (report.drawn === 0) found.push(`${c.name} (${mode}): drew nothing`)
    else if (c.cardMode === 'overlay' && report.overlay === 0) found.push(`${c.name} (${mode}): the overlay did not open`)
    else if (report.detached) found.push(`${c.name} (${mode}): the overlay is not attached to its trigger`)
    else if (mode === 'canvas' && c.cardMode !== 'overlay') {
      // A preview that shows its trigger closed: open it as a person would, and fail
      // when nothing opens or it opens away from the trigger. A trigger inside a
      // component, cloned by Radix's `asChild`, only shows that defect once clicked.
      if ((await evalB64(session, MARK_TRIGGER)).includes('marked')) {
        await browser(session, ['click', '[data-rc-trigger]'])
        const opened = JSON.parse(JSON.parse(await evalB64(session, settled(true))))
        if (opened.errors.length) found.push(`${c.name} (opened): ${opened.errors[0].slice(0, 200)}`)
        else if (opened.overlay === 0) found.push(`${c.name} (opened): clicking its trigger opened nothing`)
        else if (opened.detached) found.push(`${c.name} (opened): it opens away from its trigger`)
      }
    }
  }
  const differing = pixelsDiffering(path.join(RENDER, `${c.name}.light.png`), path.join(RENDER, `${c.name}.canvas.png`))
  if (differing)
    found.push(`${c.name} (canvas): ${differing} pixels differ between the plain render and the one inside the design tool's wrappers — part of its look depends on its siblings or position, which a design changes. Compare ${c.name}.light.png with ${c.name}.canvas.png in render/`)
  return found
}

const launched = []
try {
  for (let lane = 0; lane < LANES; lane++) {
    try {
      launch(sessionOf(lane))
      launched.push(sessionOf(lane))
    } catch (e) {
      console.error(`render-check: could not start agent-browser (${e.code ?? e.status ?? 'failed'}) — it must be installed on this machine; see rules/integrations/agent-browser.md`)
      process.exit(1)
    }
  }
  // Each lane takes the next component not yet started; results keep the config's order.
  const results = new Array(components.length)
  let next = 0
  await Promise.all(
    launched.map(async (session) => {
      await browser(session, ['set', 'viewport', '1200', '800'])
      while (next < components.length) {
        const i = next++
        results[i] = await renderComponent(session, components[i])
      }
    }),
  )
  for (const r of results) failures.push(...r)
} finally {
  for (const session of launched) {
    try {
      execFileSync(CMD, argv(session, ['close']), { stdio: 'ignore', shell: WINDOWS })
    } catch {}
  }
}

if (failures.length) {
  console.error(`render-check: ${failures.length} failure(s)\n`)
  for (const f of failures) console.error(`  ✗ ${f}`)
  process.exit(1)
}
console.log(`render-check: ${components.length} components render in light, dark and canvas mounting — screenshots in ${path.relative(process.cwd(), RENDER)}`)
