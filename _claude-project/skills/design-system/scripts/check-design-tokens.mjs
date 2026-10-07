#!/usr/bin/env node
/**
 * Every design token family is set by a ROLE, and the tokens underneath resolve.
 *
 *   node .claude/skills/design-system/scripts/check-design-tokens.mjs [--base <ref> | --all]   (npm run lint:tokens)
 *
 * The screen rules judge only lines changed since --base (or DESIGN_TOKENS_BASE; default:
 * where this work left origin/main), so new code is held to the design language and an
 * untouched line is left alone; --all judges every line. Every other check reads the
 * whole tree.
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
 *              painting the field look; a className naming a constant is read as the
 *              constant's classes;
 *   screens    a file outside a part — a route, a feature folder — draws no box
 *              (background, border, radius, shadow, padding), fades no colour, and imports no frame
 *              atom (the Wraps column of references/block-types.md); a part is a .tsx
 *              under a `components/` folder outside `features/`;
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

import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, globSync, readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseTokenBlocks } from '../../claude-design/scripts/resolve.mjs'
import { atomModule, readBlockTypes } from './block-types.mjs'

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
/** A token a class list can hold — never an operator or a stray quote. */
const CLASS_SHAPE = /^!?-?[a-z0-9@*[][^\s'"`{}]*$/i
/** A box: what a part draws and a screen never does. */
const BOX = /^-?(?:bg-|border|rounded|shadow|p[xytrblse]?-|ring|outline|divide-)/
/** Where a file sits: a part draws its box; a screen or feature file never does. */
export const isPart = (file) => {
  const parts = file.split('/')
  return parts.includes('components') && !parts.includes('features')
}
const isContent = (file) => file.endsWith('.tsx') && !isPart(file) && !/\.(test|spec|stories)\.tsx$/.test(file)
/** Modules whose components are glyphs, painting in currentColor. */
const GLYPH_MODULE = /(?:^|\/)icons?$|^lucide-react$|^@tabler\/icons-react$|^@heroicons\/|^@phosphor-icons\/|^@radix-ui\/react-icons$/
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

/** The class-merge helpers: their arguments are class lists. */
const CLASS_HELPERS = new Set(['cn', 'clsx', 'cva', 'tv', 'twMerge', 'twJoin', 'cx'])

/** An expression with the arguments of every other call blanked — `colourFor(x, "submitted")`
 * returns classes, but its arguments are values, not class lists. */
export function withoutCallArguments(expr) {
  let out = ''
  let i = 0
  for (const m of expr.matchAll(/([A-Za-z_$][\w$.]*)\s*\(/g)) {
    if (m.index < i) continue
    const open = m.index + m[0].length - 1
    if (CLASS_HELPERS.has(m[1].split('.').pop())) continue
    const close = closeOf(expr, open, '(', ')')
    if (close < 0) break
    out += `${expr.slice(i, open + 1)}${' '.repeat(close - open - 1)})`
    i = close + 1
  }
  return out + expr.slice(i)
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
    const quote = open[at0]
    if (at0 >= 0 && (quote === '"' || quote === "'")) value = open.slice(at0, open.indexOf(quote, at0 + 1) + 1)
    else if (at0 >= 0) {
      let d = 1
      let i = at0 + 1
      for (; i < open.length && d; i++) d += open[i] === '{' ? 1 : open[i] === '}' ? -1 : 0
      value = open
        .slice(at0 + 1, i - 1)
        .replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*/g, '')
        .replace(/[!=]==?\s*(["'`])[^"'`]*\1|(["'`])[^"'`]*\2\s*[!=]==?/g, '')
      value = withoutCallArguments(value)
    }
    // A template's text and the strings inside each of its `${…}` are class lists; the
    // expression around them (`x ? … : …`) is not.
    const lists = []
    for (const lit of value.matchAll(/"([^"]*)"|'([^']*)'|`([^`]*)`/g)) {
      if (lit[3] === undefined) {
        lists.push(lit[1] ?? lit[2])
        continue
      }
      lists.push(lit[3].replace(/\$\{[^}]*\}/g, ' '))
      for (const expr of lit[3].matchAll(/\$\{([^}]*)\}/g)) for (const q of expr[1].matchAll(/"([^"]*)"|'([^']*)'/g)) lists.push(q[1] ?? q[2])
    }
    const classes = lists.flatMap((l) => l.split(/\s+/)).filter((c) => CLASS_SHAPE.test(c))
    // The bare names the className reads — a constant (`DIVIDED`), a map (`tone[x]`) —
    // never a call (`cn(`) or a property after a dot.
    const ids = [...value.replace(/"[^"]*"|'[^']*'|`[^`]*`/g, '').matchAll(/(?<![\w$.])[A-Za-z_$][\w$]*(?![\w$]*\s*\()/g)].map((m) => m[0])
    yield { name: tag[1], open, line: src.slice(0, tag.index).split('\n').length, classes, ids }
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

/**
 * Where a bracketed span that opens at `start` closes, skipping strings, template
 * literals and comments; -1 when it never does.
 */
function closeOf(src, start, open, close) {
  let depth = 0
  for (let i = start; i < src.length; i++) {
    const ch = src[i]
    if (ch === '"' || ch === "'" || ch === '`') {
      for (i++; i < src.length && src[i] !== ch; i++) if (src[i] === '\\') i++
    } else if (ch === '/' && src[i + 1] === '/') i = src.indexOf('\n', i) < 0 ? src.length : src.indexOf('\n', i)
    else if (ch === '/' && src[i + 1] === '*') i = src.indexOf('*/', i + 2) < 0 ? src.length : src.indexOf('*/', i + 2) + 1
    else if (ch === open) depth++
    else if (ch === close && --depth === 0) return i
  }
  return -1
}

/** The class-merge helpers whose arguments are class lists. */
/** Every constant a file declares, with the classes in its initialiser — a string, a
 * template, a class-merge call, an array or a map — so a className that names it is read
 * as those classes. `exported` collects the ones another file may import. */
export function constantClasses(src, exported = new Map()) {
  const local = new Map()
  for (const d of src.matchAll(/(\bexport\s+)?\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*/g)) {
    const at = d.index + d[0].length
    const ch = src[at]
    let span = ''
    if (ch === '"' || ch === "'" || ch === '`') span = src.slice(at, src.indexOf(ch, at + 1) + 1)
    else if (ch === '[' || ch === '{' || ch === '(') span = src.slice(at, closeOf(src, at, ch, { '[': ']', '{': '}', '(': ')' }[ch]) + 1)
    else {
      const call = src.slice(at).match(/^(?:cn|clsx|twMerge|twJoin|cx)\s*\(/)
      if (call) span = src.slice(at, closeOf(src, at + call[0].length - 1, '(', ')') + 1)
    }
    if (!span) continue
    const classes = []
    for (const lit of span.matchAll(/"([^"]*)"|'([^']*)'|`([^`]*)`/g))
      for (const cls of (lit[1] ?? lit[2] ?? lit[3]).split(/\s+/).filter(Boolean)) if (!cls.includes('${')) classes.push(cls)
    if (!classes.length) continue
    local.set(d[2], classes)
    if (d[1]) exported.set(d[2], classes)
  }
  return local
}

const CLASS_CALLS = /\b(?:cn|clsx|cva|tv|twMerge|twJoin|cx)\s*\(/g

/**
 * The source with everything but its class lists blanked, line breaks kept: className and
 * class attribute values and any prop named for classes (`contentClassName`, `toneClasses`), the arguments of the class-merge helpers, the initialiser of any
 * variable those use (`const base = "…"`, a size map), and the body of any function they
 * call (`className={toneFor(order)}`). An import path, a URL, a logger name or a prop value
 * (`size="text-meta"`) is not a class list.
 */
export function classText(src, { names = new Set() } = {}) {
  const keep = new Uint8Array(src.length)
  const mark = (a, b) => {
    for (let i = a; i <= b && i < src.length; i++) keep[i] = 1
  }
  const spans = []
  for (const m of src.matchAll(/(?<!\b(?:const|let|var)\s+)\b(?:className|class|[A-Za-z]\w*(?:ClassName|Classes|Class))\s*=(?![=>])\s*/g)) {
    const at = m.index + m[0].length
    const ch = src[at]
    if (ch === '"' || ch === "'") spans.push([at, src.indexOf(ch, at + 1)])
    else if (ch === '{') spans.push([at, closeOf(src, at, '{', '}')])
  }
  for (const m of src.matchAll(CLASS_CALLS)) {
    const open = m.index + m[0].length - 1
    spans.push([open, closeOf(src, open, '(', ')')])
  }
  // A variable a class list names contributes its initialiser, once — named here, or in
  // another file's class list (`names`), for a constant exported to it.
  const seen = new Set()
  // Every declaration's initialiser start, by name — the first one wins.
  const declared = new Map()
  for (const d of src.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*/g)) {
    if (!declared.has(d[1])) declared.set(d[1], d.index + d[0].length)
  }
  for (const d of src.matchAll(/\bfunction\s+([A-Za-z_$][\w$]*)\s*(?=[(<])/g)) {
    if (!declared.has(d[1])) declared.set(d[1], d.index + d[0].length)
  }
  // A call's span (`toneFor(order)`), so the function it names is followed in turn.
  const callEnd = (start) => {
    const call = src.slice(start).match(/^(?:await\s+)?[A-Za-z_$][\w$.]*\s*\(/)
    return call ? closeOf(src, start + call[0].length - 1, '(', ')') : -1
  }
  // A function's span: its block body, or an arrow's expression to the end of its line.
  const fnEnd = (start) => {
    const open = src.indexOf('(', start)
    if (open < 0) return -1
    const close = closeOf(src, open, '(', ')')
    if (close < 0) return -1
    const after = src.slice(close + 1).match(/^\s*(?::[^={]*)?(=>)?\s*/)
    const at = close + 1 + after[0].length
    if (src[at] === '{') return closeOf(src, at, '{', '}')
    if (!after[1]) return close
    const eol = src.indexOf('\n', at)
    return eol < 0 ? src.length - 1 : eol
  }
  const declare = (name) => {
    if (seen.has(name)) return
    seen.add(name)
    const start = declared.get(name)
    if (start === undefined) return
    const ch = src[start]
    const end =
      ch === '{'
        ? closeOf(src, start, '{', '}')
        : ch === '['
          ? closeOf(src, start, '[', ']')
          : ch === '"' || ch === "'" || ch === '`'
            ? src.indexOf(ch, start + 1)
            : ch === '(' || ch === '<' || src.startsWith('async', start)
              ? fnEnd(start)
              : callEnd(start)
    if (end >= 0) spans.push([start, end])
  }
  for (const name of names) declare(name)
  for (let k = 0; k < spans.length; k++) {
    const [a, b] = spans[k]
    if (b < 0) continue
    mark(a, b)
    for (const id of src.slice(a, b + 1).matchAll(/(?<![\w$.'"`-])[A-Za-z_$][\w$]*/g)) {
      declare(id[0])
    }
  }
  let out = ''
  for (let i = 0; i < src.length; i++) out += keep[i] || src[i] === '\n' ? src[i] : ' '
  return out
}

/** The identifiers every file's class lists name, so a constant exported from one file and
 * used in another's class list is checked where it is declared. */
export function classNames(sources) {
  const names = new Set()
  for (const src of sources) {
    const text = classText(src)
    for (const id of text.matchAll(/(?<![\w$.'"`-])[A-Za-z_$][\w$]*/g)) names.add(id[0])
  }
  return names
}

/** Every file and line a change touched since `base`, tracked or not: a Map of file to its
 * changed line numbers, or to ALL for a file git does not track yet. */
export const ALL = 'all'
export function changedLines(repo, base) {
  const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
  const out = new Map()
  let file = null
  const addHunks = (diff, as) => {
    for (const line of diff.split('\n')) {
      if (line.startsWith('+++ ')) file = as ?? line.slice(4).replace(/^b\//, '')
      const m = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/)
      if (!m || !file || file === '/dev/null') continue
      if (!out.has(file)) out.set(file, new Set())
      for (let n = Number(m[1]), end = n + Number(m[2] ?? 1); n < end; n++) out.get(file).add(n)
    }
  }
  // A moved file is judged by its edits, not as new: git pairs committed moves (-M), and an
  // uncommitted one pairs with the deleted file of its name.
  // No --ignore-cr-at-eol: the kit's .gitattributes (`* text=auto eol=lf`) checks tracked files
  // out as LF on every platform, and a CRLF untracked file can only over-judge, never hide a line.
  addHunks(git('diff', '-M', '-U0', '--no-color', base, '--', '*.ts', '*.tsx'))
  const deleted = git('diff', '-M', '--name-only', '--diff-filter=D', base, '--', '*.ts', '*.tsx').split('\n').filter(Boolean)
  const claimed = new Set()
  for (const f of git('ls-files', '--others', '--exclude-standard', '--', '*.ts', '*.tsx').split('\n')) {
    if (!f) continue
    const from = deleted.find((d) => !claimed.has(d) && path.basename(d) === path.basename(f))
    if (!from) {
      out.set(f, ALL)
      continue
    }
    claimed.add(from)
    const r = spawnSync('git', ['-C', repo, 'diff', '--no-index', '-U0', '--no-color', '-', f], { input: git('show', `${base}:${from}`), encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })
    if (r.status !== 0 && r.status !== 1) throw new Error(`git diff --no-index ${from} ${f}: ${r.stderr.trim()}`)
    out.set(f, new Set())
    addHunks(r.stdout, f)
  }
  return out
}

/** The base the screen rules measure against: the given ref, or where this work left
 * `origin/main`. Null — every line is checked — outside a git repository or without it. */
export function screenBase(repo, base) {
  try {
    const ref = base ?? execFileSync('git', ['-C', repo, 'merge-base', 'HEAD', 'origin/main'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    execFileSync('git', ['-C', repo, 'rev-parse', '--verify', '--quiet', `${ref}^{commit}`], { stdio: 'ignore' })
    return ref
  } catch {
    if (base) throw new Error(`${base}: not a commit this repository has — the screen rules need it to know what changed`)
    return null
  }
}

/** Run every check over a repository. `keys` replaces the substitutions read from
 * the repository — for running the check against a tree that has none yet. The screen
 * rules judge only the lines changed since `base` (default: where this work left
 * `origin/main`); `all: true` judges every line. */
export async function checkDesignTokens(repo, { keys: given, base, all = false } = {}) {
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
  const exported = classNames(sources.values())
  // The screen rules hold new and changed code to the design language and leave a line
  // nobody has touched alone.
  let screenScope = null
  if (!all) {
    const ref = screenBase(repo, base)
    if (ref) {
      screenScope = changedLines(repo, ref)
      const lines = [...screenScope.values()].reduce((n, v) => n + (v === ALL ? 0 : v.size), 0)
      const fresh = [...screenScope.values()].filter((v) => v === ALL).length
      notes.push(`screen rules: ${lines} changed line(s) and ${fresh} new file(s) since ${ref.slice(0, 12)}; untouched lines are not judged`)
    }
  }
  if (!screenScope) notes.push('screen rules: every line judged')
  const touched = (file, from, to = from) => {
    if (!screenScope) return true
    const lines = screenScope.get(file)
    if (!lines) return false
    if (lines === ALL) return true
    for (let n = from; n <= to; n++) if (lines.has(n)) return true
    return false
  }
  for (const [file, src] of sources) {
    const isVendored = vendored && file.startsWith(vendored)
    // Only class lists are checked; the rest of the file is blanked, line numbers kept.
    const classLines = classText(src, { names: exported }).split('\n')
    src.split('\n').forEach((original, i) => {
      lines++
      if (isComment(original)) return
      const line = classLines[i]
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
  // A className naming a constant is read as the constant's classes, whether the
  // file declares it or imports it from another.
  const exportedConsts = new Map()
  const fileConsts = new Map([...sources].map(([f, s]) => [f, constantClasses(s, exportedConsts)]))
  let blockTypes = { frames: new Map() }
  try {
    blockTypes = readBlockTypes()
  } catch (err) {
    problems.push(`${err.message} — the frame-atom rule cannot run`)
  }
  const frameModules = new Map([...blockTypes.frames].map(([atom, types]) => [atomModule(atom), { atom, types }]))
  const fieldClass = (cls) => /^rounded-(?!none$).+/.test(cls) || fieldLook.has(cls)
  // A box a screen or feature file draws, or a colour it fades, belongs in a part.
  const screenFinding = (base) => {
    if (BOX.test(base)) return 'a screen or feature file draws no box; a background, border, radius, shadow or padding comes from a part (block-types.md)'
    const colour = base.match(/^text-(.+?)\/\d+$/)
    if (colour && colours.has(colour[1])) return 'a screen or feature file never fades a colour; a muted look is a colour role of its own'
    return null
  }
  const placesOnly = (file, t, classes) => {
    if (!touched(file, t.line, t.line + t.open.split('\n').length - 1)) return
    for (const cls of classes) {
      classesChecked++
      const why = screenFinding(cls.split(':').pop())
      if (why) add(`${file}:${t.line}`, `<${t.name}> ${cls}`, why)
    }
  }
  for (const [file, src] of sources) {
    if (!file.endsWith('.tsx')) continue
    const isVendored = vendored && file.startsWith(vendored)
    const consts = fileConsts.get(file)
    const classesOf = (t) => [...t.classes, ...t.ids.flatMap((id) => consts.get(id) ?? exportedConsts.get(id) ?? [])]
    if (!isVendored || restyled) {
      for (const t of openingTags(src, /<(input|textarea)\b/g)) {
        if (NOT_TEXT.test(t.open)) continue
        for (const cls of classesOf(t)) {
          classesChecked++
          if (fieldClass(cls.split(':').pop())) add(`${file}:${t.line}`, `<${t.name}> ${cls}`, "a text field's look is the field atom's; render Input/Textarea")
        }
      }
    }
    if (isVendored) continue
    const content = isContent(file)
    // Every import form — named, default, namespace — of a frame atom's module.
    if (content)
      for (const m of src.matchAll(/\bimport\s[^'"]*?from\s*["']([^"']+)["']/g)) {
        const frame = frameModules.get(m[1].split('/').pop()) ?? frameModules.get(m[1].replace(/^@radix-ui\/react-/, ''))
        const at = src.slice(0, m.index).split('\n').length
        if (frame && touched(file, at, at + m[0].split('\n').length - 1))
          add(`${file}:${at}`, frame.atom, `a frame atom is used only inside a part; build or use the ${frame.types.join(' / ')} part (block-types.md)`)
      }
    const ours = new Set()
    const glyphs = new Set()
    for (const m of src.matchAll(/import\s+(?:type\s+)?(?:(\w+)\s*,?\s*)?(?:\{([^}]*)\})?\s*from\s*["']([^"']+)["']/g)) {
      const from = m[3]
      const names = [m[1], ...(m[2] ?? '').split(',').map((n) => n.trim().replace(/^type\s+/, '').split(/\s+as\s+/).pop())].filter((n) => n && /^[A-Z]/.test(n))
      // Glyph modules paint in currentColor; their caller naming the colour is the design.
      if (GLYPH_MODULE.test(from)) {
        for (const n of names) glyphs.add(n)
        continue
      }
      // A relative import outside the component trees is a route module, not a component.
      if (from.startsWith('.') ? !/components\//.test(file) && !/\/components\//.test(from) : !/(^|\/)components\//.test(from)) continue
      for (const n of names) ours.add(n)
    }
    for (const t of openingTags(src, /<([A-Z][\w.]*)\b/g)) {
      // A glyph — imported from an icon set, or an icon bound from a map (`Icon`, `item.Icon`).
      if (exempt.has(t.name) || glyphs.has(t.name) || /(?:^|\.)\w*Icon$/.test(t.name)) continue
      if (!ours.has(t.name)) {
        if (content) placesOnly(file, t, classesOf(t))
        continue
      }
      for (const cls of classesOf(t)) {
        classesChecked++
        if (!PLACEMENT.test(cls.split(':').pop())) add(`${file}:${t.line}`, `<${t.name}> ${cls}`, 'a call site places a component, never repaints it; add a variant')
      }
      const size = t.open.match(MAGNITUDE_SIZE)
      if (size) add(`${file}:${t.line}`, `<${t.name}> size="${size[1] ?? size[2]}"`, 'a size named by magnitude; the component names the role (a size or variant for what the control is), and a call site never picks how big it is')
    }
    // A lowercase tag is an element; `<item.icon>` is a component bound from data, a glyph.
    if (content) for (const t of openingTags(src, /<([a-z][\w-]*)\b(?!\.)/g)) placesOnly(file, t, classesOf(t))
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
  const argv = process.argv.slice(2)
  const at = argv.indexOf('--base')
  const base = at >= 0 ? argv[at + 1] : process.env.DESIGN_TOKENS_BASE || undefined
  const { problems, notes, counts, notApplicable } = await checkDesignTokens(repo, { base, all: argv.includes('--all') })
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
