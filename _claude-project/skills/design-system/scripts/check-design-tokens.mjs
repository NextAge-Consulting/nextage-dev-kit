#!/usr/bin/env node
/**
 * Every design token family is set by a ROLE, and the tokens underneath resolve.
 *
 *   node .claude/skills/design-system/scripts/check-design-tokens.mjs   (npm run lint:tokens)
 *
 * A raw `text-sm` or `rounded-[6px]` is valid Tailwind and valid TSX, so no
 * ordinary linter objects — and that is how one thing ends up at four sizes across
 * four screens. The allowlists are inverted on purpose: anything not known GOOD is a
 * finding, and the good sets are read live from the CSS, so a new role is allowed
 * the moment it is defined and a deleted one fails the moment it is gone.
 *
 * The project's values come from .claude/sync-substitutions.json:
 *   DESIGN_UI_PACKAGE          the UI package, from the repository root
 *   DESIGN_TOKEN_FILES         its token stylesheets (light and dark blocks), from the package
 *   DESIGN_TYPE_FILE           its type-role stylesheet, from the package
 *   DESIGN_STYLES_FILE         its Tailwind entry (theme, utilities, aliases), from the package
 *   DESIGN_SOURCE_DIRS         the source trees whose .ts/.tsx are checked, from the root
 *   DESIGN_VENDORED_DIR        the vendored atoms (shadcn), from the root; empty for none
 *   DESIGN_VENDORED_RESTYLED   "true" when those atoms are restyled onto the roles at
 *                              source, so every class rule applies to them; empty
 *                              exempts them from the class rules, arbitrary spacing aside
 *   DESIGN_FIELD_LOOK_CLASSES  the classes that paint a text field's look
 *   DESIGN_EXEMPT_COMPONENTS   components a call site may style: headless primitives
 *                              with no look of their own, and glyphs
 *
 * Checks, each naming file and line:
 *   classes    type, radius, weight, shadow, spacing, line width, `dark:`, bare scroll
 *              areas — off a role, arbitrary, or off the 4px grid;
 *   call sites a component imported from the project's component trees placed, never
 *              repainted or sized by magnitude (`size="sm"`); a raw <input>/<textarea>
 *              painting the field look;
 *   names      every role — type, radius, weight, shadow, spacing, leading, tracking —
 *              named for what it is, never a size (`md`, `2xl`, `semibold`);
 *   tokens     every var() resolves, every token is reached, and the dark theme
 *              redefines every colour other tokens build on and adds none of its own;
 *   design.md  every token reference and quoted class exists, every type and radius
 *              role has its frontmatter entry, every stated pixel value is on the grid;
 *   generated  with a claude-design config, the safelist and class-merge files are
 *              current and imported;
 *   project    every `*.mjs` in <DESIGN_UI_PACKAGE>/design-system/checks/ — the
 *              project's own checks, each a default-exported function given the API
 *              below.
 *
 * Prints what it inspected, and fails when that is nothing.
 */

import { existsSync, globSync, readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseTokenBlocks } from '../../claude-design/scripts/resolve.mjs'

export const KEYS = [
  'DESIGN_UI_PACKAGE', 'DESIGN_TOKEN_FILES', 'DESIGN_TYPE_FILE', 'DESIGN_STYLES_FILE', 'DESIGN_SOURCE_DIRS',
  'DESIGN_VENDORED_DIR', 'DESIGN_VENDORED_RESTYLED', 'DESIGN_FIELD_LOOK_CLASSES', 'DESIGN_EXEMPT_COMPONENTS',
]
const REQUIRED = new Set(['DESIGN_UI_PACKAGE', 'DESIGN_TOKEN_FILES', 'DESIGN_SOURCE_DIRS'])

/** `text-*` utilities that are not typography: alignment, wrapping, keywords. */
const NON_TYPE = new Set([
  'text-left', 'text-center', 'text-right', 'text-justify', 'text-start', 'text-end',
  'text-balance', 'text-pretty', 'text-wrap', 'text-nowrap', 'text-ellipsis', 'text-clip',
  'text-current', 'text-inherit', 'text-transparent',
])
/** CSS property names and tailwind-merge group ids, which appear as strings. */
const NOT_CLASSES = new Set([
  'font-size', 'font-family', 'font-weight', 'font-style', 'font-variant',
  'font-stretch', 'font-feature-settings', 'font-variant-numeric',
  'text-transform', 'text-decoration', 'text-anchor',
])
const SPACE_PROPS = 'p|px|py|pt|pb|pl|pr|ps|pe|m|mx|my|mt|mb|ml|mr|ms|me|gap|gap-x|gap-y|space-x|space-y'
const CORNER = 't|r|b|l|tl|tr|br|bl|s|e|ss|se|es|ee'

/** What a call site may write on a component: where it sits, never how it looks. */
const PLACEMENT = new RegExp(
  '^-?(?:' +
    [
      'm[xytrblse]?-.+', // margin
      // The box's extent: the parent decides how wide a field is, and may bound or
      // stretch its height. A fixed height is NOT here, and neither is `size-*` —
      // how tall a control is belongs to the control.
      '(?:min-|max-)?w-.+', '(?:min-|max-)h-.+', 'h-(?:full|auto|screen|fit|min|max|dvh|svh|lvh)',
      'flex-(?:\\d+|\\[[^\\]]+\\]|1|auto|initial|none)', 'grow(?:-0)?', 'shrink(?:-0)?', 'basis-.+',
      'order-.+', 'self-.+', 'justify-self-.+', 'place-self-.+', 'col-.+', 'row-.+',
      'relative', 'absolute', 'sticky', 'fixed', 'inset-.+', 'top-.+', 'right-.+', 'bottom-.+', 'left-.+', 'z-.+',
      'block', 'inline-block', 'inline', 'hidden', 'sr-only',
      'text-(?:left|center|right|start|end)', // where the text sits in the box
      'truncate', 'whitespace-.+', 'break-.+', // how the text fits the box
    ].join('|') +
    ')$',
)
const NOT_TEXT = /\stype="(?:radio|checkbox|file|hidden|range|color)"/
/** A role name that is a size, not a thing: `md`, `2xl`, `base`, `semibold`, `tight`. */
const MAGNITUDE_NAME = /^(?:\d*x[sl]|sm|md|lg|base|thin|extralight|light|normal|medium|semibold|bold|extrabold|black|tighter|tight|snug|relaxed|loose|wide|wider|widest)$/
/** A size prop naming a magnitude (`sm`, `lg`, `icon-sm`), not a role. */
const MAGNITUDE_SIZE = /\ssize=(?:"((?:icon-)?(?:\d?xs|sm|md|lg|\d?xl))"|\{\s*["'`]((?:icon-)?(?:\d?xs|sm|md|lg|\d?xl))["'`]\s*\})/

const posix = (p) => p.split(path.sep).join('/').replaceAll('\\', '/')
const isComment = (line) => /^\s*(\/\/|\*|\/\*)/.test(line)
const DECL = /^\s*(--[A-Za-z0-9-]+)\s*:\s*(.+?);(?:\s*\/\*.*)?\s*$/

export const NOT_SET_UP = 'design token checks do not apply: this project has no UI package (DESIGN_UI_PACKAGE is intentionally empty)'

/** The design keys from .claude/sync-substitutions.json, and a problem per missing one;
 * `notApplicable` set when the project has deliberately not set its design system up. */
export function readKeys(repo) {
  const file = path.join(repo, '.claude/sync-substitutions.json')
  if (!existsSync(file)) return { keys: null, problems: ['.claude/sync-substitutions.json not found — the design keys live there'] }
  const subs = JSON.parse(readFileSync(file, 'utf8'))
  // DESIGN_UI_PACKAGE decides whether the check applies at all, by the three
  // substitution states: empty AND listed in _intentionally_empty is a decision
  // that the project has no UI package; missing, or empty without that
  // listing, is a decision nobody has made. Every project with a UI package names it,
  // whether or not it publishes to Claude Design.
  const ui = subs.DESIGN_UI_PACKAGE
  const off = (subs._intentionally_empty ?? []).includes('DESIGN_UI_PACKAGE')
  if (ui !== undefined && !String(ui).trim() && off) return { keys: null, problems: [], notApplicable: NOT_SET_UP }
  if (ui === undefined || !String(ui).trim())
    return {
      keys: null,
      problems: [
        `DESIGN_UI_PACKAGE: ${ui === undefined ? 'not set' : 'empty, and not listed in _intentionally_empty'} in .claude/sync-substitutions.json — set it to the UI package that holds the design system, or set it to "" and list it in _intentionally_empty only when the project has no UI package`,
      ],
    }
  const problems = []
  const keys = {}
  for (const k of KEYS) {
    if (subs[k] === undefined) problems.push(`${k}: not set in .claude/sync-substitutions.json`)
    keys[k] = String(subs[k] ?? '').trim()
    if (REQUIRED.has(k) && subs[k] !== undefined && !keys[k]) problems.push(`${k}: empty in .claude/sync-substitutions.json, and the check needs it`)
  }
  return { keys, problems }
}

/** Every JSX opening tag matching `pattern`, with the string literals of its OWN
 * `className` — read at brace depth 0, so JSX passed in a prop is not mistaken for
 * it, with comments inside a `cn(…)` stripped and a compared value
 * (`x === 'a' ? …`) not read as a class. */
export function* openingTags(src, pattern) {
  for (const tag of src.matchAll(pattern)) {
    let depth = 0
    let end = tag.index
    for (; end < src.length; end++) {
      const c = src[end]
      if (c === '{') depth++
      else if (c === '}') depth--
      else if (c === '>' && depth === 0 && src[end - 1] !== '=') break
    }
    const open = src.slice(tag.index, end)
    let at0 = -1
    for (let i = 0, d = 0; i < open.length; i++) {
      if (open[i] === '{') d++
      else if (open[i] === '}') d--
      else if (d === 0 && open.startsWith('className=', i) && /\s/.test(open[i - 1])) {
        at0 = i + 'className='.length
        break
      }
    }
    let value = ''
    if (at0 >= 0 && open[at0] === '"') value = open.slice(at0, open.indexOf('"', at0 + 1) + 1)
    else if (at0 >= 0) {
      let d = 1
      let i = at0 + 1
      for (; i < open.length && d; i++) d += open[i] === '{' ? 1 : open[i] === '}' ? -1 : 0
      value = open
        .slice(at0 + 1, i - 1)
        .replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, '')
        .replace(/[!=]==?\s*(["'`])[^"'`]*\1|(["'`])[^"'`]*\2\s*[!=]==?/g, '')
    }
    const classes = []
    for (const lit of value.matchAll(/"([^"]*)"|'([^']*)'|`([^`]*)`/g))
      for (const cls of (lit[1] ?? lit[2] ?? lit[3]).split(/\s+/).filter(Boolean)) if (!cls.includes('${')) classes.push(cls)
    yield { name: tag[1], open, line: src.slice(0, tag.index).split('\n').length, classes }
  }
}

const isColour = (v) => /^(#[0-9a-f]{3,8}|oklch\(|oklab\(|rgba?\(|hsla?\(|color-mix\()/i.test(v.trim())

/** Light/dark parity: a token only dark has no light value, and a colour other
 * tokens build on (the ramp) that dark does not redefine leaves every alias on it
 * light on a dark surface. Parity applies only when a dark theme exists. */
export function parityProblems(cssByFile) {
  const light = new Map()
  const dark = new Map()
  const out = []
  for (const [file, css] of cssByFile) {
    let blocks
    try {
      blocks = parseTokenBlocks(css)
    } catch (e) {
      out.push(`${file}  — ${e.message}; the light and dark blocks cannot be compared`)
      continue
    }
    for (const b of blocks) for (const d of b.decls) (b.theme === 'dark' ? dark : light).set(`--${d.name}`, { v: d.value, file })
  }
  if (!dark.size) return { problems: out, applies: false }
  for (const [k, { file }] of dark) if (!light.has(k) && k !== '--color-scheme') out.push(`${file}  ${k}  — declared only for the dark theme; every token has a light value`)
  const referenced = new Set()
  for (const [, { v }] of light) for (const m of v.matchAll(/var\((--[A-Za-z0-9-]+)/g)) referenced.add(m[1])
  for (const [k, { v, file }] of light)
    if (referenced.has(k) && isColour(v) && !/var\(/.test(v) && !dark.has(k))
      out.push(`${file}  ${k}  — other tokens build on this colour, and the dark theme does not redefine it, so they stay light on a dark surface`)
  return { problems: out, applies: true }
}

/** Run every check over a repository. `keys` replaces the substitutions read from
 * the repository — for running the check against a tree that has none yet. */
export async function checkDesignTokens(repo, { keys: given } = {}) {
  const problems = []
  const notes = []
  const add = (at, cls, why) => problems.push(`${at}  ${cls}  — ${why}`)
  const rel = (f) => posix(path.relative(repo, f))

  const { keys, problems: keyProblems, notApplicable } = given ? { keys: Object.fromEntries(KEYS.map((k) => [k, String(given[k] ?? '')])), problems: [] } : readKeys(repo)
  if (notApplicable) return { problems: [], notes, counts: null, notApplicable }
  if (keyProblems.length) return { problems: keyProblems, notes, counts: null }
  const pkgRel = keys.DESIGN_UI_PACKAGE.replace(/\/$/, '')
  const pkg = path.join(repo, pkgRel)
  const list = (v) => v.split(/\s+/).filter(Boolean)

  // --- what is checked: the stylesheets, the source, the spec ----------------
  // One file may hold several of these (tokens and the Tailwind entry together); read it once.
  const styleRels = [...new Set([...list(keys.DESIGN_TOKEN_FILES), keys.DESIGN_TYPE_FILE, keys.DESIGN_STYLES_FILE].filter(Boolean).map((r) => posix(path.join(pkgRel, r))))]
  for (const s of styleRels) if (!existsSync(path.join(repo, s))) problems.push(`${s}  — a stylesheet the design keys name, not found`)
  const css = styleRels.filter((s) => existsSync(path.join(repo, s))).map((s) => [s, readFileSync(path.join(repo, s), 'utf8').replace(/\r\n/g, '\n')])

  const sourceDirs = list(keys.DESIGN_SOURCE_DIRS)
  for (const d of sourceDirs) if (!existsSync(path.join(repo, d))) problems.push(`${d}  — a DESIGN_SOURCE_DIRS entry, not found`)
  const sourceFiles = [
    ...new Set(sourceDirs.flatMap((d) => globSync(`${d}/**/*.{ts,tsx}`, { cwd: repo }).map(posix))),
  ].filter((f) => !/\.(gen|generated)\.ts$/.test(f) && !/\/node_modules\//.test(f))

  if (!css.length || !sourceFiles.length) {
    problems.push(`scanned ${sourceFiles.length} source file(s) under ${sourceDirs.join(', ') || '(none)'} and ${css.length} stylesheet(s) — nothing to check means the design keys point at the wrong paths`)
    return { problems, notes, counts: null }
  }
  const designPath = 'design.md'
  const design = existsSync(path.join(repo, designPath)) ? readFileSync(path.join(repo, designPath), 'utf8').replace(/\r\n/g, '\n') : null
  if (design === null) problems.push(`${designPath}  — not found at the repository root; the checks compare the code against it`)

  // --- the roles, read from the CSS -----------------------------------------
  const themeDecls = []
  for (const [, s] of css) for (const m of s.matchAll(/--([a-z0-9-]+)\s*:/g)) themeDecls.push(m[1])
  const themeKeys = (prefix) => new Set(themeDecls.filter((k) => k.startsWith(`${prefix}-`)).map((k) => k.slice(prefix.length + 1)))
  const colours = themeKeys('color')
  const radiusRoles = themeKeys('radius')
  const weightRoles = themeKeys('font-weight')
  const fontFamilies = new Set([...themeKeys('font')].filter((k) => !k.startsWith('weight-')))
  const shadowRoles = themeKeys('shadow')
  const textShadowRoles = themeKeys('text-shadow')
  const spacingAliases = themeKeys('spacing')
  const leadingRoles = themeKeys('leading')
  const trackingRoles = themeKeys('tracking')
  const typeRoles = new Set()
  const utilities = new Set()
  for (const [, s] of css) {
    for (const m of s.matchAll(/@utility\s+(type-[a-z0-9-]+)\s*\{/g)) typeRoles.add(m[1])
    for (const m of s.matchAll(/@utility\s+([a-z][a-z0-9-]*)\s*\{/g)) utilities.add(m[1])
  }
  // A role is named for what it is, never for its size: `--radius-md`, `--font-weight-semibold`,
  // `--shadow-lg` and `type-sm` are sizes in token clothing, whichever stylesheet defines them.
  const definedAt = (text) => {
    for (const [f, src] of css) {
      const i = src.indexOf(text)
      if (i !== -1) return `${f}:${src.slice(0, i).split('\n').length}`
    }
    return styleRels[0]
  }
  for (const [family, prefix, roles] of [
    ['radius', '--radius-', radiusRoles],
    ['weight', '--font-weight-', weightRoles],
    ['shadow', '--shadow-', shadowRoles],
    ['text-shadow', '--text-shadow-', textShadowRoles],
    ['spacing', '--spacing-', spacingAliases],
    ['leading', '--leading-', leadingRoles],
    ['tracking', '--tracking-', trackingRoles],
  ]) {
    for (const r of roles) if (MAGNITUDE_NAME.test(r)) add(definedAt(`${prefix}${r}:`), `${prefix}${r}`, `a ${family} role named by its size; name it for what it is`)
  }
  for (const r of typeRoles) if (MAGNITUDE_NAME.test(r.slice('type-'.length))) add(definedAt(`@utility ${r}`), r, 'a type role named by its size; name it for what it is')
  const scrollUtilities = [...utilities].filter((u) => u.startsWith('scroll-'))
  const fieldLook = new Set(list(keys.DESIGN_FIELD_LOOK_CLASSES))
  const exempt = new Set(list(keys.DESIGN_EXEMPT_COMPONENTS))
  const vendored = keys.DESIGN_VENDORED_DIR ? `${keys.DESIGN_VENDORED_DIR.replace(/\/$/, '')}/` : null
  const restyled = keys.DESIGN_VENDORED_RESTYLED === 'true'
  let classesChecked = 0
  let lines = 0

  // --- the classes source writes ---------------------------------------------
  const arbitrarySpacing = new RegExp(`(?<![\\w-])-?(?:${SPACE_PROPS})-\\[[^\\]]*\\]`, 'g')
  const sources = new Map(sourceFiles.map((f) => [f, readFileSync(path.join(repo, f), 'utf8').replace(/\r\n/g, '\n')]))
  for (const [file, src] of sources) {
    const isVendored = vendored && file.startsWith(vendored)
    src.split('\n').forEach((line, i) => {
      lines++
      if (isComment(line)) return
      const at = `${file}:${i + 1}`
      const each = (re, fn) => {
        for (const m of line.matchAll(re)) {
          classesChecked++
          fn(m)
        }
      }
      // shadcn never writes an arbitrary pixel value; one in a vendored file was
      // hand-edited, so this rule holds there whatever else is exempt.
      each(arbitrarySpacing, (m) => add(at, m[0], "no arbitrary spacing; the scale is Tailwind's own 4px grid"))
      if (isVendored && !restyled) return

      // type
      each(/(?<![\w-])text-\[[^\]]*\]/g, (m) => add(at, m[0], 'no arbitrary text-[…]; type comes from a type-* role'))
      each(/(?<![\w-])(text-[a-z0-9][a-z0-9-]*)(?:\/\d+)?(?![\w-])/g, (m) => {
        const cls = m[1]
        // A shadow on text is the shadow family, not a type size.
        if (cls.startsWith('text-shadow')) {
          const role = cls.slice('text-shadow-'.length)
          if (role !== 'none' && !textShadowRoles.has(role)) add(at, cls, 'not a text-shadow role; a shadow on text comes from a --text-shadow-* token')
          return
        }
        if (NON_TYPE.has(cls) || NOT_CLASSES.has(cls) || colours.has(cls.slice(5))) return
        add(at, cls, /-\d{2,3}$|-(?:black|white)$/.test(cls) ? 'not a theme colour; colour comes from a semantic token' : 'not a type role; a size comes from a type-* role')
      })
      each(/(?<![\w-])(type-[a-z0-9][a-z0-9-]*)(?![\w-])/g, (m) => {
        if (!typeRoles.has(m[1])) add(at, m[1], 'no such type role')
      })
      each(/(?<![\w-])(leading|tracking)-([a-z0-9[\]().-]+)/g, (m) => {
        if ((m[1] === 'leading' ? leadingRoles : trackingRoles).has(m[2])) return
        add(at, m[0], 'line height and tracking come from the type-* role, or a --leading-* / --tracking-* token')
      })

      // radius
      each(new RegExp(`(?<![\\w-])rounded(?:-(?:${CORNER}))?-\\[[^\\]]*\\]`, 'g'), (m) => add(at, m[0], 'no arbitrary rounded-[…]; pick a radius role'))
      each(new RegExp(`(?<![\\w-])rounded(?:-(?:${CORNER}))?(?:-([a-z0-9][a-z0-9-]*))?(?![\\w\\[-])`, 'g'), (m) => {
        if (m[1] === 'none' || radiusRoles.has(m[1])) return
        add(at, m[0], `not a radius role (have: ${[...radiusRoles].sort().join(', ')})`)
      })

      // weight
      each(/(?<![\w-])(font-[a-z0-9][a-z0-9-]*)(?![\w-])/g, (m) => {
        const cls = m[1]
        if (fontFamilies.has(cls.slice(5)) || NOT_CLASSES.has(cls) || weightRoles.has(cls.slice(5))) return
        add(at, cls, `not a weight role (have: ${[...weightRoles].sort().join(', ')})`)
      })

      // shadow — elevation is a role like any other
      each(/(?<![\w-])shadow-([a-z0-9][a-z0-9-]*)(?![\w-])/g, (m) => {
        if (m[1] !== 'none' && !shadowRoles.has(m[1]) && !colours.has(m[1])) add(at, m[0], 'not a shadow role')
      })

      // theme — dark mode is the token file redefining values, never a variant
      each(/(?<![\w-])dark:[^\s"'`]+/g, (m) => add(at, m[0], 'no `dark:` in components; a theme changes token values in the token file'))

      // scrolling — a kind of region is one named utility
      each(/(?<![\w-])overflow-(?:y-)?(?:auto|scroll)(?![\w-])/g, (m) =>
        add(at, m[0], scrollUtilities.length ? `a scroll area is a named utility (${scrollUtilities.map((u) => `\`${u}\``).join(', ')})` : 'a scroll area is a named @utility in the stylesheet, not a bare overflow'),
      )

      // line widths — a ring, outline or border takes a scale width
      each(/(?<![\w-])(?:ring|ring-offset|outline|outline-offset|border(?:-[trblxyse])?)-\[[0-9.]+(?:px|rem)\]/g, (m) => add(at, m[0], 'no arbitrary line width; use the scale (`ring-3`, `border-2`)'))

      // spacing
      each(new RegExp(`(?<![\\w-])-?(?:${SPACE_PROPS})-(\\d+\\.5)(?![\\w-])`, 'g'), (m) => {
        if (m[1] !== '0.5') add(at, m[0], 'off the 4px grid; 0.5 (2px) is the only half step')
      })
    })
  }

  // --- a call site places a component; it never repaints it ------------------
  const fieldClass = (cls) => /^rounded-(?!none$).+/.test(cls) || fieldLook.has(cls)
  for (const [file, src] of sources) {
    if (!file.endsWith('.tsx')) continue
    const isVendored = vendored && file.startsWith(vendored)
    if (!isVendored || restyled) {
      for (const t of openingTags(src, /<(input|textarea)\b/g)) {
        if (NOT_TEXT.test(t.open)) continue
        for (const cls of t.classes) {
          classesChecked++
          if (fieldClass(cls.split(':').pop())) add(`${file}:${t.line}`, `<${t.name}> ${cls}`, "a text field's look is the field atom's; render Input/Textarea")
        }
      }
    }
    if (isVendored) continue
    const ours = new Set()
    for (const m of src.matchAll(/import\s+(?:type\s+)?(?:(\w+)\s*,?\s*)?(?:\{([^}]*)\})?\s*from\s*["']([^"']+)["']/g)) {
      const from = m[3]
      // Glyph modules paint in currentColor; a relative import outside the
      // component trees is a route module, not a component.
      if (/icons?$/.test(from)) continue
      if (from.startsWith('.') ? !/components\//.test(file) && !/\/components\//.test(from) : !/(^|\/)components\//.test(from)) continue
      if (m[1] && /^[A-Z]/.test(m[1])) ours.add(m[1])
      for (const n of (m[2] ?? '').split(',')) {
        const name = n.trim().replace(/^type\s+/, '').split(/\s+as\s+/).pop()
        if (name && /^[A-Z]/.test(name)) ours.add(name)
      }
    }
    if (!ours.size) continue
    for (const t of openingTags(src, /<([A-Z][\w.]*)\b/g)) {
      if (!ours.has(t.name) || exempt.has(t.name)) continue
      for (const cls of t.classes) {
        classesChecked++
        if (!PLACEMENT.test(cls.split(':').pop())) add(`${file}:${t.line}`, `<${t.name}> ${cls}`, 'a call site places a component, never repaints it; add a variant')
      }
      const size = t.open.match(MAGNITUDE_SIZE)
      if (size) add(`${file}:${t.line}`, `<${t.name}> size="${size[1] ?? size[2]}"`, 'a size named by magnitude; the component names the role (a size or variant for what the control is), and a call site never picks how big it is')
    }
  }

  // --- the tokens those roles rest on resolve… ------------------------------
  const realDefs = new Set()
  for (const [, s] of css)
    for (const line of s.split('\n')) {
      const m = line.match(DECL)
      // `--x: var(--x)` is Tailwind's @theme re-export idiom, not a definition.
      if (m && m[2].trim() !== `var(${m[1]})`) realDefs.add(m[1])
    }
  for (const [file, s] of css)
    s.split('\n').forEach((line, i) => {
      for (const m of line.matchAll(/var\((--[A-Za-z0-9-]+)/g)) if (!realDefs.has(m[1])) problems.push(`${file}:${i + 1}  ${m[1]}  — referenced but never defined; resolves to nothing`)
    })

  // --- …and nothing is defined that nothing reaches -------------------------
  const componentSrc = [...sources.values()].join('\n')
  const REEXPORT = /^\s*(--[A-Za-z0-9-]+)\s*:\s*var\((--[A-Za-z0-9-]+)\)\s*;/
  const reached = new Set()
  for (const [, s] of css)
    for (const line of s.split('\n')) {
      const re = line.match(REEXPORT)
      for (const m of line.matchAll(/var\((--[A-Za-z0-9-]+)/g)) {
        if (re && re[1] === re[2] && m[1] === re[2]) continue
        reached.add(m[1])
      }
    }
  for (const m of componentSrc.matchAll(/var\((--[A-Za-z0-9-]+)/g)) reached.add(m[1])
  const written = new Set()
  for (const src of [componentSrc, ...css.map(([, s]) => s)]) for (const m of src.matchAll(/(?<![\w-])[a-z][a-z0-9-]*(?![\w-])/g)) written.add(m[0])
  const COLOUR_PREFIXES = 'text bg border ring outline fill stroke from via to divide accent caret shadow decoration placeholder'.split(' ')
  const SPACING_PREFIXES = [...SPACE_PROPS.split('|'), 'w', 'h', 'size', 'min-w', 'min-h', 'max-w', 'max-h', 'basis', 'inset', 'top', 'right', 'bottom', 'left']
  const UTILITY = [
    [/^--radius-(.+)$/, ['rounded', ...CORNER.split('|').map((c) => `rounded-${c}`)]],
    [/^--font-weight-(.+)$/, ['font']],
    [/^--color-(.+)$/, COLOUR_PREFIXES],
    [/^--spacing-(.+)$/, SPACING_PREFIXES],
    [/^--container-(.+)$/, ['max-w']],
    [/^--shadow-(.+)$/, ['shadow']],
    [/^--leading-(.+)$/, ['leading']],
    [/^--tracking-(.+)$/, ['tracking']],
    [/^--text-(.+)$/, ['text']],
    [/^--font-(?!weight)(.+)$/, ['font']],
  ]
  const producesWrittenUtility = (tok) => UTILITY.some(([shape, prefixes]) => {
    const m = tok.match(shape)
    return m && prefixes.some((p) => written.has(`${p}-${m[1]}`))
  })
  for (const [file, s] of css)
    s.split('\n').forEach((line, i) => {
      const m = line.match(DECL)
      if (!m || m[2].trim() === `var(${m[1]})`) return
      if (reached.has(m[1]) || producesWrittenUtility(m[1])) return
      // A token for a screen not built yet says so on its line; an unmarked unused
      // token is indistinguishable from one a rewrite left behind.
      if (/\/\*\s*not-yet-built:/.test(line)) return
      problems.push(`${file}:${i + 1}  ${m[1]}  — defined but nothing reaches it; delete it, use it, or mark it /* not-yet-built: … */`)
    })

  // --- light and dark agree -------------------------------------------------
  const tokenCss = css.filter(([f]) => list(keys.DESIGN_TOKEN_FILES).some((t) => f === posix(path.join(pkgRel, t))))
  const parity = parityProblems(tokenCss)
  problems.push(...parity.problems)
  // A token file that would not parse is already a problem; it is not evidence of no dark theme.
  if (!parity.applies && !parity.problems.length) notes.push('light/dark parity: no dark theme in the token files — does not apply')

  // --- design.md describes what the code is ---------------------------------
  if (design !== null) {
    const lineOf = (i) => design.slice(0, i).split('\n').length
    const declared = {}
    let group = null
    for (const line of (design.split('---')[1] ?? '').split('\n')) {
      const g = line.match(/^([a-z]+):\s*$/)
      if (g) {
        group = g[1]
        declared[group] = new Set()
        continue
      }
      const k = line.match(/^ {2}([A-Za-z0-9-]+):/)
      if (k && group) declared[group].add(k[1])
    }
    const SPEC_GROUPS = new Set(['colors', 'typography', 'rounded', 'spacing', 'components'])
    for (const m of design.matchAll(/\{([a-z]+)\.([A-Za-z0-9-]+)\}/g))
      if (!declared[m[1]]?.has(m[2])) add(`${designPath}:${lineOf(m.index)}`, `{${m[1]}.${m[2]}}`, 'no such key in the frontmatter')
    // The same reference written without braces, in prose.
    for (const m of design.matchAll(/`([a-z]+)\.([A-Za-z0-9-]+)`/g))
      if ((SPEC_GROUPS.has(m[1]) || declared[m[1]]) && !declared[m[1]]?.has(m[2])) add(`${designPath}:${lineOf(m.index)}`, `${m[1]}.${m[2]}`, 'no such key in the frontmatter')
    // A frontmatter key names a role in either case: `rowTitle` and `row-title` are `type-row-title`.
    const kebab = (k) => k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)
    const typography = new Set([...(declared.typography ?? [])].map(kebab))
    for (const r of typeRoles) if (!typography.has(r.slice(5))) add(designPath, r, 'a type role with no typography entry in the frontmatter')
    // A `font-*` entry is a family, not a role.
    for (const k of declared.typography ?? []) if (!kebab(k).startsWith('font-') && !typeRoles.has(`type-${kebab(k)}`)) add(designPath, `typography.${k}`, 'no such type role in the stylesheets')
    for (const r of radiusRoles) if (!declared.rounded?.has(r)) add(designPath, `rounded-${r}`, 'a radius role with no rounded entry in the frontmatter')
    for (const k of declared.rounded ?? []) if (k !== 'none' && !radiusRoles.has(k)) add(designPath, `rounded.${k}`, 'no such radius role in the stylesheets')
    for (const m of design.matchAll(/`(type-[a-z0-9-]+)`/g)) if (!typeRoles.has(m[1])) add(`${designPath}:${lineOf(m.index)}`, m[1], 'no such type role')
    for (const m of design.matchAll(/`rounded-([a-z0-9-]+)`/g)) if (!radiusRoles.has(m[1]) && m[1] !== 'none') add(`${designPath}:${lineOf(m.index)}`, `rounded-${m[1]}`, 'no such radius role')
    for (const m of design.matchAll(/`font-([a-z0-9-]+)`/g))
      if (!weightRoles.has(m[1]) && !fontFamilies.has(m[1])) add(`${designPath}:${lineOf(m.index)}`, `font-${m[1]}`, 'no such weight role or font family')
    for (const m of design.matchAll(/`(scroll-[a-z-]+|[a-z]+-theme-only)`/g)) if (!utilities.has(m[1])) add(`${designPath}:${lineOf(m.index)}`, m[1], 'no such utility')
    // A pixel value the prose states is on the grid, unless the stylesheets declare
    // it (an odd type step, a pill's 999) or it is a 1px hairline.
    const declaredPx = new Set()
    for (const [, s] of css) for (const m of s.matchAll(/(?<![\w.])(\d+(?:\.\d+)?)px/g)) declaredPx.add(m[1])
    for (const m of design.matchAll(/(?<![\w.])(\d+(?:\.\d+)?)px/g)) {
      const v = m[1]
      if (v === '1' || declaredPx.has(v)) continue
      if (v.includes('.') || Number(v) % 2 !== 0) add(`${designPath}:${lineOf(m.index)}`, `${v}px`, 'off the grid, and no token declares it')
    }
  }

  // --- the generated files are current and imported -------------------------
  const configFile = path.join(pkg, 'design-system/design-system.config.mjs')
  let generatedChecked = 0
  if (!existsSync(configFile)) notes.push(`generated files: no ${pkgRel}/design-system/design-system.config.mjs — no claude-design config, so none apply`)
  else {
    const engine = new URL('../../claude-design/scripts/', import.meta.url)
    const { readConfig } = await import(new URL('config.mjs', engine).href)
    const { buildModel } = await import(new URL('model.mjs', engine).href)
    const { generatedFiles } = await import(new URL('generate.mjs', engine).href)
    const { problems: cfgProblems, ctx } = await readConfig(configFile)
    if (cfgProblems.length) for (const p of cfgProblems) problems.push(`${rel(configFile)}  — ${p}`)
    else {
      const model = buildModel(ctx)
      for (const p of model.problems) problems.push(`${pkgRel}  — ${p}`)
      for (const f of generatedFiles(ctx, model)) {
        generatedChecked++
        const at = rel(f.file)
        const disk = existsSync(f.file) ? readFileSync(f.file, 'utf8').replace(/\r\n/g, '\n') : null
        if (disk === null) add(at, 'missing', 'a generated file the design system needs — run npm run build:design-system')
        else if (disk !== f.content) add(at, 'out of date', "differs from the tokens it is generated from — run npm run build:design-system and commit it")
      }
      const [safelist, classMerge] = generatedFiles(ctx, model)
      const safelistName = path.basename(safelist.file)
      const pkgCss = globSync('**/*.css', { cwd: pkg, exclude: (p) => /node_modules|dist/.test(posix(p)) }).map(posix)
      if (!pkgCss.some((f) => new RegExp(`@import\\s+["'][^"']*${safelistName.replace(/\./g, '\\.')}["']`).test(readFileSync(path.join(pkg, f), 'utf8'))))
        add(rel(safelist.file), 'not imported', "no stylesheet in the UI package imports it, so Tailwind never ships the classes the design system promises — the feed stylesheet imports it")
      const mergeName = path.basename(classMerge.file).replace(/\.ts$/, '')
      const mergeUsed = [...sources].some(([f, src]) => f !== rel(classMerge.file) && src.includes(mergeName) && src.includes('designClassGroups'))
      if (!mergeUsed)
        add(rel(classMerge.file), 'not imported', "no source file passes its designClassGroups to extendTailwindMerge, so cn() keeps two classes of one role and CSS order picks the winner")
    }
  }

  // --- the project's own checks ---------------------------------------------
  const checksDir = path.join(pkg, 'design-system/checks')
  const projectChecks = existsSync(checksDir) ? readdirSync(checksDir).filter((f) => f.endsWith('.mjs')).sort() : []
  const api = {
    repo,
    pkg,
    design,
    designPath,
    css,
    sources,
    roles: { type: typeRoles, radius: radiusRoles, weight: weightRoles, shadow: shadowRoles, colours, spacing: spacingAliases, utilities, fontFamilies },
    add,
  }
  for (const f of projectChecks) {
    const mod = await import(pathToFileURL(path.join(checksDir, f)).href)
    if (typeof mod.default !== 'function') {
      problems.push(`${rel(path.join(checksDir, f))}  — a project check default-exports a function given the check API`)
      continue
    }
    await mod.default(api)
  }

  return {
    problems,
    notes,
    counts: {
      sourceFiles: sourceFiles.length,
      lines,
      stylesheets: css.length,
      classesChecked,
      typeRoles: typeRoles.size,
      radius: radiusRoles.size,
      weight: weightRoles.size,
      colours: colours.size,
      tokens: realDefs.size,
      generated: generatedChecked,
      projectChecks: projectChecks.length,
    },
  }
}

async function main() {
  // The repository root, from this script's own place: .claude/skills/design-system/scripts/.
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..')
  const { problems, notes, counts, notApplicable } = await checkDesignTokens(repo)
  if (notApplicable) {
    console.log(`✓ ${notApplicable}`)
    return
  }
  for (const n of notes) console.log(`  · ${n}`)
  if (problems.length) {
    console.error(`\n✗ design tokens: ${problems.length} place(s) bypass a token role or reference a token that does not resolve.\n  What each role means is in design.md; the roles are defined in the stylesheets the design keys name.\n`)
    for (const p of problems) console.error(`    ${p}`)
    if (counts) console.error(`\n  (scanned ${counts.sourceFiles} source files, ${counts.stylesheets} stylesheets and design.md; ${counts.classesChecked} classes checked)`)
    process.exit(1)
  }
  console.log(
    `✓ design tokens: scanned ${counts.sourceFiles} source files (${counts.lines} lines), ${counts.stylesheets} stylesheets and design.md; ` +
      `${counts.classesChecked} classes checked against ${counts.typeRoles} type roles, ${counts.radius} radius, ${counts.weight} weight, ` +
      `${counts.colours} colours; ${counts.tokens} tokens resolve; ${counts.generated} generated files current; ${counts.projectChecks} project checks`,
  )
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) await main()
