#!/usr/bin/env node
/**
 * check-design.mjs — fails a design page that draws what the design system owns.
 *
 *   node check-design.mjs [--implement] [--config <design-system.config.mjs>] <page.dc.html> [more pages…]
 *
 * A design composes the system's components; it decides WHAT goes WHERE and
 * nothing else. Spacing inside a component, colour, type and shape belong to the
 * design system. When the system lacks something, that is a gap to raise — shown
 * to the person as tweaks, never drawn quietly into the page. This check is the
 * guard, because the written rule alone did not hold.
 *
 * FAIL (exit 1):
 *   - any inline `style` attribute — the page styles nothing inline;
 *   - a page style rule setting colour, type or shape;
 *   - a page style rule setting spacing or height inside a mounted component, or
 *     on one — arrangement (display, columns, direction, width, grid position) is
 *     the page's, how far apart things sit is not;
 *   - a bare tag rule other than body, html and the plain-link colour;
 *   - spacing, fill, border or shape classes on plain markup inside a component;
 *   - a mounted component missing a prop the design system requires on every use
 *     (the config's `requiredProps`, read with --config);
 *   - whatever the project's own page checks report: every `*.mjs` in
 *     `page-checks/` beside the --config file, each default-exporting a function
 *     called once per page with the page check API (`pageCheckApi`);
 *   - a page that mounts no component of the system and embeds no other page;
 *   - a `data-props` that is not JSON, since no gap on the page can then be read.
 *
 * Every run prints how many components, elements and style rules it inspected, and
 * how many project page checks ran.
 *
 * OPEN (listed, not failed) — decisions in front of the person:
 *   - the rules inside a `/* PREVIEW — … *\/` block, each switched by a tweak;
 *   - markup under a `<!-- DESIGN-SYSTEM CANDIDATE: … -->` comment.
 *
 * A gap's styling lives ONLY in its preview block, candidate markup included, so
 * the "Design system only" tweak turns every override off and shows the system as
 * it is. Markup under a candidate mark is exempt from nothing.
 *
 * Each gap's tweak (the `Design system` section of `data-props`) is read for its
 * state: an option starting "Undecided — " is still the person's to judge, one
 * starting "Approved — " is approved but not yet in the design system, and
 * "System as is" is rejected. The counts are reported on every run.
 *
 * --implement is the gate before building the real screens: it fails while ANY
 * gap is still in the design — undecided, or approved and not yet landed in the
 * design system — and on any preview block or candidate mark left behind.
 *
 * Page layout — the grid, the columns, breakpoints, show and hide — passes.
 * Dependency-free: a design page is well-formed by the Design type's own rules
 * (every element closed, every attribute quoted), so a stack parser is enough.
 */
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { loadConfig } from './config.mjs'

const VOID = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'source', 'track', 'wbr'])

// Properties that are always the design system's.
const SYSTEM_PROPS = /^(color|background(-color|-image)?|border(-(top|right|bottom|left))?(-color)?|border-radius|outline(-color)?|fill|stroke|accent-color|box-shadow|font(-(size|weight|family|style|variant(-numeric)?))?|line-height|letter-spacing|text-transform|text-decoration(-color)?|text-align|opacity)$/
// Spacing and size: the system's inside a component, and on one.
const SPACING_PROPS = /^(padding(-(top|right|bottom|left|inline|block))?|gap|row-gap|column-gap|height|min-height|max-height|margin(-(top|right|bottom|left|inline|block))?)$/
// Arrangement: what goes where. The page may set it anywhere, a component's inside included.
const PLACEMENT = /^(display|visibility|grid-template-(columns|rows|areas)|grid-(area|row|column)|flex-(direction|wrap|grow|shrink|basis)|flex|order|align-(items|self|content)|justify-(items|self|content)|place-(items|self|content)|width|min-width|max-width)$/
// Utility classes that draw: spacing, fills, borders, shape, fixed sizes.
const DRAWING_CLASS = /^(-?(p|px|py|pt|pr|pb|pl|m|mx|my|mt|mr|mb|ml|gap|gap-x|gap-y|space-x|space-y)-|bg-|border|rounded|h-|min-h-|size-|shadow)/
const ALLOWED_TAG_SELECTORS = /^(body|html|a:not\(\[data-slot\]\)(:hover|:focus-visible)?)$/

/** Parse well-formed markup into a tree; keep each element's line and any candidate mark. */
export function parseMarkup(src) {
  const root = { tag: '#root', attrs: {}, children: [], parent: null, line: 1 }
  const lineAt = (i) => src.slice(0, i).split('\n').length
  const re = /<!--([\s\S]*?)-->|<\/([a-zA-Z][\w-]*)\s*>|<([a-zA-Z][\w-]*)((?:\s+[^\s=>\/]+(?:\s*=\s*(?:"[^"]*"|'[^']*'))?)*)\s*(\/?)>/g
  let cur = root
  let pendingCandidate = null
  let m
  let rawUntil = null
  while ((m = re.exec(src))) {
    if (rawUntil) {
      if (m[2] && m[2].toLowerCase() === rawUntil) { cur = cur.parent; rawUntil = null }
      continue
    }
    if (m[1] !== undefined) {
      const c = m[1].trim()
      if (/^DESIGN-SYSTEM CANDIDATE/i.test(c)) pendingCandidate = { text: c, line: lineAt(m.index) }
      continue
    }
    if (m[2]) {
      let n = cur
      while (n && n.tag !== m[2].toLowerCase()) n = n.parent
      if (n && n.parent) cur = n.parent
      continue
    }
    const tag = m[3].toLowerCase()
    const attrs = {}
    const ar = /([^\s=>\/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'))?/g
    let a
    while ((a = ar.exec(m[4] || ''))) attrs[a[1].toLowerCase()] = a[2] ?? a[3] ?? ''
    const el = { tag, attrs, children: [], parent: cur, line: lineAt(m.index), candidate: pendingCandidate }
    pendingCandidate = null
    cur.children.push(el)
    if (m[5] === '/' || VOID.has(tag)) continue
    cur = el
    if (tag === 'script' || tag === 'style') rawUntil = tag
  }
  return root
}

function* walk(n) { for (const c of n.children) { yield c; yield* walk(c) } }

export const isComponent = (el) => el.tag === 'x-import'
export const componentName = (el) => el.attrs['component-from-global-scope'] || 'component'
// A provider wraps the page without drawing anything, and a shell (`AppShell`, `DialogShell`) draws
// chrome around content its caller composes: neither is a component the page sits "inside".
const isTransparent = (el) => /(Provider|Shell)$/.test(componentName(el))

/** The nearest drawing component enclosing an element, if any. */
export function enclosingComponent(el) {
  for (let p = el.parent; p; p = p.parent) if (isComponent(p) && !isTransparent(p)) return p
  return null
}
export const classesOf = (el) => (el.attrs.class || el.attrs['class-name'] || '').split(/\s+/).filter(Boolean)

/** The elements one selector lands on: those carrying its last class. */
const selectorHits = (sel, els) => {
  const classes = [...sel.matchAll(/\.([A-Za-z0-9_-]+)/g)].map((x) => x[1])
  return classes.length ? els.filter((e) => classesOf(e).includes(classes[classes.length - 1])) : []
}

/** The elements a style rule lands on, over every selector in its list. */
export function elementsFor(rule, els) {
  return [...new Set(rule.selector.split(',').flatMap((sel) => selectorHits(sel.trim(), els)))]
}

/** Split the page's <helmet> CSS into rules, marking those inside a PREVIEW block. */
export function parseCss(css, lineOffset = 0) {
  const rules = []
  let preview = null
  let i = 0
  const stack = []
  const lineAt = (k) => lineOffset + css.slice(0, k).split('\n').length - 1
  while (i < css.length) {
    while (i < css.length && /\s/.test(css[i])) i++
    if (css.startsWith('/*', i)) {
      const end = css.indexOf('*/', i + 2)
      const body = css.slice(i + 2, end < 0 ? css.length : end).trim()
      if (/^PREVIEW\b/.test(body)) preview = { text: body.split('\n')[0], line: lineAt(i) }
      else if (/^END PREVIEW\b/.test(body)) preview = null
      i = end < 0 ? css.length : end + 2
      continue
    }
    const open = css.indexOf('{', i)
    const close = css.indexOf('}', i)
    if (close >= 0 && (open < 0 || close < open)) { stack.pop(); i = close + 1; continue }
    if (open < 0) break
    const prelude = css.slice(i, open).trim()
    if (prelude.startsWith('@')) {
      if (/^@font-face/.test(prelude)) { const end = css.indexOf('}', open); i = end + 1; continue }
      stack.push(prelude); i = open + 1; continue
    }
    const end = css.indexOf('}', open)
    const decls = css.slice(open + 1, end).split(';').map((d) => d.trim()).filter(Boolean).map((d) => {
      const k = d.indexOf(':')
      return { prop: d.slice(0, k).trim().toLowerCase(), value: d.slice(k + 1).trim() }
    })
    rules.push({ selector: prelude, decls, line: lineAt(i + (css.slice(i, open).length - css.slice(i, open).trimStart().length)), preview: preview ? preview.text : null })
    i = end + 1
  }
  return rules
}

/** Every style rule on the page, from each <style> block, with its page line. */
export function pageRules(src) {
  const rules = []
  const styleRe = /<style[^>]*>([\s\S]*?)<\/style>/g
  let sm
  while ((sm = styleRe.exec(src))) {
    const lineOffset = src.slice(0, sm.index + sm[0].indexOf('>') + 1).split('\n').length
    rules.push(...parseCss(sm[1], lineOffset))
  }
  return rules
}

/** The gap tweaks in a page's data-props: { tweaks: [{ key, value }] for the "Design
 * system" section's enums, error } — `error` set when data-props is there and is not
 * JSON, because then no gap on the page can be read. */
export function readGapTweaks(src) {
  const m = src.match(/data-dc-script[^>]*data-props=(?:'([^']*)'|"([^"]*)")/)
  if (!m) return { tweaks: [], error: null }
  const raw = (m[1] ?? m[2])
    .replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&')
  let props
  try { props = JSON.parse(raw) } catch (e) { return { tweaks: [], error: e.message } }
  const tweaks = Object.entries(props)
    .filter(([, v]) => v && v.section === 'Design system' && v.editor === 'enum')
    .map(([key, v]) => ({ key, value: String(v.default ?? '') }))
  return { tweaks, error: null }
}

/** A gap tweak's state from its chosen option. */
export function gapState(value) {
  if (/^Undecided\b/.test(value)) return 'undecided'
  if (/^Approved\b/.test(value)) return 'approved'
  if (/^System as is\b/.test(value)) return 'rejected'
  return 'unlabelled'
}

/** Check one page's source; returns { fails, open, tweaks, counts }. `required` maps a mounted
 * component (`NS.DataTable`) to the props it must always be given. */
export function checkPage(src, { implement = false, required = {} } = {}) {
  const fails = []
  const open = []
  const tree = parseMarkup(src)
  const els = [...walk(tree)]

  // Props the design system requires on every use of a component.
  for (const el of els) {
    if (!isComponent(el)) continue
    for (const prop of required[componentName(el)] ?? []) {
      const kebab = prop.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)
      if (el.attrs[kebab] === undefined && el.attrs[prop.toLowerCase()] === undefined)
        fails.push({ line: el.line, msg: `${componentName(el)} is mounted without "${kebab}" — the design system requires it on every ${componentName(el).split('.').pop()}.` })
    }
  }

  // Inline styles: none.
  for (const el of els) {
    if (el.attrs.style === undefined || el.tag === 'html') continue
    const where = isComponent(el) ? componentName(el) : `<${el.tag}>`
    fails.push({ line: el.line, msg: `inline style on ${where}: "${el.attrs.style}" — the page styles nothing inline. Placement goes in a page-layout class; spacing, colour and type come from the design system.` })
  }

  // Drawing classes on plain markup inside a component.
  for (const el of els) {
    if (isComponent(el)) continue
    const comp = enclosingComponent(el)
    if (!comp) continue
    const drawing = classesOf(el).filter((c) => DRAWING_CLASS.test(c))
    if (!drawing.length) continue
    fails.push({ line: el.line, msg: `<${el.tag}> inside ${componentName(comp)} draws with "${drawing.join(' ')}" — spacing, fills and borders inside a component are the design system's. Raise it as a gap, its styling in a PREVIEW block.` })
  }
  const candidates = new Map()
  for (const el of els) if (el.candidate) candidates.set(el.candidate.line, el.candidate)
  for (const c of candidates.values()) open.push({ line: c.line, msg: c.text })

  // The page's style rules.
  const allRules = pageRules(src)
  const ruleCount = allRules.length
  const previews = new Map()
  for (const rule of allRules) {
    if (rule.preview) { if (!previews.has(rule.preview)) previews.set(rule.preview, rule.line); continue }
    for (const sel of rule.selector.split(',').map((s) => s.trim())) {
      if (ALLOWED_TAG_SELECTORS.test(sel)) continue
      const classes = [...sel.matchAll(/\.([A-Za-z0-9_-]+)/g)].map((x) => x[1])
      if (!classes.length) {
        fails.push({ line: rule.line, msg: `"${sel}" styles bare tags — the design system's base styles own them.` })
        continue
      }
      const system = rule.decls.filter((d) => SYSTEM_PROPS.test(d.prop))
      if (system.length) {
        fails.push({ line: rule.line, msg: `"${sel}" sets ${system.map((d) => d.prop).join(', ')} — colour, type and shape come from the design system. Use its classes, or raise the gap.` })
        continue
      }
      // Where do elements matching the rule's last class sit?
      const hits = selectorHits(sel, els)
      const descends = /[\s>+~]/.test(sel.replace(/\[[^\]]*\]|:[a-z-]+\([^)]*\)/g, ''))
      for (const el of hits) {
        const comp = enclosingComponent(el)
        const inside = !!comp
        const onComponent = isComponent(el) && !isTransparent(el)
        const drawn = rule.decls.filter((d) => !PLACEMENT.test(d.prop))
        if (inside && drawn.length) {
          fails.push({ line: rule.line, msg: `"${sel}" reaches inside ${componentName(comp)} (line ${el.line}) and sets ${drawn.map((d) => d.prop).join(', ')} — spacing and size inside a component are the design system's. The page arranges; it does not space.` })
          break
        }
        if (onComponent && descends) {
          fails.push({ line: rule.line, msg: `"${sel}" styles the inside of ${componentName(el)} (line ${el.line}) — pass the component a prop or class-name, or raise the gap.` })
          break
        }
        const spacing = rule.decls.filter((d) => SPACING_PROPS.test(d.prop) && !/^margin/.test(d.prop))
        if (onComponent && spacing.length) {
          fails.push({ line: rule.line, msg: `"${sel}" sets ${spacing.map((d) => d.prop).join(', ')} on ${componentName(el)} (line ${el.line}) — a component's spacing and height are its own. The page places it; it does not size its inside.` })
          break
        }
      }
    }
  }
  for (const [text, line] of previews) open.push({ line, msg: text })

  // A page that mounts no component of the system draws everything itself; a page
  // that only embeds another (`<dc-import>`, a phone preview) draws nothing.
  const components = els.filter(isComponent)
  if (!components.length && !els.some((el) => el.tag === 'dc-import'))
    fails.push({ line: 0, msg: 'the page mounts no design-system component — a design composes the system\'s components; one that mounts none is drawing the whole page itself.' })

  const read = readGapTweaks(src)
  if (read.error) fails.push({ line: 0, msg: `data-props is not JSON (${read.error}) — no gap on this page can be read, so none can be counted or gated.` })
  const tweaks = read.tweaks.map((t) => ({ ...t, state: gapState(t.value) }))
  for (const t of tweaks) {
    if (t.state === 'unlabelled') fails.push({ line: 0, msg: `tweak "${t.key}" is set to "${t.value}" — every gap option starts "Undecided — ", "Approved — " or is "System as is".` })
  }
  if (implement) {
    for (const t of tweaks) {
      if (t.state === 'undecided') fails.push({ line: 0, msg: `gap "${t.key}" is undecided ("${t.value}") — every gap is decided before implement.` })
      if (t.state === 'approved') fails.push({ line: 0, msg: `gap "${t.key}" is approved but not landed ("${t.value}") — put it in the design system, publish and apply it, and remove its tweak and preview.` })
      if (t.state === 'rejected') fails.push({ line: 0, msg: `gap "${t.key}" is rejected but still in the design — remove its tweak, preview and candidate markup.` })
    }
    for (const o of open) fails.push({ line: o.line, msg: `still open at implement: ${o.msg}` })
  }
  return { fails, open, tweaks, counts: { elements: els.length, components: components.length, rules: ruleCount } }
}

/** The config's `requiredProps`, keyed by the name a page mounts: `NS.DataTable`. */
export function requiredFrom(config) {
  const out = {}
  for (const [name, props] of Object.entries(config.requiredProps ?? {})) out[`${config.namespace}.${name}`] = props
  return out
}

/** The project's page checks: every `*.mjs` in `dir`, sorted. A file whose default export is
 * not a function is a problem, never silently skipped. */
export async function loadPageChecks(dir) {
  const checks = []
  const problems = []
  if (!fs.existsSync(dir)) return { checks, problems }
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.mjs')).sort()) {
    const mod = await import(pathToFileURL(path.join(dir, file)).href)
    if (typeof mod.default === 'function') checks.push({ file, run: mod.default })
    else problems.push(`${path.join(dir, file)} — a page check default-exports a function given the page check API`)
  }
  return { checks, problems }
}

/** What a page check is given for one page. `add(line, what, why)` reports a FAIL. Style
 * rules inside a PREVIEW block are left out: a gap's styling is the person's decision,
 * listed open, and --implement fails while any is left. */
export function pageCheckApi(src, { page, config, add }) {
  const elements = [...walk(parseMarkup(src))]
  return {
    page,
    elements,
    rules: pageRules(src).filter((r) => !r.preview),
    config,
    elementsFor: (rule) => elementsFor(rule, elements),
    isComponent,
    componentName,
    enclosingComponent,
    classesOf,
    add,
  }
}

/** Run every page check on one page; returns its fails, each naming the check. */
export async function runPageChecks(src, checks, { page, config } = {}) {
  const fails = []
  for (const { file, run } of checks) {
    const add = (line, what, why) => fails.push({ line, msg: `${what} — ${why} (project check ${file})` })
    await run(pageCheckApi(src, { page, config, add }))
  }
  return fails
}

async function main(args) {
  const implement = args.includes('--implement')
  const at = args.indexOf('--config')
  const configPath = at >= 0 ? args[at + 1] : null
  const files = args.filter((a, i) => a !== '--implement' && (at < 0 || (i !== at && i !== at + 1)))
  if (!files.length || (at >= 0 && !configPath)) {
    console.error('usage: check-design.mjs [--implement] [--config <design-system.config.mjs>] <page.dc.html> [more pages…]')
    process.exit(2)
  }
  const config = configPath ? (await loadConfig(configPath, { tool: 'check-design.mjs' })).CONFIG : null
  const required = config ? requiredFrom(config) : {}
  if (!configPath) console.log('(no --config: props the design system requires and the project\'s page checks are not checked)')
  const { checks, problems } = configPath ? await loadPageChecks(path.join(path.dirname(configPath), 'page-checks')) : { checks: [], problems: [] }
  for (const p of problems) console.log(`  FAIL ${p}`)
  let failed = problems.length
  const total = { elements: 0, components: 0, rules: 0 }
  for (const f of files) {
    const src = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n')
    const { fails, open, tweaks, counts } = checkPage(src, { implement, required })
    fails.push(...(await runPageChecks(src, checks, { page: f, config })))
    const name = path.basename(f)
    const count = (st) => tweaks.filter((t) => t.state === st).length
    for (const k of Object.keys(total)) total[k] += counts[k]
    console.log(`${name}: ${fails.length} fail, ${open.length} open · ${counts.components} components, ${counts.elements} elements, ${counts.rules} style rules · gaps: ${count('undecided')} undecided, ${count('approved')} approved, ${count('rejected')} rejected`)
    for (const t of tweaks) console.log(`  GAP  ${t.key}: ${t.value}`)
    for (const x of fails.sort((a, b) => a.line - b.line)) console.log(`  FAIL ${name}:${x.line}  ${x.msg}`)
    for (const x of open.sort((a, b) => a.line - b.line)) console.log(`  OPEN ${name}:${x.line}  ${x.msg}`)
    failed += fails.length
  }
  console.log(`\ncheck-design: ${files.length} page(s) — ${total.components} components, ${total.elements} elements, ${total.rules} style rules inspected; ${checks.length} project checks`)
  if (failed) {
    console.log(implement
      ? `${failed} failure(s). Implement waits until every gap is decided and landed in the design system.`
      : `${failed} failure(s). The page is drawing what the design system owns — each is a gap to raise, not a value to tune.`)
    process.exit(1)
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) main(process.argv.slice(2))
