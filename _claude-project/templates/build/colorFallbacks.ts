import type { AtRule as CssAtRule, ChildNode, Declaration as CssDecl, Node as CssNode, PluginCreator, Rule as CssRule } from 'postcss'

/**
 * Plain-colour fallbacks for the design tokens, added to every app's CSS at build time.
 *
 * A browser that cannot read `oklch()`, `oklab()` or `color-mix()` — Safari before 16.2,
 * Chrome before 111 — drops a token written in one, and whatever it colours draws with
 * no colour at all: a dropdown goes see-through over the form behind it. For each token
 * written that way this adds the same colour in hex, inside an `@supports` block only
 * those browsers apply, so current browsers render exactly as before.
 *
 * Only rules that define tokens are read — on `:root`, `:host` or a `.dark` theme — and
 * never one inside an `@supports` block, which is Tailwind's own fallback for its
 * utilities. A `var()` inside a colour resolves the way the browser would: the rule's
 * own tokens, then the root's. A token that cannot be resolved is left alone and
 * reported as a build warning.
 *
 * A PostCSS plugin, in the app's Vite config: `css: { postcss: { plugins: [colorFallbacks()] } }`.
 */

/** Applies where the browser cannot read either newer colour form. */
const NEEDS_FALLBACK = 'not ((color: oklch(0 0 0)) and (color: color-mix(in oklab, red, red)))'
const MODERN = /\b(oklch|oklab|color-mix)\(/i
const DEFINES_TOKENS = /:root|:host|\.dark\b/

type Rgba = [number, number, number, number]

export const colorFallbacks: PluginCreator<void> = () => ({
  postcssPlugin: 'color-fallbacks',
  OnceExit(root, { result, AtRule, Rule, Declaration }) {
    const tokenRules: CssRule[] = []
    root.walkRules((rule) => {
      if (DEFINES_TOKENS.test(rule.selector) && !insideSupports(rule)) tokenRules.push(rule)
    })
    const rootTokens = new Map<string, string>()
    for (const rule of tokenRules) {
      if (isPlainRoot(rule)) for (const decl of tokenDecls(rule)) rootTokens.set(decl.prop, decl.value)
    }
    for (const rule of tokenRules) {
      const scope = new Map(rootTokens)
      for (const decl of tokenDecls(rule)) scope.set(decl.prop, decl.value)
      const fallbacks: CssDecl[] = []
      for (const decl of tokenDecls(rule)) {
        if (!MODERN.test(decl.value)) continue
        const plain = plainValue(decl.value, scope)
        if (plain === null) result.warn(`no plain-colour fallback for ${decl.prop}: ${decl.value.trim()}`, { node: decl })
        else fallbacks.push(new Declaration({ prop: decl.prop, value: plain, source: decl.source }))
      }
      if (!fallbacks.length || !rule.parent) continue
      // Each added node carries the source of the rule it copies, so source maps and
      // Vite's asset handling see where it came from.
      const block = new AtRule({ name: 'supports', params: NEEDS_FALLBACK, source: rule.source })
      const copy = new Rule({ selector: rule.selector, source: rule.source })
      copy.append(fallbacks)
      block.append(copy)
      rule.parent.insertAfter(rule, block)
    }
  },
})
colorFallbacks.postcss = true

function insideSupports(node: CssNode): boolean {
  for (let p = node.parent; p; p = p.parent) if (p.type === 'atrule' && (p as CssAtRule).name === 'supports') return true
  return false
}

/** `:root` / `:host` outside any condition — the tokens every theme starts from. */
function isPlainRoot(rule: CssRule): boolean {
  return rule.parent?.type === 'root' || (rule.parent?.type === 'atrule' && (rule.parent as CssAtRule).name === 'layer')
    ? /^(:root|:host)(\s*,\s*(:root|:host))*$/.test(rule.selector.trim())
    : false
}

function tokenDecls(rule: CssRule): CssDecl[] {
  return rule.nodes.filter((n: ChildNode): n is CssDecl => n.type === 'decl' && n.prop.startsWith('--'))
}

/** The value with every colour function in it written as hex; null when one cannot be resolved. */
export function plainValue(value: string, scope: Map<string, string>): string | null {
  let out = ''
  let i = 0
  while (i < value.length) {
    const match = /\b(oklch|oklab|color-mix)\(/gi
    match.lastIndex = i
    const found = match.exec(value)
    if (!found) {
      out += value.slice(i)
      break
    }
    const end = closingParen(value, found.index + found[0].length - 1)
    if (end < 0) return null
    const rgba = resolveColor(value.slice(found.index, end + 1), scope, 0)
    if (!rgba) return null
    out += value.slice(i, found.index) + toHex(rgba)
    i = end + 1
  }
  return out
}

function closingParen(text: string, open: number): number {
  let depth = 0
  for (let i = open; i < text.length; i++) {
    if (text[i] === '(') depth++
    else if (text[i] === ')' && --depth === 0) return i
  }
  return -1
}

/** Top-level comma-separated parts of a function's arguments. */
function args(text: string): string[] {
  const inner = text.slice(text.indexOf('(') + 1, -1)
  const parts: string[] = []
  let depth = 0
  let start = 0
  for (let i = 0; i < inner.length; i++) {
    if (inner[i] === '(') depth++
    else if (inner[i] === ')') depth--
    else if (inner[i] === ',' && depth === 0) {
      parts.push(inner.slice(start, i).trim())
      start = i + 1
    }
  }
  parts.push(inner.slice(start).trim())
  return parts
}

/** Every `var()` in a run of numbers replaced by its value. */
function substituteVars(text: string, scope: Map<string, string>, depth: number): string | null {
  if (depth > 20) return null
  const v = /var\(\s*(--[\w-]+)\s*(?:,([^()]*))?\)/
  let out = text
  for (let m = v.exec(out); m; m = v.exec(out)) {
    const value = scope.get(m[1] as string) ?? m[2]?.trim()
    if (value === undefined) return null
    const resolved = substituteVars(value, scope, depth + 1)
    if (resolved === null) return null
    out = out.replace(m[0], resolved)
  }
  return out
}

function resolveColor(text: string, scope: Map<string, string>, depth: number): Rgba | null {
  if (depth > 20) return null
  const t = text.trim()
  const lower = t.toLowerCase()
  if (lower === 'transparent') return [0, 0, 0, 0]
  if (lower === 'white') return [1, 1, 1, 1]
  if (lower === 'black') return [0, 0, 0, 1]
  const v = /^var\(\s*(--[\w-]+)\s*(?:,(.*))?\)$/s.exec(t)
  if (v) {
    const value = scope.get(v[1] as string) ?? v[2]?.trim()
    return value === undefined ? null : resolveColor(value, scope, depth + 1)
  }
  if (t.startsWith('#')) return hex(t)
  const fn = /^([a-z-]+)\(/i.exec(t)?.[1]?.toLowerCase()
  if (fn === 'color-mix') return colorMix(t, scope, depth)
  if (fn !== 'oklch' && fn !== 'oklab' && fn !== 'rgb' && fn !== 'rgba') return null
  const inner = substituteVars(t.slice(t.indexOf('(') + 1, -1), scope, depth)
  if (inner === null) return null
  const [channels = '', alphaText] = inner.includes('/') ? inner.split('/') : [inner.replaceAll(',', ' '), undefined]
  const n = channels.trim().split(/\s+/)
  if (n.length < 3) return null
  const alpha = alphaText === undefined ? (fn === 'rgba' && n[3] ? number(n[3], 1) : 1) : number(alphaText.trim(), 1)
  if (alpha === null) return null
  if (fn === 'rgb' || fn === 'rgba') {
    const [r, g, b] = n.slice(0, 3).map((x) => number(x, 255))
    return r === null || g === null || b === null || r === undefined || g === undefined || b === undefined ? null : [r / 255, g / 255, b / 255, alpha]
  }
  const l = number(n[0] as string, 1)
  if (fn === 'oklab') {
    const a = number(n[1] as string, 0.4)
    const b = number(n[2] as string, 0.4)
    return l === null || a === null || b === null ? null : [...oklabToSrgb(l, a, b), alpha]
  }
  const c = number(n[1] as string, 0.4)
  const h = number((n[2] as string).replace(/deg$/i, ''), 1)
  if (l === null || c === null || h === null) return null
  const rad = (h * Math.PI) / 180
  return [...oklabToSrgb(l, c * Math.cos(rad), c * Math.sin(rad)), alpha]
}

/** A number, a percentage of `percentOf`, or `none` (0). */
function number(text: string, percentOf: number): number | null {
  if (text === 'none') return 0
  const value = Number.parseFloat(text)
  if (Number.isNaN(value)) return null
  return text.endsWith('%') ? (value / 100) * percentOf : value
}

function hex(text: string): Rgba | null {
  let h = text.slice(1)
  if (h.length === 3 || h.length === 4) h = [...h].map((c) => c + c).join('')
  if (h.length !== 6 && h.length !== 8) return null
  const byte = (i: number) => Number.parseInt(h.slice(i, i + 2), 16) / 255
  return [byte(0), byte(2), byte(4), h.length === 8 ? byte(6) : 1]
}

/** `color-mix(in <space>, <a> [p%], <b> [q%])`, mixed with premultiplied alpha as the browser does. */
function colorMix(text: string, scope: Map<string, string>, depth: number): Rgba | null {
  const [method = '', first = '', second = ''] = args(text)
  const space = /^in\s+([\w-]+)/i.exec(method)?.[1]?.toLowerCase()
  if (space !== 'oklab' && space !== 'oklch' && space !== 'srgb') return null
  const part = (p: string) => {
    const m = /^(.*?)\s+(-?[\d.]+)%$/s.exec(p)
    return m ? { color: m[1] as string, pct: Number(m[2]) } : { color: p, pct: undefined }
  }
  const a = part(first)
  const b = part(second)
  const c1 = resolveColor(a.color, scope, depth + 1)
  const c2 = resolveColor(b.color, scope, depth + 1)
  if (!c1 || !c2) return null
  let p1 = a.pct
  let p2 = b.pct
  if (p1 === undefined && p2 === undefined) [p1, p2] = [50, 50]
  else if (p1 === undefined) p1 = 100 - (p2 as number)
  else if (p2 === undefined) p2 = 100 - p1
  const sum = (p1 as number) + (p2 as number)
  if (sum <= 0) return null
  const w1 = (p1 as number) / sum
  const w2 = (p2 as number) / sum
  const alpha = c1[3] * w1 + c2[3] * w2
  const scale = Math.min(sum, 100) / 100
  if (alpha === 0) return [0, 0, 0, 0]
  const coords = (c: Rgba) => (space === 'srgb' ? [c[0], c[1], c[2]] : srgbToOklab(c[0], c[1], c[2]))
  const [x1, y1, z1] = coords(c1) as [number, number, number]
  const [x2, y2, z2] = coords(c2) as [number, number, number]
  if (space === 'oklch') {
    const toLch = (l: number, aa: number, bb: number) => [l, Math.hypot(aa, bb), Math.atan2(bb, aa)]
    const [l1, ch1, h1] = toLch(x1, y1, z1) as [number, number, number]
    const [l2, ch2, h2] = toLch(x2, y2, z2) as [number, number, number]
    // An achromatic colour, or one fully transparent, takes the other's hue.
    const hue1 = ch1 < 1e-6 || c1[3] === 0 ? h2 : h1
    const hue2 = ch2 < 1e-6 || c2[3] === 0 ? h1 : h2
    let dh = hue2 - hue1
    if (dh > Math.PI) dh -= 2 * Math.PI
    if (dh < -Math.PI) dh += 2 * Math.PI
    const l = (l1 * c1[3] * w1 + l2 * c2[3] * w2) / alpha
    const ch = (ch1 * c1[3] * w1 + ch2 * c2[3] * w2) / alpha
    const h = hue1 + dh * w2
    return [...oklabToSrgb(l, ch * Math.cos(h), ch * Math.sin(h)), alpha * scale]
  }
  const mix = (u: number, w: number) => (u * c1[3] * w1 + w * c2[3] * w2) / alpha
  const mixed: [number, number, number] = [mix(x1, x2), mix(y1, y2), mix(z1, z2)]
  return [...(space === 'srgb' ? mixed : oklabToSrgb(...mixed)), alpha * scale]
}

const toLinear = (x: number) => (x <= 0.04045 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4)
const toGamma = (x: number) => (x <= 0.0031308 ? 12.92 * x : 1.055 * x ** (1 / 2.4) - 0.055)

function oklabToSrgb(l: number, a: number, b: number): [number, number, number] {
  const l_ = (l + 0.3963377774 * a + 0.2158037573 * b) ** 3
  const m_ = (l - 0.1055613458 * a - 0.0638541728 * b) ** 3
  const s_ = (l - 0.0894841775 * a - 1.291485548 * b) ** 3
  return [
    toGamma(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_),
    toGamma(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_),
    toGamma(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.707614701 * s_),
  ]
}

function srgbToOklab(r: number, g: number, b: number): [number, number, number] {
  const [lr, lg, lb] = [toLinear(r), toLinear(g), toLinear(b)]
  const l = Math.cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
  const m = Math.cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
  const s = Math.cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
  return [
    0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s,
  ]
}

function toHex([r, g, b, a]: Rgba): string {
  const byte = (x: number) => Math.round(Math.min(1, Math.max(0, x)) * 255).toString(16).padStart(2, '0')
  return `#${byte(r)}${byte(g)}${byte(b)}${a < 1 ? byte(a) : ''}`
}
