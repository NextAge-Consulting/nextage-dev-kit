#!/usr/bin/env node
/**
 * Proves a UI change leaves what the user sees unchanged — or lists exactly what moved.
 *
 *   node .claude/skills/design-system/scripts/compare-ui-values.mjs [--base <git-ref>]
 *
 * Compares the working tree against <git-ref> (default HEAD). Tailwind itself compiles
 * both sides with each side's own stylesheets, so every class resolves to the values
 * the browser gets. For every changed line of .ts/.tsx, the classes removed and the
 * classes added are resolved to final values — lengths in px, colours as literals —
 * and compared. Every theme variable both sides define is compared too.
 *
 * Prints:
 *   moved        styles that left one line and arrived, identical, on another — a shared
 *                look pulled into one place; not a change;
 *   changed      each difference, grouped (`font-size: 13px → 12px`), with file:line;
 *   uncompared   a changed line it could not resolve, so nothing passes unseen.
 * Exits 0 when nothing a user sees changed and everything was compared; 1 otherwise.
 * Prints what it inspected, and fails when that is nothing.
 */

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { classNames, classText } from './check-design-tokens.mjs'

const ENTRY = /^\s*@import\s+["']tailwindcss["']/m
const ROOT_PX = 16
/** A property at its CSS initial value draws the same as the property unset. */
export const INITIAL = { 'background-color': ['transparent'], 'border-color': ['currentcolor'], 'box-shadow': ['none'], opacity: ['1', '100%'] }
/** Joins the nested rules a declaration sits in. */
const SEP = ' » '

const git = (repo, args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })

// A comment line — `//`, a block comment's lines, a JSX comment — holds no classes, whatever it quotes.
export const isCommentLine = (line) => /^\s*(?:\/\/|\/\*|\*|\{\s*\/\*)/.test(line)

/** Every string literal's words on a line: the candidate classes. Tailwind ignores the rest. */
export function candidates(line) {
  if (isCommentLine(line)) return []
  const out = []
  // A JSX attribute other than className/class (`density="filter"`, `variant="outline"`)
  // holds a prop value, not classes, however much it looks like one.
  const code = line
    .replace(/\/\*.*?\*\//g, ' ')
    .replace(/\b([A-Za-z_][\w:-]*)=(["'])((?:\\.|(?!\2).)*)\2/g, (whole, attr) => (/^(?:className|class)$/.test(attr) ? whole : ' '))
    // A string in a TypeScript union (`density?: "control" | "filter"`) is a type, not a class.
    .replace(/(["'])[\w-]+\1(?=\s*\|)|(?<=\|\s*)(["'])[\w-]+\2/g, ' ')
  for (const m of code.matchAll(/(["'`])((?:\\.|(?!\1).)*)\1/g)) for (const w of m[2].split(/\s+/)) if (w && !w.includes('${')) out.push(w)
  return out
}

/** + - * / and parentheses over plain numbers; null for anything else. */
export function arithmetic(src) {
  const tokens = src.match(/\d*\.?\d+|[-+*/()]/g)
  if (!tokens || tokens.join('') !== src.replace(/\s+/g, '')) return null
  let i = 0
  const factor = () => {
    const t = tokens[i++]
    if (t === '(') {
      const v = sum()
      return tokens[i++] === ')' ? v : Number.NaN
    }
    if (t === '-') return -factor()
    return Number(t)
  }
  const product = () => {
    let v = factor()
    while (tokens[i] === '*' || tokens[i] === '/') v = tokens[i++] === '*' ? v * factor() : v / factor()
    return v
  }
  const sum = () => {
    let v = product()
    while (tokens[i] === '+' || tokens[i] === '-') v = tokens[i++] === '+' ? v + product() : v - product()
    return v
  }
  const v = sum()
  return i === tokens.length && Number.isFinite(v) ? v : null
}

/**
 * The class lists a line can apply. `cond ? "a" : "b"` applies one branch or the other, and
 * `cond && "a"` applies it or nothing, so each is a choice; every other string always
 * applies. Returns one list per combination of choices, or null past eight.
 */
export function variants(line) {
  if (isCommentLine(line)) return [[]]
  const choices = []
  let rest = line.replace(/\?\s*(["'`])((?:\\.|(?!\1).)*)\1\s*:\s*(["'`])((?:\\.|(?!\3).)*)\3/g, (_, _q, a, _q2, b) => {
    choices.push([a, b])
    return ' '
  })
  rest = rest.replace(/&&\s*(["'`])((?:\\.|(?!\1).)*)\1/g, (_, _q, a) => {
    choices.push([a, ''])
    return ' '
  })
  const always = candidates(rest)
  if (choices.length > 3) return null
  let out = [always]
  for (const [a, b] of choices) out = out.flatMap((cls) => [[...cls, ...candidates(`"${a}"`)], [...cls, ...candidates(`"${b}"`)]])
  return out
}

/**
 * The specificity a rule's own selector parts add, as one number (classes, attributes and
 * pseudo-classes; `:where()` adds nothing, `:is()`/`:not()`/`:has()` add what is inside).
 * The utility's own class is common to every rule of an element, so it is left out.
 */
export function specificity(parts) {
  let n = 0
  for (const part of parts) {
    if (part.startsWith('@')) continue
    let sel = part
    for (let i = 0; i < 5 && sel.includes(':where('); i++) sel = sel.replace(/:where\((?:[^()]|\([^()]*\))*\)/g, '')
    sel = sel.replace(/:(?:is|not|has)\(/g, '(').replace(/::[\w-]+/g, '')
    n += (sel.match(/\.[\w-]|\[|:[\w-]+|#[\w-]/g) ?? []).length
  }
  return n
}

/** A shadow layer with no offset, blur or spread draws nothing, whatever its colour. */
export function visibleShadow(value) {
  const layers = []
  let depth = 0
  let cur = ''
  for (const ch of value) {
    if (ch === '(') depth++
    else if (ch === ')') depth--
    if (ch === ',' && depth === 0) {
      layers.push(cur.trim())
      cur = ''
    } else cur += ch
  }
  layers.push(cur.trim())
  const shown = layers.filter((l) => {
    const lengths = (l.replace(/\b(?:inset|initial)\b/g, '').match(/-?[\d.]+(?:px|rem|em)?(?![\w%.(])/g) ?? []).slice(0, 4)
    return !(lengths.length >= 2 && lengths.every((x) => Number.parseFloat(x) === 0))
  })
  return shown.length ? shown.join(', ') : 'none'
}

/**
 * Every hex, rgb() and oklch() colour in a value rewritten as one canonical sRGB form, so
 * `#fff`, `rgb(255 255 255)` and `oklch(1 0 0)` compare equal. Channels round to 0.1.
 */
export function canonicalColors(value) {
  const out = (r, g, b, a = 1) => {
    const c = (x) => +(x * 255).toFixed(1)
    return `color(srgb ${c(r)} ${c(g)} ${c(b)}${a === 1 ? '' : ` / ${+a.toFixed(3)}`})`
  }
  const alpha = (x) => (x === undefined ? 1 : x.endsWith('%') ? Number.parseFloat(x) / 100 : Number(x))
  return value
    .replace(/#([0-9a-f]{3,8})\b/gi, (m, h) => {
      const hex = h.length <= 4 ? [...h].map((x) => x + x).join('') : h
      if (hex.length !== 6 && hex.length !== 8) return m
      const n = (i) => Number.parseInt(hex.slice(i, i + 2), 16) / 255
      return out(n(0), n(2), n(4), hex.length === 8 ? n(6) : 1)
    })
    .replace(/rgba?\(\s*([\d.]+%?)[\s,]+([\d.]+%?)[\s,]+([\d.]+%?)\s*(?:[,/]\s*([\d.]+%?))?\s*\)/gi, (_, r, g, b, a) => {
      // A channel is 0–255, or a percentage of it.
      const ch = (x) => (x.endsWith('%') ? Number.parseFloat(x) / 100 : Number(x) / 255)
      return out(ch(r), ch(g), ch(b), alpha(a))
    })
    .replace(/oklch\(\s*([\d.]+)(%?)\s+([\d.]+)\s+([\d.]+)(?:deg)?\s*(?:\/\s*([\d.]+%?))?\s*\)/gi, (_, l, pct, c, h, a) => {
      const L = pct ? l / 100 : Number(l)
      const hr = (Number(h) * Math.PI) / 180
      const A = c * Math.cos(hr)
      const B = c * Math.sin(hr)
      const l_ = (L + 0.3963377774 * A + 0.2158037573 * B) ** 3
      const m_ = (L - 0.1055613458 * A - 0.0638541728 * B) ** 3
      const s_ = (L - 0.0894841775 * A - 1.291485548 * B) ** 3
      const lin = [
        4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
        -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
        -0.0041960863 * l_ - 0.7034186147 * m_ + 1.707614701 * s_,
      ]
      const gamma = (x) => (x <= 0.0031308 ? 12.92 * x : 1.055 * Math.sign(x) * Math.abs(x) ** (1 / 2.4) - 0.055)
      return out(...lin.map(gamma), alpha(a))
    })
}

/** A plain length or number in px where it can be; anything else unchanged. */
export function toPx(value) {
  const v = value.trim().replace(/\s+/g, ' ')
  // A radius of infinity and one of 9999px or more both draw a pill.
  if (v === 'calc(infinity * 1px)') return '9999px'
  let m = v.match(/^(-?[\d.]+)(px|rem)$/)
  if (m) return `${+(Number(m[1]) * (m[2] === 'rem' ? ROOT_PX : 1)).toFixed(3)}px`
  m = v.match(/^calc\((.+)\)$/)
  if (m) {
    const expr = m[1].replace(/(-?[\d.]+)(px|rem)/g, (_, n, u) => `(${Number(n) * (u === 'rem' ? ROOT_PX : 1)}px)`)
    const unit = /px/.test(expr) ? 'px' : ''
    const arith = expr.replace(/px/g, '')
    const n = arithmetic(arith)
    // A length rounds to a thousandth of a px; a bare number keeps its precision for the line-height step.
    if (n !== null) return unit ? `${+n.toFixed(3)}px` : `${n}`
  }
  return v
}

/** Replace every var() with its value from `vars`, or its fallback; repeat until none is left. */
export function resolveVars(value, vars) {
  let v = value
  for (let i = 0; i < 20 && v.includes('var('); i++) {
    v = v.replace(/var\((--[\w-]+)(?:\s*,\s*((?:[^()]|\([^()]*\))*))?\)/g, (_, name, fallback) => {
      // Radix sets its `--radix-*` variables on the element at runtime; no stylesheet holds them.
      if (name.startsWith('--radix-')) return `runtime(${name})`
      const value = vars.get(name)
      // `initial` is the guaranteed-invalid value Tailwind gives an unset internal variable:
      // the fallback applies, or nothing when there is none.
      if (value === 'initial') return fallback ?? ''
      return value ?? fallback ?? `<undefined ${name}>`
    })
  }
  return v
}

/** A dark-theme block: the `.dark` class, the OS preference, or the kit's `:root:not(.light)`. */
const isDark = (part) => /\.dark\b|prefers-color-scheme:\s*dark|:root:not\(\.light\)/.test(part)

/**
 * CSS as a stream of block opens, block closes and declarations. `{`, `}` and `;` inside a
 * quoted string, a comment or a `url(…)` are ordinary characters, and a backslash escapes the
 * next character everywhere — inside a string and in an escaped selector alike. A declaration left open at a block's end still counts.
 */
export function* cssEvents(css) {
  let buf = ''
  let quote = ''
  let url = false
  for (let i = 0; i < css.length; i++) {
    const ch = css[i]
    if (quote) {
      buf += ch
      if (ch === '\\') buf += css[++i] ?? ''
      else if (ch === quote) quote = ''
      continue
    }
    if (url) {
      buf += ch
      if (ch === '\\') buf += css[++i] ?? ''
      else if (ch === ')') url = false
      continue
    }
    // A CSS escape outside a string — a quote or brace in an escaped selector (`.content-\[\'x\'\]`) — is part of the name.
    if (ch === '\\') {
      buf += ch + (css[++i] ?? '')
      continue
    }
    if (ch === '/' && css[i + 1] === '*') {
      const end = css.indexOf('*/', i + 2)
      i = end === -1 ? css.length : end + 1
      continue
    }
    if (ch === '"' || ch === "'") quote = ch
    else if (ch === '(' && /url$/i.test(buf)) url = true
    if (ch === '{') {
      yield { type: 'open', text: buf.trim() }
      buf = ''
    } else if (ch === '}') {
      if (buf.trim()) yield { type: 'decl', text: buf.trim() }
      yield { type: 'close' }
      buf = ''
    } else if (ch === ';') {
      if (buf.trim()) yield { type: 'decl', text: buf.trim() }
      buf = ''
    } else buf += ch
  }
}

/**
 * Theme variables for one mode, by the cascade: unlayered beats `@layer`, later beats
 * earlier, and in dark mode a dark block beats both. A variable defined as itself
 * (`--x: var(--x)`) is no value. `*` defaults and `@property` initial values rank lowest.
 */
export function themeVars(css, mode = 'light') {
  const vars = new Map()
  const rank = new Map()
  const put = (name, value, r) => {
    if (value === `var(${name})` || (rank.get(name) ?? -1) > r) return
    vars.set(name, value)
    rank.set(name, r)
  }
  const stack = []
  for (const e of cssEvents(css)) {
    if (e.type === 'open') stack.push(e.text)
    else if (e.type === 'close') stack.pop()
    else {
      // The nearest real selector: Tailwind nests `@supports` and `@media` inside `:root`.
      const sel = stack.findLast((x) => !x.startsWith('@')) ?? ''
      const at = stack.at(-1) ?? ''
      const dark = stack.some(isDark)
      // A value under a media query other than dark mode (`@media (pointer: coarse)`) holds
      // only there; conditionalVars compares it under its own condition.
      if (stack.some((x) => x.startsWith('@media') && !isDark(x))) continue
      const layered = stack.some((x) => x.startsWith('@layer'))
      const m = e.text.match(/^(--[\w-]+)\s*:\s*([\s\S]+)$/)
      if (m && (!dark || mode === 'dark')) {
        if (/(^|,|\s)(:root|:host|html)\b/.test(sel) || dark) put(m[1], m[2].trim(), (layered ? 1 : 2) + (dark ? 2 : 0))
        else if (/^\*/.test(sel)) put(m[1], m[2].trim(), 0)
      }
      const init = e.text.match(/^initial-value\s*:\s*([\s\S]+)$/)
      const prop = at.match(/^@property\s+(--[\w-]+)/)
      if (init && prop) put(prop[1], init[1].trim(), 0)
    }
  }
  return vars
}

/** Where a class's selector appears in a rule's selector — not as the prefix of a longer class. */
export function ownSelector(selector) {
  const at = (sel) => {
    const hits = []
    for (let i = sel.indexOf(selector); i !== -1; i = sel.indexOf(selector, i + 1)) {
      // A word character, a hyphen or an escape (`py-2\.5`) after the match means a longer class.
      if (!/[\w\\-]/.test(sel[i + selector.length] ?? '')) hits.push(i)
    }
    return hits
  }
  return {
    within: (sel) => at(sel).length > 0,
    first: (css) => at(css)[0] ?? -1,
    replaced: (sel) => {
      let out = sel
      for (const i of at(sel).reverse()) out = `${out.slice(0, i)}&${out.slice(i + selector.length)}`
      return out
    },
  }
}

/** The declarations one utility produces, as `context|property` → raw value, custom properties included. */
export function declarations(css, cls) {
  const out = new Map()
  const stack = []
  let inside = 0
  // The class as CSS writes it in a selector (`hover\:bg-x`), matched as plain text.
  const selector = `.${cls.replace(/[^\w-]/g, (c) => `\\${c}`)}`
  const own = ownSelector(selector)
  for (const e of cssEvents(css)) {
    if (e.type === 'open') {
      stack.push(e.text)
      if (own.within(e.text) || (inside && stack.length > inside)) inside ||= stack.length
    } else if (e.type === 'close') {
      if (stack.length === inside) inside = 0
      stack.pop()
    } else if (inside) {
      const m = e.text.match(/^([\w-]+)\s*:\s*([\s\S]+)$/)
      if (m) {
        const context = stack.slice(inside).map((x) => own.replaced(x)).concat(stack.slice(0, inside).filter((x) => /^@media|^@supports|^@container/.test(x)))
        out.set(`${context.join(SEP)}|${m[1]}`, m[2].trim())
      }
    }
  }
  return out
}

/** A compiler for one tree: classes → resolved declarations, cached. */
export async function compilerFor(root, entry, { inherited = new Set() } = {}) {
  const req = createRequire(path.join(root, 'package.json'))
  const tw = await import(pathToFileURL(req.resolve('@tailwindcss/node')).href)
  const full = path.join(root, entry)
  const compiled = await tw.compile(readFileSync(full, 'utf8'), { base: path.dirname(full), onDependency() {} })
  // build() is cumulative and writes only the theme variables its classes use, so the
  // variables are re-read from the latest output whenever a new class was built.
  const read = () => {
    const css = compiled.build([])
    return {
      light: themeVars(css, 'light'),
      dark: themeVars(css, 'dark'),
      conditional: conditionalVars(css),
      defaults: { light: baseDefaults(css, 'light'), dark: baseDefaults(css, 'dark') },
    }
  }
  let vars = read()
  const cache = new Map()
  const place = new Map()
  const isMix = (part) => /^@supports \(color: color-mix\(/.test(part)
  return {
    get vars() {
      return vars
    },
    /** Each property's final value, light and dark: `14px`, or `x · dark y` when they differ. */
    resolve(classes) {
      let built = false
      for (const c of classes) {
        if (!cache.has(c)) {
          cache.set(c, declarations(compiled.build([c]), c))
          built = true
        }
      }
      if (built) {
        vars = read()
        place.clear()
      }
      // Two classes setting one property: the one later in the compiled CSS wins, whatever
      // order the className lists them in.
      const css = place.size ? null : compiled.build([])
      const at = (c) => {
        if (!place.has(c)) place.set(c, ownSelector(`.${c.replace(/[^\w-]/g, (x) => `\\${x}`)}`).first(css ?? compiled.build([])))
        return place.get(c)
      }
      const ordered = [...new Set(classes)].sort((a, b) => at(a) - at(b))
      // Custom properties the element's own classes set (`--tw-shadow`) resolve first, over the theme.
      const local = { light: new Map(vars.light), dark: new Map(vars.dark) }
      // A variable a component sets on an ancestor (`[--cell-size:…]`) reaches this element
      // by inheritance at runtime: it compares as written.
      for (const name of inherited) {
        if (!local.light.has(name)) local.light.set(name, `inherited(${name})`)
        if (!local.dark.has(name)) local.dark.set(name, `inherited(${name})`)
      }
      // Each class folds on its own first: Tailwind's `@supports (color: color-mix…)` upgrade
      // replaces its own fallback. Every rule is then kept with its state (hover, a media query,
      // an attribute), its mode, its specificity and its place in the CSS.
      const rules = []
      // Custom properties by the element they are set on: '' is this element, a child
      // selector (`[&_p]:leading-relaxed`) its own. A child inherits this element's.
      const childVars = []
      for (const c of ordered) {
        const own = new Map()
        for (const [k, v] of cache.get(c)) {
          const [ctx, prop] = k.split('|')
          const parts = ctx ? ctx.split(SEP) : []
          const mode = parts.some(isDark) ? 'dark' : 'light'
          if (prop.startsWith('--')) {
            const element = parts.filter(isOtherElement).join(SEP)
            if (element) childVars.push({ element, prop, v, mode })
            else {
              local.dark.set(prop, v)
              if (mode === 'light') local.light.set(prop, v)
            }
            continue
          }
          const state = parts.filter((x) => !isDark(x) && !isMix(x))
          const slot = `${state.join(SEP)}|${prop}\u0000${mode}`
          const mix = parts.some(isMix)
          if (!own.has(slot) || mix || !own.get(slot).mix) own.set(slot, { state, prop, mode, v, mix, spec: specificity(parts) })
        }
        for (const r of own.values()) rules.push({ ...r, order: rules.length })
      }
      // In each state, every rule that matches it competes, as in the browser: a plain rule
      // also applies while hovered, a dark rule in dark mode. The more specific wins, then the later.
      const states = new Map()
      for (const r of rules) states.set(`${r.state.join(SEP)}|${r.prop}`, r)
      const scopes = new Map([['', local]])
      const scopeFor = (element) => {
        if (!scopes.has(element)) scopes.set(element, elementScope(local, childVars, element))
        return scopes.get(element)
      }
      const resolved = (mode) => {
        const out = new Map()
        for (const [key, { state, prop }] of states) {
          const win = winner(rules, state, prop, mode)
          if (!win) continue
          const scope = scopeFor(win.state.filter(isOtherElement).join(SEP))[mode]
          const raw = canonicalColors(toPx(resolveVars(win.v, scope)))
          const value = prop === 'box-shadow' ? visibleShadow(raw) : raw
          const dflt = vars.defaults[mode].get(prop)
          const atDefault = dflt !== undefined && canonicalColors(toPx(resolveVars(dflt, scope))) === value
          if (!atDefault && !INITIAL[prop]?.includes(value.toLowerCase())) out.set(key, value)
        }
        // A unitless line height is relative to the font size beside it.
        for (const [k, v] of out) {
          const [ctx, prop] = k.split('|')
          const size = out.get(`${ctx}|font-size`)
          if (prop === 'line-height' && /^[\d.]+$/.test(v) && size?.endsWith('px')) out.set(k, `${+(Number(v) * Number.parseFloat(size)).toFixed(3)}px`)
        }
        return out
      }
      const light = resolved('light')
      const dark = resolved('dark')
      const merged = new Map()
      for (const k of new Set([...light.keys(), ...dark.keys()])) {
        const l = light.get(k) ?? '(unset)'
        const d = dark.get(k) ?? '(unset)'
        merged.set(k, l === d ? l : `${l} · dark ${d}`)
      }
      return merged
    },
  }
}

/** The base tree, extracted read-only, with node_modules mirrored so its own workspaces resolve. */
export function extractBase(repo, ref) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'ui-values-'))
  // Two plain processes, no shell: git and tar both ship on Windows as well.
  const archive = path.join(mkdtempSync(path.join(os.tmpdir(), 'ui-values-tar-')), 'base.tar')
  try {
    execFileSync('git', ['-C', repo, 'archive', '--output', archive, ref])
    // From inside the destination with a relative archive: Git for Windows puts GNU tar
    // on PATH, which reads an absolute `C:\...` name as host `C`. Both live under the
    // temp directory, so they share a drive and the relative path always exists.
    execFileSync('tar', ['-xf', path.relative(dir, archive)], { cwd: dir })
  } finally {
    rmSync(path.dirname(archive), { recursive: true, force: true })
  }
  const mirror = (from, to) => {
    if (!existsSync(from)) return
    mkdirSync(to, { recursive: true })
    for (const name of readdirSync(from)) {
      const src = path.join(from, name)
      const dst = path.join(to, name)
      if (name.startsWith('@') && lstatSync(src).isDirectory()) {
        mirror(src, dst)
        continue
      }
      let target = src
      if (lstatSync(src).isSymbolicLink()) {
        const real = path.resolve(path.dirname(src), readlinkSync(src))
        if (real.startsWith(`${repo}${path.sep}`)) target = path.join(dir, path.relative(repo, real))
      }
      if (!existsSync(dst)) symlinkSync(target, dst)
    }
  }
  mirror(path.join(repo, 'node_modules'), path.join(dir, 'node_modules'))
  return dir
}

/** A line with the text inside its string literals blanked: what it is, apart from its classes. */
const shape = (line) => line.replace(/(["'`])(?:\\.|(?!\1).)*\1/g, '$1$1').trim()

/**
 * Pairs a hunk's removed and added lines: lines of the same shape match in order, and the
 * lines between two matches pair one to one when both sides hold the same number. Every
 * other line is left over — never merged with another.
 */
export function pairLines(removed, added) {
  const a = removed.map(shape)
  const b = added.map(shape)
  const lcs = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0))
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1])
  const anchors = []
  for (let i = 0, j = 0; i < a.length && j < b.length; ) {
    if (a[i] === b[j]) anchors.push([i++, j++])
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) i++
    else j++
  }
  const pairs = []
  const leftover = []
  let pi = 0
  let pj = 0
  for (const [ai, bj] of [...anchors, [a.length, b.length]]) {
    if (ai - pi === bj - pj) for (let k = 0; k < ai - pi; k++) pairs.push([pi + k, pj + k])
    else {
      for (let k = pi; k < ai; k++) leftover.push({ side: 'removed', index: k })
      for (let k = pj; k < bj; k++) leftover.push({ side: 'added', index: k })
    }
    if (ai < a.length) pairs.push([ai, bj])
    pi = ai + 1
    pj = bj + 1
  }
  return { pairs, leftover }
}

/**
 * Styles that moved rather than changed. Each line carries what it lost outright, what it
 * gained outright, and what changed value in place. A line's lost styles that another line
 * gained — same context, same value — moved there, when that line holds at least half of
 * them: one shared property is coincidence. A value that changed in place is never
 * explained by a move.
 */
export function explainMoves(diffs) {
  const overlap = (src, t) => [...src.lost].filter(([k, v]) => t.gained.get(k) === v).map(([k]) => k)
  const lost = new Map(diffs.map((d) => [d, new Map(d.lost)]))
  const gained = new Map(diffs.map((d) => [d, new Map(d.gained)]))
  const moves = new Map()
  for (const src of diffs) {
    if (!src.lost.size) continue
    let best = null
    for (const t of diffs) {
      if (t === src || !t.gained.size) continue
      const keys = overlap(src, t)
      if (keys.length && (!best || keys.length > best.keys.length)) best = { t, keys }
    }
    if (!best || best.keys.length * 2 < src.lost.size) continue
    const key = `${src.where} → ${best.t.where}`
    if (!moves.has(key)) moves.set(key, { from: src.where, to: best.t.where, styles: 0 })
    moves.get(key).styles += best.keys.length
    for (const k of best.keys) {
      lost.get(src).delete(k)
      gained.get(best.t).delete(k)
    }
  }
  const remaining = diffs
    .map((d) => ({ ...d, lost: lost.get(d), gained: gained.get(d), changed: d.changed ?? new Map() }))
    .filter((d) => d.lost.size || d.gained.size || d.changed.size)
  return { moved: [...moves.values()], remaining }
}

/**
 * The project's own defaults: properties its stylesheets set on every element (`* {…}`, as
 * Tailwind writes `@apply border-border` in a base layer). An element with no value of its
 * own takes these, so a value equal to one is the property unset. Dark blocks win in dark
 * mode, and a `@supports (color: color-mix…)` upgrade wins over its fallback.
 */
export function baseDefaults(css, mode = 'light') {
  const out = new Map()
  const stack = []
  for (const e of cssEvents(css)) {
    if (e.type === 'open') stack.push(e.text)
    else if (e.type === 'close') stack.pop()
    else {
      const sel = stack.findLast((x) => !x.startsWith('@') && !x.startsWith('&')) ?? ''
      if (!/^\*(?:\s*,|\s*$)/.test(sel)) continue
      const dark = stack.some(isDark)
      if (dark && mode !== 'dark') continue
      const m = e.text.match(/^([a-z][\w-]*)\s*:\s*([\s\S]+)$/)
      if (m) out.set(m[1], m[2].trim())
    }
  }
  return out
}

/**
 * Whether a selector part picks a different element than the one the class is on: a
 * pseudo-element (`::selection`) or a child (`& svg`, `:is(& > *)`). A pseudo-class
 * (`:hover`, `[data-state=open]`) is a state of the same element.
 */
export function isOtherElement(part) {
  if (part.startsWith('@')) return false
  if (part.includes('::')) return true
  if (/\(\s*&\s*[>~+\s]/.test(part)) return true
  let depth = 0
  let outside = ''
  for (const ch of part.replace(/^&/, '')) {
    if (ch === '(' || ch === '[') depth++
    else if (ch === ')' || ch === ']') depth--
    else if (depth === 0) outside += ch
  }
  return /[\s>~+]/.test(outside)
}

/**
 * The custom properties one element sees: this element's own, plus those a child selector
 * sets on that child. A child inherits the element's; the element never sees a child's.
 */
export function elementScope(local, childVars, element) {
  const own = { light: new Map(local.light), dark: new Map(local.dark) }
  for (const d of childVars) {
    if (d.element !== element) continue
    own.dark.set(d.prop, d.v)
    if (d.mode === 'light') own.light.set(d.prop, d.v)
  }
  return own
}

/**
 * The rule that wins one property in one state, as the browser decides: among rules for the
 * same element whose states all hold here, the more specific wins, then the later. A dark
 * rule competes only in dark mode.
 */
export function winner(rules, state, prop, mode) {
  const element = state.filter(isOtherElement).join(SEP)
  let win = null
  for (const r of rules) {
    if (r.prop !== prop || (r.mode === 'dark' && mode !== 'dark')) continue
    if (r.state.filter(isOtherElement).join(SEP) !== element || !r.state.every((x) => state.includes(x))) continue
    if (!win || r.spec > win.spec || (r.spec === win.spec && r.order > win.order)) win = r
  }
  return win
}

/**
 * Theme variables that hold only under a media query other than dark mode, keyed
 * `<media> <name>`: a touch-size override is compared under its own condition.
 */
export function conditionalVars(css) {
  const out = new Map()
  const stack = []
  for (const e of cssEvents(css)) {
    if (e.type === 'open') stack.push(e.text)
    else if (e.type === 'close') stack.pop()
    else {
      const media = stack.filter((x) => x.startsWith('@media') && !isDark(x))
      const m = e.text.match(/^(--[\w-]+)\s*:\s*([\s\S]+)$/)
      if (m && media.length && !stack.some(isDark)) out.set(`${media.join(' ')} ${m[1]}`, m[2].trim())
    }
  }
  return out
}

/**
 * A hunk's lines with their comments removed: a block comment may open on one line and
 * close several lines later, and a JSX comment sits mid-line.
 */
export function stripComments(lines) {
  let open = false
  return lines.map((line) => {
    let out = ''
    for (let i = 0; i < line.length; i++) {
      if (open) {
        if (line[i] === '*' && line[i + 1] === '/') {
          open = false
          i++
        }
      } else if (line[i] === '/' && line[i + 1] === '*') {
        open = true
        i++
      } else out += line[i]
    }
    return out
  })
}

/** Changed lines per file: hunks of removed and added lines, with the new-side line number. */
export function hunks(diff) {
  const out = []
  let file = null
  let cur = null
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ ')) file = line.slice(4).replace(/^b\//, '')
    else if (line.startsWith('@@')) {
      const m = line.match(/-(\d+)(?:,\d+)? \+(\d+)/)
      cur = { file, oldLine: Number(m[1]), line: Number(m[2]), removed: [], added: [] }
      out.push(cur)
    } else if (cur && line.startsWith('-') && !line.startsWith('---')) cur.removed.push(line.slice(1))
    else if (cur && line.startsWith('+') && !line.startsWith('+++')) cur.added.push(line.slice(1))
  }
  return out.filter((h) => h.file && h.file !== '/dev/null')
}

/** Every changed .ts/.tsx hunk since `base`. A file git does not track yet is compared too:
 * against the deleted file of the same name when there is one — a file moved, say into a
 * feature folder — so only its real edits show; otherwise as all added lines — a part just
 * extracted — so a style that left a screen for it reads as moved. */
export function changedHunks(repo, base) {
  const tracked = hunks(git(repo, ['diff', '-U0', base, '--', '*.ts', '*.tsx']))
  const deleted = git(repo, ['diff', '--name-only', '--diff-filter=D', base, '--', '*.ts', '*.tsx']).split('\n').filter(Boolean)
  const claimed = new Set()
  const untracked = []
  for (const file of git(repo, ['ls-files', '--others', '--exclude-standard', '--', '*.ts', '*.tsx']).split('\n')) {
    if (!file || file.includes('node_modules') || !existsSync(path.join(repo, file))) continue
    const text = readFileSync(path.join(repo, file), 'utf8').replace(/\r\n/g, '\n')
    const from = deleted.find((d) => !claimed.has(d) && path.basename(d) === path.basename(file))
    if (!from) {
      untracked.push({ file, oldLine: 0, line: 1, removed: [], added: text.replace(/\n$/, '').split('\n') })
      continue
    }
    claimed.add(from)
    const dir = mkdtempSync(path.join(os.tmpdir(), 'ui-values-moved-'))
    try {
      const old = path.join(dir, 'old')
      writeFileSync(old, git(repo, ['show', `${base}:${from}`]))
      // `git diff --no-index` exits 1 when the files differ; its output is the diff either way.
      const r = spawnSync('git', ['diff', '--no-index', '-U0', old, path.join(repo, file)], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
      if (r.status !== 0 && r.status !== 1) throw new Error(`git diff --no-index ${from} ${file}: ${r.stderr.trim()}`)
      for (const h of hunks(r.stdout)) untracked.push({ ...h, file, from })
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  }
  return [...tracked, ...untracked]
}

function entryFor(entries, file) {
  const scored = entries.map((e) => [e, path.dirname(e).split('/').filter((p, i) => file.split('/')[i] === p).length])
  scored.sort((a, b) => b[1] - a[1] || (a[0].startsWith('apps/') ? -1 : 1))
  return scored[0]?.[0]
}

export async function compareUiValues(repo, { base = 'HEAD' } = {}) {
  const changes = changedHunks(repo, base)
  const tracked = git(repo, ['ls-files', '--cached', '--others', '--exclude-standard', '--', '*.css']).split('\n').filter(Boolean)
  const entries = tracked.filter((f) => !f.includes('node_modules') && ENTRY.test(readFileSync(path.join(repo, f), 'utf8')))
  if (!entries.length) return { problems: ['no stylesheet imports tailwindcss — nothing to compile the classes with'], changed: [], uncompared: [], counts: null }

  const baseDir = extractBase(repo, base)
  try {
    const compilers = new Map()
    // Custom properties the changed files set with an arbitrary property (`[--cell-size:…]`),
    // on either side: an element below reads them by inheritance.
    const inherited = new Set()
    for (const file of new Set(changes.map((h) => h.file))) {
      const texts = []
      if (existsSync(path.join(repo, file))) texts.push(readFileSync(path.join(repo, file), 'utf8'))
      if (existsSync(path.join(baseDir, file))) texts.push(readFileSync(path.join(baseDir, file), 'utf8'))
      for (const t of texts) for (const m of t.matchAll(/\[(--[\w-]+):/g)) inherited.add(m[1])
    }
    // Only class lists hold classes: a className, a class helper's arguments, a variable
    // either names — never a role-name list or a prop value (check-design-tokens' classText).
    // Constants a class list names in another file count where they are declared.
    const sources = git(repo, ['ls-files', '--cached', '--others', '--exclude-standard', '--', '*.ts', '*.tsx'])
      .split('\n')
      .filter((f) => f && !f.includes('node_modules') && existsSync(path.join(repo, f)))
      .map((f) => readFileSync(path.join(repo, f), 'utf8'))
    for (const file of new Set(changes.map((h) => h.file))) if (existsSync(path.join(baseDir, file))) sources.push(readFileSync(path.join(baseDir, file), 'utf8'))
    const names = classNames(sources)
    const classLines = new Map()
    const linesOf = (dir, file) => {
      const k = `${dir}:${file}`
      if (!classLines.has(k)) classLines.set(k, existsSync(path.join(dir, file)) ? classText(readFileSync(path.join(dir, file), 'utf8'), { names }).split('\n') : null)
      return classLines.get(k)
    }

    const get = async (side, entry) => {
      const k = `${side}:${entry}`
      if (!compilers.has(k)) compilers.set(k, existsSync(path.join(side === 'new' ? repo : baseDir, entry)) ? await compilerFor(side === 'new' ? repo : baseDir, entry, { inherited }) : null)
      return compilers.get(k)
    }

    const changed = new Map()
    const uncompared = []
    const note = (what, at) => {
      if (!changed.has(what)) changed.set(what, [])
      if (!changed.get(what).includes(at)) changed.get(what).push(at)
    }

    // Theme variables both sides define.
    let varsCompared = 0
    for (const entry of entries) {
      const before = await get('old', entry)
      const after = await get('new', entry)
      if (!before || !after) continue
      for (const mode of ['light', 'dark']) {
        for (const [name, v] of before.vars[mode]) {
          if (!after.vars[mode].has(name)) continue
          varsCompared++
          const a = toPx(resolveVars(v, before.vars[mode]))
          const b = toPx(resolveVars(after.vars[mode].get(name), after.vars[mode]))
          if (a !== b) note(`${mode === 'dark' ? 'dark ' : ''}${name}: ${a} → ${b} (everything using it)`, entry)
        }
      }
      for (const [key, v] of before.vars.conditional) {
        if (!after.vars.conditional.has(key)) continue
        varsCompared++
        const a = toPx(resolveVars(v, before.vars.light))
        const b = toPx(resolveVars(after.vars.conditional.get(key), after.vars.light))
        if (a !== b) note(`${key}: ${a} → ${b} (everything using it, under that condition)`, entry)
      }
    }

    let linesCompared = 0
    const diffs = []
    for (const h of changes) {
      const at = `${h.file}:${h.line}`
      const entry = entryFor(entries, h.file)
      const before = await get('old', entry)
      const after = await get('new', entry)
      if (!before || !after) {
        uncompared.push(`${at}  — no stylesheet on one side to compile with`)
        continue
      }
      const oldLines = linesOf(baseDir, h.file)
      const newLines = linesOf(repo, h.file)
      // Lines pair by their written shape; their classes come from the class lists alone.
      const { pairs, leftover } = pairLines(stripComments(h.removed), stripComments(h.added))
      h.removed = stripComments(h.removed.map((l, i) => oldLines?.[h.oldLine - 1 + i] ?? l))
      h.added = stripComments(h.added.map((l, i) => newLines?.[h.line - 1 + i] ?? l))
      const record = (where, x, y) => {
        const lost = new Map()
        const gained = new Map()
        const changed = new Map()
        for (const k of new Set([...x.keys(), ...y.keys()])) {
          const va = x.get(k)
          const vb = y.get(k)
          const undef = `${va} ${vb}`.match(/<undefined (--[\w-]+)>/)
          if (undef) uncompared.push(`${where}  — ${k.split('|')[1]} uses ${undef[1]}, which nothing defines`)
          else if (va !== vb) {
            if (vb === undefined) lost.set(k, va)
            else if (va === undefined) gained.set(k, vb)
            else changed.set(k, [va, vb])
          }
        }
        if (lost.size || gained.size || changed.size) diffs.push({ where, lost, gained, changed })
      }
      for (const l of leftover) {
        const removed = l.side === 'removed'
        const text = removed ? h.removed[l.index] : h.added[l.index]
        if (!candidates(text).length) continue
        linesCompared++
        const where = `${h.file}:${h.line + (removed ? 0 : l.index)}`
        const vs = variants(text)
        if (!vs) {
          uncompared.push(`${where}  — more than three conditional class choices on one line; check it by hand`)
          continue
        }
        for (const c of vs) {
          if (removed) record(where, before.resolve(c), new Map())
          else record(where, new Map(), after.resolve(c))
        }
      }
      for (const [ri, ai] of pairs) {
        if (candidates(h.removed[ri]).join(' ') === candidates(h.added[ai]).join(' ')) continue
        linesCompared++
        const where = `${h.file}:${h.line + ai}`
        let vo = variants(h.removed[ri])
        let vn = variants(h.added[ai])
        // A side with no choice holds in every branch of the other.
        if (vo && vn && vo.length === 1) vo = vn.map(() => vo[0])
        if (vo && vn && vn.length === 1) vn = vo.map(() => vn[0])
        if (!vo || !vn || vo.length !== vn.length) {
          uncompared.push(`${where}  — its conditional class choices changed shape; check each branch by hand`)
          continue
        }
        for (let v = 0; v < vo.length; v++) record(where, before.resolve(vo[v]), after.resolve(vn[v]))
      }
    }

    const { moved, remaining } = explainMoves(diffs)
    const label = (k) => {
      const [ctx, prop] = k.split('|')
      return `${ctx ? `${ctx} ` : ''}${prop}`
    }
    for (const d of remaining) {
      for (const [k, v] of d.lost) note(`${label(k)}: ${v} → (unset)`, d.where)
      for (const [k, v] of d.gained) note(`${label(k)}: (unset) → ${v}`, d.where)
      for (const [k, [a, b]] of d.changed) note(`${label(k)}: ${a} → ${b}`, d.where)
    }

    return {
      problems: [],
      changed: [...changed].map(([what, at]) => ({ what, at })),
      moved,
      uncompared,
      counts: { hunks: changes.length, linesCompared, varsCompared, entries: entries.length },
    }
  } finally {
    rmSync(baseDir, { recursive: true, force: true })
  }
}

async function main() {
  const i = process.argv.indexOf('--base')
  const base = i > -1 ? process.argv[i + 1] : 'HEAD'
  const repo = git(process.cwd(), ['rev-parse', '--show-toplevel']).trim()
  const { problems, changed, moved, uncompared, counts } = await compareUiValues(repo, { base })
  if (problems.length) {
    for (const p of problems) console.error(`✗ ${p}`)
    process.exit(1)
  }
  const scanned = `compared ${counts.linesCompared} changed class lines in ${counts.hunks} hunks and ${counts.varsCompared} theme variables against ${base}, through ${counts.entries} Tailwind entry stylesheet(s)`
  if (counts.linesCompared === 0 && counts.varsCompared === 0) {
    console.error(`✗ nothing compared: ${scanned}`)
    process.exit(1)
  }
  if (moved.length) {
    console.log(`\n  Moved, values identical (${moved.length}) — glance that each source still uses its new home:`)
    for (const m of moved) console.log(`    ${m.from}  →  ${m.to}  (${m.styles} style(s))`)
  }
  if (!changed.length && !uncompared.length) {
    console.log(`✓ nothing a user sees changed: ${scanned}`)
    return
  }
  if (changed.length) {
    console.error(`\n✗ what a user sees changed (${changed.length}):`)
    for (const c of changed) console.error(`  ${c.what}  — ${c.at.length} place(s): ${c.at.slice(0, 12).join(', ')}${c.at.length > 12 ? ', …' : ''}`)
  }
  if (uncompared.length) {
    console.error(`\n✗ could not compare (${uncompared.length}):`)
    for (const u of uncompared) console.error(`  ${u}`)
  }
  console.error(`\n  (${scanned})`)
  process.exit(1)
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) await main()

