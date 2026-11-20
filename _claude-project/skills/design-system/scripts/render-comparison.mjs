#!/usr/bin/env node
/**
 * Comparison pages on the app's real CSS (references/comparison-pages.md): a static page a
 * human opens with no sign-in, holding no value anyone typed by hand.
 *
 *   node render-comparison.mjs sample --spec <spec.json> --out <page.html> [--repo <root>]
 *       A sample: each option's markup, written with the project's real classes, on the
 *       stylesheet the project's own Tailwind compiles for those classes.
 *       spec: { "entry": "apps/web/src/styles.css", "html": { "class": "…", "data-theme": "…" },
 *               "body": { "class": "…" },
 *               "options": [ { "name": "Today", "html": "<h2 class=\"type-card-title\">…</h2>",
 *                              "vars": { "--shadow-card": "…" } } ] }
 *       `entry` may be left out when one stylesheet imports tailwindcss.
 *
 *   node render-comparison.mjs capture-script --selector <css selector>
 *       Prints the script that captures one section of a running page: pipe it to
 *       `agent-browser eval --stdin --json` and save what comes back. `--selector body`
 *       captures the whole screen.
 *
 *   node render-comparison.mjs captured --capture <capture.json> --out <page.html>
 *                                       [--spec <spec.json>] [--repo <root>]
 *       A captured section: the page's real markup inside its real ancestors, each held at
 *       the width it measured, on the page's real stylesheets, with its fonts and images
 *       carried in the file. spec: { "entry": "…", "options": [ { "name": "Today" },
 *       { "name": "Stronger", "swap": [["shadow-card", "shadow-raised"]], "vars": { … } } ] }.
 *       An option's `swap` replaces whole classes everywhere; `edits` changes chosen
 *       elements only — [ { "select": "<css selector>", "swap": [[from, to]], "add": "…",
 *       "remove": "…" } ]. A class the page never shipped is compiled by the project's
 *       Tailwind and added. A section is shown cropped to the piece and what is just
 *       around it, the options in one row and numbered `1 of n`, scaled down together when
 *       they would not fit; each option is also written alone, `<page>-<option>.html`. A
 *       whole screen (`body`) is written one file per option, with nothing added to it.
 *
 * Every command prints what it wrote and each class no stylesheet styles, and exits 1 on
 * one: a class that draws nothing is a comparison that is not the real thing.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

/** A class that draws nothing by itself and so needs no rule: `group`, `peer`, and the name
 * an icon set writes on each glyph it renders (`lucide`, `lucide-star`). */
export const isMarker = (cls) => /^(?:group|peer)(?:\/|$)/.test(cls) || /^lucide(?:-|$)/.test(cls)

const ENTITIES = { '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'", '&#x27;': "'" }

/** Every class written in the markup's class attributes, as the browser reads it: an
 * attribute's `&amp;` is `&`, so `[&amp;_svg]:size-4` is the class `[&_svg]:size-4`. */
export function classesIn(html) {
  const out = new Set()
  for (const m of html.matchAll(/\sclass\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) {
    const value = (m[1] ?? m[2]).replace(/&(?:amp|lt|gt|quot|#39|#x27);/g, (e) => ENTITIES[e])
    for (const c of value.split(/\s+/)) if (c) out.add(c)
  }
  return [...out]
}

/** The markup with whole classes replaced, inside class attributes only. */
export function swapClasses(html, pairs) {
  const to = new Map(pairs)
  return html.replace(/(\sclass\s*=\s*)(?:"([^"]*)"|'([^']*)')/g, (_, head, a, b) => {
    const next = (a ?? b).split(/\s+/).filter(Boolean).flatMap((c) => (to.has(c) ? to.get(c).split(/\s+/).filter(Boolean) : [c]))
    return `${head}"${next.join(' ')}"`
  })
}

/** Every `url(…)` in a stylesheet passed through `resolve`, which returns the new target or null to keep it. */
export function rewriteUrls(css, resolve) {
  return css.replace(/url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)/g, (whole, a, b, c) => {
    const target = a ?? b ?? c
    if (!target || /^(data:|#)/.test(target)) return whole
    const next = resolve(target)
    return next ? `url("${next}")` : whole
  })
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;')
const attrs = (o = {}) => Object.entries(o).filter(([, v]) => v !== undefined && v !== null && v !== false).map(([k, v]) => ` ${k}="${esc(v)}"`).join('')
const styleOf = (vars = {}) => Object.entries(vars).map(([k, v]) => `${k}: ${v}`).join('; ')
export const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'option'

/** The frame around the options: their names and the light/dark switch, and nothing else. It
 * reads no project token, so it never borrows or lends a style. */
const FRAME = `
[data-cmp-row]{display:flex;flex-wrap:wrap;gap:32px;align-items:flex-start;padding:24px}
[data-cmp-name]{all:initial;display:block;font:600 12px/1.4 system-ui,sans-serif;color:#666;margin:0 0 8px;white-space:nowrap}`
/** The switch's own style. */
const SWITCH_STYLE = `[data-cmp-theme]{all:initial;position:fixed;right:12px;bottom:12px;font:12px system-ui,sans-serif;padding:4px 10px;border:1px solid #999;border-radius:6px;background:#fff;color:#111;cursor:pointer;z-index:2147483647}`
const SWITCH = `<button data-cmp-theme type="button" onclick="var h=document.documentElement;h.dataset.theme=h.dataset.theme==='dark'?'light':'dark';h.classList.toggle('dark',h.dataset.theme==='dark');this.textContent=h.dataset.theme">theme</button>`

/**
 * Runs in the comparison page. Applies each option's edits to the elements they select,
 * then shows each captured piece through a window cropped to the piece — whatever it draws
 * outside its own box included — and the surroundings just around it, and scales the
 * options down together when one row would not hold them. The layout inside the window is
 * untouched: the page behind it is whole.
 */
export function arrangeInPage() {
  const PAD = 24
  const FLOOR = 0.5
  const options = [...document.querySelectorAll('[data-cmp-option]')]
  const scopes = options.length ? options : [document.body]
  for (const o of scopes) {
    const spec = (o.getAttribute && o.getAttribute('data-cmp-edits')) || document.documentElement.getAttribute('data-cmp-edits')
    if (!spec || o.cmpEdited) continue
    o.cmpEdited = true
    const words = (v) => String(v || '').split(/\s+/).filter(Boolean)
    for (const e of JSON.parse(spec)) for (const n of o.querySelectorAll(e.select)) {
      for (const [from, to] of e.swap || []) if (n.classList.contains(from)) {
        n.classList.remove(from)
        n.classList.add(...words(to))
      }
      n.classList.remove(...words(e.remove))
      n.classList.add(...words(e.add))
    }
  }
  const crop = () => {
    for (const o of options) {
      const win = o.querySelector('[data-cmp-window]')
      const target = o.querySelector('[data-cmp-target]')
      if (!win || !target) continue
      const inner = win.firstElementChild
      win.style.cssText = ''
      inner.style.cssText = ''
      const base = inner.getBoundingClientRect()
      let left = Infinity
      let top = Infinity
      let right = -Infinity
      let bottom = -Infinity
      for (const n of [target, ...target.querySelectorAll('*')]) {
        const r = n.getBoundingClientRect()
        if (!r.width || !r.height) continue
        left = Math.min(left, r.left)
        top = Math.min(top, r.top)
        right = Math.max(right, r.right)
        bottom = Math.max(bottom, r.bottom)
      }
      const x = Math.max(0, left - base.left - PAD)
      const y = Math.max(0, top - base.top - PAD)
      const w = Math.min(base.right, right + PAD) - base.left - x
      const h = Math.max(Math.min(base.bottom, bottom + PAD), bottom) - base.top - y
      inner.style.cssText = `position:absolute;left:${-x}px;top:${-y}px;width:${base.width}px`
      win.style.cssText = `position:relative;overflow:hidden;width:${w}px;height:${h}px`
    }
    const wins = options.map((o) => o.querySelector('[data-cmp-window]')).filter((w) => w && w.style.width)
    if (wins.length > 1) {
      const row = document.querySelector('[data-cmp-row]')
      const style = getComputedStyle(row)
      const room = row.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight) - parseFloat(style.columnGap || 0) * (wins.length - 1)
      const need = wins.reduce((sum, w) => sum + parseFloat(w.style.width), 0)
      const tall = Math.max(...wins.map((w) => parseFloat(w.style.height)))
      const high = innerHeight - row.getBoundingClientRect().top - 72
      const zoom = Math.min(1, room / need, high / tall)
      const shown = zoom >= FLOOR ? zoom : 1
      for (const o of options) {
        // The window is scaled, never its name: the label stays readable.
        const win = o.querySelector('[data-cmp-window]')
        if (win) win.style.zoom = shown < 1 ? String(shown) : ''
        const name = o.querySelector('[data-cmp-name]')
        name.textContent = name.getAttribute('data-cmp-label') + (shown < 1 ? ` — shown at ${Math.round(shown * 100)}%` : '')
      }
    }
  }
  crop()
  addEventListener('resize', crop)
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(crop)
}
const ARRANGE = `<script>(${arrangeInPage.toString()})()</script>`

/**
 * One page: the stylesheets, then each option's markup under its number and name. An option
 * with `of: [k, n]` is one of n written alone. A single unnamed column is written bare — a
 * whole screen, with nothing added but its place in the title.
 */
export function page({ title = 'Comparison', html = {}, body = {}, css = [], links = [], columns }) {
  const bare = columns.length === 1 && !columns[0].name
  const edits = (c) => (c.edits?.length ? JSON.stringify(c.edits) : undefined)
  const label = (c, i) => (columns.length > 1 || c.of ? `${c.of?.[0] ?? i + 1} of ${c.of?.[1] ?? columns.length} — ${c.name}` : c.name)
  const cols = bare
    ? `${columns[0].html}${edits(columns[0]) ? `\n${ARRANGE}` : ''}`
    : `<div data-cmp-row>${columns.map((c, i) => `<div${attrs({ 'data-cmp-option': c.name, 'data-cmp-edits': edits(c), style: c.vars ? styleOf(c.vars) : undefined })}><p data-cmp-name data-cmp-label="${esc(label(c, i))}">${esc(label(c, i))}</p><div data-cmp-window><div>${c.html}</div></div></div>`).join('\n')}</div>\n${SWITCH}\n${ARRANGE}`
  const root = bare ? { ...html, 'data-cmp-edits': edits(columns[0]), style: [html.style, columns[0].vars ? styleOf(columns[0].vars) : ''].filter(Boolean).join('; ') || undefined } : html
  return `<!doctype html>
<html${attrs(root)}>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(columns[0].of ? `${columns[0].of[0]} of ${columns[0].of[1]} — ${columns[0].title ?? columns[0].name} · ${title}` : title)}</title>
${links.map((h) => `<link rel="stylesheet" href="${esc(h)}">`).join('\n')}
${css.map((c) => `<style>\n${c.replace(/<\/style/gi, '<\\/style')}\n</style>`).join('\n')}
${bare ? '' : `<style>${FRAME}\n${SWITCH_STYLE}\n</style>`}
</head>
<body${attrs(body)}>
${cols}
</body>
</html>
`
}

/**
 * Runs in the page. Returns the section the selector names, as markup inside a shell of each
 * of its ancestors — the ancestor's own tag and attributes, held at the width it measured —
 * with the page's stylesheets as the browser holds them. Form controls carry what they show.
 */
export function captureInPage(selector) {
  const el = document.querySelector(selector)
  if (!el) return JSON.stringify({ error: `no element matches ${selector}` })
  const copy = el.cloneNode(true)
  const live = [el, ...el.querySelectorAll('*')]
  const cloned = [copy, ...copy.querySelectorAll('*')]
  live.forEach((n, i) => {
    const c = cloned[i]
    if (n instanceof HTMLInputElement) {
      if (n.type === 'checkbox' || n.type === 'radio') n.checked ? c.setAttribute('checked', '') : c.removeAttribute('checked')
      else if (n.type !== 'password' && n.type !== 'file') c.setAttribute('value', n.value)
    } else if (n instanceof HTMLTextAreaElement) c.textContent = n.value
    else if (n instanceof HTMLOptionElement) n.selected ? c.setAttribute('selected', '') : c.removeAttribute('selected')
    if (c.tagName === 'IMG' && n.currentSrc) {
      c.setAttribute('src', n.currentSrc)
      c.removeAttribute('srcset')
    }
  })
  for (const s of copy.querySelectorAll('script')) s.remove()
  if (el !== document.body) copy.setAttribute('data-cmp-target', '')
  const attrsOf = (n) => Object.fromEntries([...n.attributes].map((a) => [a.name, a.value]))
  const whole = el === document.body
  const ancestors = []
  if (!whole) for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) ancestors.unshift({ tag: p.tagName.toLowerCase(), attrs: attrsOf(p), width: p.getBoundingClientRect().width })
  const sheets = []
  const links = []
  for (const s of document.styleSheets) {
    try {
      sheets.push({ href: s.href || document.baseURI, media: s.media.mediaText, css: [...s.cssRules].map((r) => r.cssText).join('\n') })
    } catch {
      if (s.href) links.push(s.href)
    }
  }
  return JSON.stringify({ url: location.href, base: document.baseURI, selector, whole, viewport: { width: innerWidth, height: innerHeight }, html: attrsOf(document.documentElement), body: attrsOf(document.body), ancestors, section: whole ? copy.innerHTML : copy.outerHTML, width: el.getBoundingClientRect().width, sheets, links })
}

/** The script `agent-browser eval --stdin` runs for a selector. */
export const captureScript = (selector) => `(${captureInPage.toString()})(${JSON.stringify(selector)})`

/** A captured section's markup inside its ancestors, each held at its measured width. */
export function withAncestors(capture, section = capture.section) {
  let out = section
  for (const a of [...capture.ancestors].reverse()) {
    const style = [a.attrs.style, `width: ${Math.round(a.width * 100) / 100}px`, 'max-width: none', 'box-sizing: border-box'].filter(Boolean).join('; ')
    out = `<${a.tag}${attrs({ ...a.attrs, style })}>${out}</${a.tag}>`
  }
  return out
}

/** A stylesheet with each asset it names carried inside it; one that cannot be fetched keeps its address. */
export async function inlineAssets(css, base, fetcher = fetch) {
  const wanted = new Map()
  const data = new Map()
  rewriteUrls(css, (t) => {
    try {
      const abs = new URL(t, base).href
      // A file served over the network is carried in the page; any other keeps its full address.
      if (/^https?:/.test(abs)) wanted.set(t, abs)
      else data.set(t, abs)
    } catch {}
    return null
  })
  const missed = []
  await Promise.all([...wanted].map(async ([t, abs]) => {
    try {
      const r = await fetcher(abs)
      if (!r.ok) throw new Error(String(r.status))
      const buf = Buffer.from(await r.arrayBuffer())
      data.set(t, `data:${r.headers.get('content-type') || 'application/octet-stream'};base64,${buf.toString('base64')}`)
    } catch {
      data.set(t, abs)
      missed.push(abs)
    }
  }))
  return { css: rewriteUrls(css, (t) => data.get(t) ?? null), missed }
}

/** Each `<img src>` in the markup carried inside it, by the same fetching. */
export async function inlineImages(html, base, fetcher = fetch) {
  const found = [...html.matchAll(/(<img\b[^>]*?\ssrc\s*=\s*")([^"]+)(")/g)]
  const missed = []
  const data = new Map()
  await Promise.all([...new Set(found.map((m) => m[2]))].filter((s) => !s.startsWith('data:')).map(async (src) => {
    try {
      const abs = new URL(src, base).href
      const r = await fetcher(abs)
      if (!r.ok) throw new Error(String(r.status))
      data.set(src, `data:${r.headers.get('content-type') || 'application/octet-stream'};base64,${Buffer.from(await r.arrayBuffer()).toString('base64')}`)
    } catch {
      missed.push(src)
    }
  }))
  return { html: html.replace(/(<img\b[^>]*?\ssrc\s*=\s*")([^"]+)(")/g, (w, a, src, z) => (data.has(src) ? `${a}${data.get(src)}${z}` : w)), missed }
}

/** Whether a stylesheet's text styles a class: its selector appears in it. */
export const styles = (css, cls) => css.includes(`.${cls.replace(/[^\w-]/g, (c) => `\\${c}`)}`)

/** The project's Tailwind for one entry stylesheet: `css(classes)` is the sheet it compiles for them. */
async function tailwind(repo, entry) {
  const { ENTRY } = await import('./compare-ui-values.mjs')
  const tracked = execFileSync('git', ['-C', repo, 'ls-files', '--cached', '--others', '--exclude-standard', '--', '*.css'], { encoding: 'utf8' }).split('\n').filter(Boolean)
  const entries = tracked.filter((f) => !f.includes('node_modules') && ENTRY.test(readFileSync(path.join(repo, f), 'utf8')))
  if (!entries.length) throw new Error('no stylesheet imports tailwindcss — there is no build to compile the classes with')
  if (!entry && entries.length > 1) throw new Error(`name the app's stylesheet as "entry" in the spec — one of: ${entries.join(', ')}`)
  const chosen = entry ?? entries[0]
  if (!entries.includes(chosen)) throw new Error(`"entry" ${chosen} is not a stylesheet that imports tailwindcss — one of: ${entries.join(', ')}`)
  const { createRequire } = await import('node:module')
  const tw = await import(pathToFileURL(createRequire(path.join(repo, 'package.json')).resolve('@tailwindcss/node')).href)
  const full = path.join(repo, chosen)
  // Tailwind rewrites each asset an imported stylesheet names to its place from the entry,
  // so a font a package ships is found where the package holds it.
  const compiled = await tw.compile(readFileSync(full, 'utf8'), { base: path.dirname(full), shouldRewriteUrls: true, onDependency() {} })
  const absent = new Set()
  const local = (t) => {
    if (/^[a-z]+:/i.test(t)) return null
    // A path from the site's root is served from the app's public folder.
    const file = (t.startsWith('/') ? path.join(repo, chosen.split('/src/')[0], 'public', t) : path.resolve(path.dirname(full), t)).split(/[?#]/)[0]
    if (!existsSync(file)) absent.add(t)
    return pathToFileURL(file).href
  }
  return { entry: chosen, css: (classes) => rewriteUrls(compiled.build(classes), local), absent }
}

async function main() {
  const [command, ...argv] = process.argv.slice(2)
  const opt = (k) => {
    const i = argv.indexOf(k)
    return i >= 0 ? argv[i + 1] : undefined
  }
  const repo = path.resolve(opt('--repo') ?? execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim())
  const write = (file, text) => {
    mkdirSync(path.dirname(file), { recursive: true })
    writeFileSync(file, text)
    return file
  }
  const finish = (written, unstyled, notes = [], absent = []) => {
    for (const f of written) console.log(`wrote ${f}`)
    for (const n of notes) console.log(n)
    if (absent.length) {
      console.error(`render-comparison: ${absent.length} font or image file(s) the stylesheet names were not found, so the page would not show the real thing: ${absent.slice(0, 4).join(', ')}`)
      process.exit(1)
    }
    if (unstyled.length) {
      console.error(`render-comparison: no stylesheet styles ${unstyled.length} class(es) the markup uses, so the page would not show the real thing: ${unstyled.join(', ')}`)
      process.exit(1)
    }
  }

  if (command === 'capture-script') {
    const selector = opt('--selector')
    if (!selector) throw new Error('usage: render-comparison.mjs capture-script --selector <css selector>')
    process.stdout.write(`${captureScript(selector)}\n`)
    return
  }

  const out = opt('--out')
  if (command === 'sample') {
    const spec = JSON.parse(readFileSync(path.resolve(opt('--spec') ?? ''), 'utf8'))
    if (!out || !spec.options?.length) throw new Error('usage: render-comparison.mjs sample --spec <spec.json> --out <page.html>; the spec names at least one option')
    const tw = await tailwind(repo, spec.entry)
    const classes = [...new Set([...spec.options.flatMap((o) => classesIn(o.html)), ...(spec.html?.class ?? '').split(/\s+/), ...(spec.body?.class ?? '').split(/\s+/)].filter(Boolean))]
    const css = tw.css(classes)
    const file = write(path.resolve(out), page({ title: spec.title, html: spec.html, body: spec.body, css: [css], columns: spec.options }))
    // A marker class draws nothing by itself; the page's own root classes switch a theme.
    const drawn = [...new Set(spec.options.flatMap((o) => classesIn(o.html)))].filter((c) => !isMarker(c))
    finish([file], drawn.filter((c) => !styles(css, c)), [`a sample on ${tw.entry}: ${spec.options.length} option(s), ${classes.length} class(es) compiled by the project's Tailwind`], [...tw.absent])
    return
  }

  if (command === 'captured') {
    let capture = JSON.parse(readFileSync(path.resolve(opt('--capture') ?? ''), 'utf8'))
    // `agent-browser eval --json` wraps the page's answer; the answer itself is JSON text.
    while (capture && typeof capture !== 'string' && !capture.sheets && (capture.data?.result ?? capture.result) !== undefined) capture = capture.data?.result ?? capture.result
    if (typeof capture === 'string') capture = JSON.parse(capture)
    if (capture.error) throw new Error(`the capture failed in the page: ${capture.error}`)
    if (!out || !capture.sheets) throw new Error('usage: render-comparison.mjs captured --capture <capture.json> --out <page.html> [--spec <spec.json>]')
    const spec = opt('--spec') ? JSON.parse(readFileSync(path.resolve(opt('--spec')), 'utf8')) : {}
    const options = spec.options?.length ? spec.options : [{ name: '' }]
    const missed = []
    const sheets = []
    for (const s of capture.sheets) {
      const r = await inlineAssets(s.css, s.href)
      missed.push(...r.missed)
      sheets.push(s.media ? `@media ${s.media} {\n${r.css}\n}` : r.css)
    }
    const shipped = sheets.join('\n')
    const columns = []
    for (const o of options) {
      const img = await inlineImages(swapClasses(capture.section, o.swap ?? []), capture.base)
      missed.push(...img.missed)
      columns.push({ name: o.name, vars: o.vars, edits: o.edits, html: capture.whole ? img.html : withAncestors(capture, img.html) })
    }
    // A class the page already used is one the page ships; only a class an option brings in is compiled.
    const used = new Set(classesIn(withAncestors(capture)))
    const words = (v) => String(v ?? '').split(/\s+/).filter(Boolean)
    const brought = options.flatMap((o) => [...(o.swap ?? []).flatMap(([, to]) => words(to)), ...(o.edits ?? []).flatMap((e) => [...(e.swap ?? []).flatMap(([, to]) => words(to)), ...words(e.add)])])
    const added = [...new Set(brought)].filter((c) => !used.has(c) && !styles(shipped, c))
    let extra = ''
    let entry = null
    let twAbsent = []
    if (added.length) {
      const tw = await tailwind(repo, spec.entry)
      entry = tw.entry
      extra = tw.css(added)
      twAbsent = [...tw.absent]
    }
    const unstyled = added.filter((c) => !styles(extra, c))
    const base = path.resolve(out)
    const pageOf = (cols) => page({ title: spec.title ?? capture.url, html: capture.html, body: capture.body, css: [...sheets, extra].filter(Boolean), links: capture.links, columns: cols })
    const alone = (c, i) => base.replace(/\.html$/, `-${slug(c.name) || i + 1}.html`)
    const n = columns.length
    const written = capture.whole
      ? n > 1 ? columns.map((c, i) => write(alone(c, i), pageOf([{ ...c, title: c.name, name: '', of: [i + 1, n] }]))) : [write(base, pageOf([{ ...columns[0], name: '' }]))]
      : [write(base, pageOf(columns)), ...(n > 1 ? columns.map((c, i) => write(alone(c, i), pageOf([{ ...c, of: [i + 1, n] }]))) : [])]
    finish(written, unstyled, [
      `captured from ${capture.url} (${capture.selector}) at ${capture.viewport.width}×${capture.viewport.height}: ${capture.sheets.length} stylesheet(s), ${capture.ancestors.length} ancestor(s) held at their measured width, ${options.length} option(s)`,
      ...(added.length ? [`${added.length} class(es) the page never shipped compiled by the project's Tailwind on ${entry}: ${added.join(', ')}`] : []),
      ...(capture.links.length ? [`${capture.links.length} stylesheet(s) from another site linked, not carried: the page needs the network for them`] : []),
      ...(missed.length ? [`${missed.length} font or image file(s) could not be fetched and keep their address: ${[...new Set(missed)].slice(0, 3).join(', ')}`] : []),
    ], twAbsent)
    return
  }

  throw new Error('usage: render-comparison.mjs sample | capture-script | captured — see the top of this file')
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(`render-comparison: ${e.message}`)
    process.exit(2)
  })
}
