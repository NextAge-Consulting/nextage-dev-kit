#!/usr/bin/env node
/**
 * Every design token family is set by a ROLE, and the tokens underneath resolve.
 *
 *   node .claude/skills/design-system/scripts/check-design-tokens.mjs [--base <ref> | --all]   (npm run lint:tokens)
 *   node .claude/skills/design-system/scripts/check-design-tokens.mjs --roles [--repo <root>]   (every role, one family per line)
 *   node .claude/skills/design-system/scripts/check-design-tokens.mjs --purposes [--repo <root>]   (every token and utility with what it is for)
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
 * The source checked is the UI package and every workspace depending on it, found by
 * ui-sources.mjs. The project's values come from .claude/sync-substitutions.json:
 *   DESIGN_UI_PACKAGE          the UI package, from the repository root
 *   DESIGN_TOKEN_FILES         its token stylesheets (light and dark blocks), from the package
 *   DESIGN_TYPE_FILE           its type-role stylesheet, from the package
 *   DESIGN_STYLES_FILE         its Tailwind entry (theme, utilities, aliases), from the package
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
 *              areas — off a role, arbitrary, or off the 4px grid; on changed lines,
 *              spacing between the steps of the scale (the config's spacing.steps, else
 *              the kit's 0, 4, 8, 12, 16, 24, 32, 48px);
 *   call sites a component imported from the project's component trees is never given
 *              a fixed height or a t-shirt size (`size="sm"`); a raw <input>/<textarea>
 *              painting the field look; a className naming a constant is read as the
 *              constant's classes;
 *   screens    a file outside a part — a route, a feature folder — fades no colour and
 *              imports no frame atom (the Wraps column of references/block-types.md); a
 *              part is a .tsx under a `components/` folder outside `features/`;
 *   names      no role — type, radius, weight, shadow, spacing, leading, tracking — is
 *              named with a t-shirt size (`md`, `2xl`);
 *   tokens     every var() resolves, every token is reached, and the dark theme
 *              redefines every colour other tokens build on and adds none of its own;
 *   contrast   every text pair — design.md components' textColor on backgroundColor, and
 *              --<x>-foreground on --<x> — measures 4.5:1 in each theme, or its text
 *              token's line marks the ratio accepted (contrast.mjs);
 *   patterns   every type role, token and component a pattern reference names in code exists;
 *   design.md  every token reference and quoted class exists, every type and radius
 *              role has its frontmatter entry, every pixel value in the frontmatter is
 *              on the grid;
 *
 * Whether a call site repaints a part, whether a screen draws a box a part should, and
 * whether a name says what a thing is for are judgements: the design review at /commit
 * (gitflow's design-review.sh) makes them.
 *   generated  with a claude-design config, the safelist and class-merge files are
 *              current and imported;
 *   project    every `*.mjs` in <DESIGN_UI_PACKAGE>/design-system/checks/ — the
 *              project's own checks, each a default-exported function given the API
 *              below.
 *
 * Prints what it inspected, and fails when that is nothing.
 */

import { execFileSync, spawnSync } from 'node:child_process'
import { createRequire } from 'node:module'
import { existsSync, globSync, readdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseTokenBlocks } from '../../claude-design/scripts/resolve.mjs'
import { atomModule, readBlockTypes } from './block-types.mjs'
import { contrastProblems } from './contrast.mjs'
import { uiSourceDirs } from './ui-sources.mjs'

export const KEYS = [
  'DESIGN_UI_PACKAGE', 'DESIGN_TOKEN_FILES', 'DESIGN_TYPE_FILE', 'DESIGN_STYLES_FILE', 'DESIGN_VENDORED_DIR',
  'DESIGN_VENDORED_RESTYLED', 'DESIGN_FIELD_LOOK_CLASSES', 'DESIGN_EXEMPT_COMPONENTS',
]
const REQUIRED = new Set(['DESIGN_UI_PACKAGE', 'DESIGN_TOKEN_FILES'])

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

/** A fixed height or size at a call site: how tall a control is belongs to the control. */
const FIXED_SIZE = /^(?:h|size)-(?!full$|auto$|screen$|fit$|min$|max$|dvh$|svh$|lvh$).+$/
/** A token a class list can hold — never an operator or a stray quote. */
const CLASS_SHAPE = /^!?-?[a-z0-9@*[][^\s'"`{}]*$/i
/** Where a file sits: a part draws its box; a screen or feature file never does. */
export const isPart = (file) => {
  const parts = file.split('/')
  return parts.includes('components') && !parts.includes('features')
}
const isContent = (file) => file.endsWith('.tsx') && !isPart(file) && !/\.(test|spec|stories)\.tsx$/.test(file)
/** Modules whose components are glyphs, painting in currentColor. */
const GLYPH_MODULE = /(?:^|\/)icons?$|^lucide-react$|^@tabler\/icons-react$|^@heroicons\/|^@phosphor-icons\/|^@radix-ui\/react-icons$/
const NOT_TEXT = /\stype="(?:radio|checkbox|file|hidden|range|color)"/
/** A role named with a t-shirt size: `sm`, `md`, `lg`, `xs`, `2xl`. */
const MAGNITUDE_NAME = /^(?:\d*x[sl]|sm|md|lg)$/
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

/** Every role the stylesheets define, per family, as sets of names: `colours` holds
 * `primary` for `--color-primary`, `typeRoles` holds `type-body`. */
export function rolesOf(css) {
  const themeDecls = []
  for (const [, s] of css) for (const m of s.matchAll(/--([a-z0-9-]+)\s*:/g)) themeDecls.push(m[1])
  const themeKeys = (prefix) => new Set(themeDecls.filter((k) => k.startsWith(`${prefix}-`)).map((k) => k.slice(prefix.length + 1)))
  const typeRoles = new Set()
  const utilities = new Set()
  for (const [, s] of css) {
    for (const m of s.matchAll(/@utility\s+(type-[a-z0-9-]+)\s*\{/g)) typeRoles.add(m[1])
    for (const m of s.matchAll(/@utility\s+([a-z][a-z0-9-]*)\s*\{/g)) utilities.add(m[1])
  }
  return {
    colours: themeKeys('color'),
    radiusRoles: themeKeys('radius'),
    weightRoles: themeKeys('font-weight'),
    fontFamilies: new Set([...themeKeys('font')].filter((k) => !k.startsWith('weight-'))),
    shadowRoles: themeKeys('shadow'),
    textShadowRoles: themeKeys('text-shadow'),
    spacingAliases: themeKeys('spacing'),
    leadingRoles: themeKeys('leading'),
    trackingRoles: themeKeys('tracking'),
    typeRoles,
    utilities,
  }
}

/** The stylesheets the design keys name, as [file, text]. Null when the keys are unset. */
function designStylesheets(repo) {
  const { keys, problems } = readKeys(repo)
  if (!keys || problems.length) return null
  const pkgRel = keys.DESIGN_UI_PACKAGE.replace(/\/$/, '')
  const rels = [...new Set([...keys.DESIGN_TOKEN_FILES.split(/\s+/), keys.DESIGN_TYPE_FILE, keys.DESIGN_STYLES_FILE].filter(Boolean))]
  return rels.map((r) => path.join(repo, pkgRel, r)).filter(existsSync).map((f) => [f, readFileSync(f, 'utf8').replace(/\r\n/g, '\n')])
}

/** What each custom property and utility is for: the comment on its line or the comment
 * directly above it, from the first stylesheet that gives one. A re-export with no comment
 * of its own (`--spacing-x: var(--x)`) carries the purpose of what it points at. */
export function purposesOf(css) {
  const out = new Map()
  const pointsAt = new Map()
  for (const [, src] of css) {
    const lines = src.split('\n')
    let above = null
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim()
      if (line.startsWith('/*')) {
        let text = line
        while (!text.includes('*/') && i + 1 < lines.length) text += ` ${lines[++i].trim()}`
        above = text.replace(/^\/\*+\s*/, '').replace(/\s*\*\/.*$/, '').replace(/\s*\*\s+/g, ' ').trim()
        continue
      }
      const decl = line.match(/^(--[A-Za-z0-9-]+)\s*:([^;]*);\s*(?:\/\*\s*(.*?)\s*\*\/)?/)
      const util = line.match(/^@utility\s+([a-z][a-z0-9-]*)\s*\{/)
      const name = decl?.[1] ?? util?.[1]
      if (name) {
        const purpose = decl?.[3] || above || ''
        if (!out.get(name)) out.set(name, purpose)
        const target = decl?.[2].trim().match(/^var\((--[A-Za-z0-9-]+)\)$/)?.[1]
        if (target && target !== name && !pointsAt.has(name)) pointsAt.set(name, target)
      }
      if (line) above = null
    }
  }
  for (const [name, target] of pointsAt) {
    let to = target
    for (let hops = 0; !out.get(name) && to && hops < 8; hops++) {
      if (out.get(to)) out.set(name, out.get(to))
      to = pointsAt.get(to)
    }
  }
  return out
}

/** Each token and utility with what it is for, one per line — what the design review is
 * handed to judge whether a role is used for its job. Null when the keys are unset. */
export function rolePurposes(repo) {
  const css = designStylesheets(repo)
  if (!css) return null
  return [...purposesOf(css)].map(([name, purpose]) => `${name} — ${purpose || '(no purpose written)'}`).join('\n')
}

/** The project's roles as the classes a screen writes, one family per line — what the
 * design review is handed so it never guesses what exists. Null when the keys are unset. */
export function roleList(repo) {
  const css = designStylesheets(repo)
  if (!css) return null
  const r = rolesOf(css)
  const line = (label, set, prefix = '') => `${label}: ${[...set].sort().map((n) => `${prefix}${n}`).join(' ') || '(none)'}`
  return [
    line('type roles', r.typeRoles),
    line('colours (bg-, text-, border-)', r.colours),
    line('radius', r.radiusRoles, 'rounded-'),
    line('weight', r.weightRoles, 'font-'),
    line('font family', r.fontFamilies, 'font-'),
    line('shadow', r.shadowRoles, 'shadow-'),
    line('text shadow', r.textShadowRoles, 'text-shadow-'),
    line('spacing aliases', r.spacingAliases),
    line('leading', r.leadingRoles, 'leading-'),
    line('tracking', r.trackingRoles, 'tracking-'),
    line('utilities', [...r.utilities].filter((u) => !u.startsWith('type-'))),
  ].join('\n')
}

/** Array methods a class list built as an array passes through on its way to a string. */
const ARRAY_JOINS = new Set(['join', 'filter', 'concat', 'flat'])
/** The class-merge helpers: their arguments are class lists. */
const CLASS_HELPERS = new Set(['cn', 'clsx', 'cva', 'tv', 'twMerge', 'twJoin', 'cx'])
/** The helpers whose call, as a constant's initialiser, makes that constant a class list. */
const CONSTANT_HELPERS = new Set(['cn', 'clsx', 'twMerge', 'twJoin', 'cx'])
/** A prop or binding named for classes: `className`, `class`, `contentClassName`, `toneClasses`. */
const CLASS_NAMED = /^(?:className|class|[A-Za-z]\w*(?:ClassName|Classes|Class))$/

// --- reading source: TypeScript's own parser ------------------------------------
// Source is read as the compiler reads it, so an attribute, an import path, a URL or a
// logger name is never mistaken for a class list.

let typescript = null
/** TypeScript, from the checked repository, else the global npm root; loaded once. A
 * package without the compiler API (a stub some tools leave behind) is passed over. */
export function loadTypeScript(repo = process.cwd()) {
  if (typescript) return typescript
  const usable = (base) => {
    try {
      const ts = createRequire(base)('typescript')
      return typeof ts?.createSourceFile === 'function' ? ts : null
    } catch {
      return null
    }
  }
  typescript = usable(path.join(repo, 'package.json'))
  if (typescript) return typescript
  let root = ''
  try {
    root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim()
  } catch {}
  typescript = root ? usable(path.join(root, 'noop.js')) : null
  if (typescript) return typescript
  throw new Error(`TypeScript not found from ${repo} or the global npm root — the design token check reads source with it; install it (npm i -D typescript in the project, or npm i -g typescript)`)
}

const parsed = new Map()
/** A source file's syntax tree: as TSX, or as plain TypeScript when it parses better so. */
function parse(src) {
  let sf = parsed.get(src)
  if (sf) return sf
  const ts = loadTypeScript()
  sf = ts.createSourceFile('source.tsx', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
  if (sf.parseDiagnostics?.length) {
    const plain = ts.createSourceFile('source.ts', src, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
    if (plain.parseDiagnostics.length < sf.parseDiagnostics.length) sf = plain
  }
  parsed.set(src, sf)
  return sf
}

/** The last name of a callee: `cn` for `cn(…)`, `twMerge` for `utils.twMerge(…)`. */
function calleeName(ts, expr) {
  if (ts.isIdentifier(expr)) return expr.text
  if (ts.isPropertyAccessExpression(expr)) return expr.name.text
  return null
}

/** The text spans of a string or template literal: its characters, never its `${…}`. With
 * `quoted`, a span keeps its quotes and backticks, so a reader of the blanked text can
 * still tell one string from the next. */
function literalRanges(ts, node, sf, out, quoted = false) {
  const q = quoted ? 0 : 1
  if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
    out.push([node.getStart(sf) + q, node.end - q])
    return true
  }
  if (ts.isTemplateExpression(node)) {
    out.push([node.head.getStart(sf) + q, node.head.end - 2])
    for (const span of node.templateSpans) {
      const lit = span.literal
      out.push([lit.getStart(sf) + 1, lit.end - (ts.isTemplateTail(lit) ? q : 2)])
    }
    return true
  }
  return false
}

/**
 * Walk an expression that yields classes. Its strings and template text are class lists;
 * a condition, a compared value and a non-class-merge call's arguments are not. With
 * `follow`, a name it reads is followed to its declaration in the same file, and a call to
 * the function it names is followed into that function's returns.
 */
function walkClasses(ts, sf, node, acc) {
  if (!node) return
  if (literalRanges(ts, node, sf, acc.ranges, acc.quoted)) {
    if (ts.isTemplateExpression(node)) for (const span of node.templateSpans) walkClasses(ts, sf, span.expression, acc)
    return
  }
  if (ts.isConditionalExpression(node)) {
    walkClasses(ts, sf, node.whenTrue, acc)
    walkClasses(ts, sf, node.whenFalse, acc)
  } else if (ts.isBinaryExpression(node)) {
    const op = node.operatorToken.kind
    const K = ts.SyntaxKind
    if (op === K.AmpersandAmpersandToken) walkClasses(ts, sf, node.right, acc)
    else if (op === K.BarBarToken || op === K.QuestionQuestionToken || op === K.PlusToken) {
      walkClasses(ts, sf, node.left, acc)
      walkClasses(ts, sf, node.right, acc)
    }
  } else if (ts.isCallExpression(node)) {
    const name = calleeName(ts, node.expression)
    // A class list built as an array: `[a, b].join(' ')`, `[a, x && b].filter(Boolean).join(' ')`.
    if (ts.isPropertyAccessExpression(node.expression) && ARRAY_JOINS.has(node.expression.name.text)) {
      walkClasses(ts, sf, node.expression.expression, acc)
      if (node.expression.name.text === 'concat') for (const arg of node.arguments) walkClasses(ts, sf, arg, acc)
    } else if (name && CLASS_HELPERS.has(name)) for (const arg of node.arguments) walkClasses(ts, sf, arg, acc)
    else if (acc.follow && ts.isIdentifier(node.expression)) {
      acc.ids.add(name)
      acc.follow(name)
    }
  } else if (ts.isIdentifier(node)) {
    acc.ids.add(node.text)
    acc.follow?.(node.text)
  } else if (ts.isPropertyAccessExpression(node) || ts.isElementAccessExpression(node)) {
    walkClasses(ts, sf, node.expression, acc)
  } else if (ts.isObjectLiteralExpression(node)) {
    for (const p of node.properties) {
      if (ts.isPropertyAssignment(p)) walkClasses(ts, sf, p.initializer, acc)
      else if (ts.isShorthandPropertyAssignment(p)) walkClasses(ts, sf, p.name, acc)
      else if (ts.isSpreadAssignment(p)) walkClasses(ts, sf, p.expression, acc)
    }
  } else if (ts.isArrayLiteralExpression(node)) {
    for (const el of node.elements) walkClasses(ts, sf, el, acc)
  } else if (
    ts.isParenthesizedExpression(node) ||
    ts.isAsExpression(node) ||
    ts.isNonNullExpression(node) ||
    ts.isTypeAssertionExpression(node) ||
    ts.isAwaitExpression(node) ||
    ts.isSpreadElement(node) ||
    (ts.isSatisfiesExpression && ts.isSatisfiesExpression(node))
  ) {
    walkClasses(ts, sf, node.expression, acc)
  } else if (ts.isArrowFunction(node) || ts.isFunctionExpression(node)) {
    walkReturns(ts, sf, node, acc)
  }
}

/** A function's results: its expression body, or every `return` in its block. */
function walkReturns(ts, sf, fn, acc) {
  if (!fn.body) return
  if (!ts.isBlock(fn.body)) return walkClasses(ts, sf, fn.body, acc)
  const visit = (n) => {
    if (ts.isFunctionLike(n)) return
    if (ts.isReturnStatement(n)) walkClasses(ts, sf, n.expression, acc)
    else ts.forEachChild(n, visit)
  }
  ts.forEachChild(fn.body, visit)
}

/** Every class-list span in a file, and the names its class lists read. `names` are
 * declarations another file's class list reads, followed here too. */
function readClassLists(src, names = new Set()) {
  const ts = loadTypeScript()
  const sf = parse(src)
  const declared = new Map()
  const roots = []
  const visit = (n) => {
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.initializer && !declared.has(n.name.text)) declared.set(n.name.text, n)
    else if (ts.isFunctionDeclaration(n) && n.name && !declared.has(n.name.text)) declared.set(n.name.text, n)
    if (ts.isJsxAttribute(n) && CLASS_NAMED.test(n.name.getText(sf)) && n.initializer) {
      roots.push(ts.isJsxExpression(n.initializer) ? n.initializer.expression : n.initializer)
    } else if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken) {
      const target = ts.isPropertyAccessExpression(n.left) ? n.left.name.text : ts.isIdentifier(n.left) ? n.left.text : null
      if (target && CLASS_NAMED.test(target)) roots.push(n.right)
    } else if ((ts.isBindingElement(n) || ts.isParameter(n)) && ts.isIdentifier(n.name) && CLASS_NAMED.test(n.name.text) && n.initializer) {
      roots.push(n.initializer)
    } else if (ts.isCallExpression(n) && CLASS_HELPERS.has(calleeName(ts, n.expression) ?? '')) {
      roots.push(n)
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
  const seen = new Set()
  const acc = { ranges: [], ids: new Set(), quoted: true }
  acc.follow = (name) => {
    if (seen.has(name)) return
    seen.add(name)
    const d = declared.get(name)
    if (!d) return
    if (ts.isVariableDeclaration(d)) walkClasses(ts, sf, d.initializer, acc)
    else walkReturns(ts, sf, d, acc)
  }
  for (const name of names) acc.follow(name)
  for (const r of roots) walkClasses(ts, sf, r, acc)
  return acc
}

/**
 * The source with everything but its class lists blanked, line breaks kept: className and
 * class attribute values and any prop named for classes (`contentClassName`, `toneClasses`),
 * the arguments of the class-merge helpers, the initialiser of any variable those use
 * (`const base = "…"`, a size map), and the returns of any function they call
 * (`className={toneFor(order)}`). An import path, a URL, a logger name or a prop value
 * (`size="text-meta"`) is not a class list.
 */
export function classText(src, { names = new Set() } = {}) {
  const keep = new Uint8Array(src.length)
  for (const [a, b] of readClassLists(src, names).ranges) keep.fill(1, a, b)
  let out = ''
  for (let i = 0; i < src.length; i++) out += keep[i] || src[i] === '\n' ? src[i] : ' '
  return out
}

/** The names every file's class lists read, so a constant exported from one file and
 * used in another's class list is checked where it is declared. */
export function classNames(sources) {
  const names = new Set()
  for (const src of sources) for (const id of readClassLists(src).ids) names.add(id)
  return names
}

/** Every JSX opening tag whose `<name` matches `pattern`, with the classes of its OWN
 * `className` and the names it reads (a constant, a map), never a call's. */
export function* openingTags(src, pattern) {
  const ts = loadTypeScript()
  const sf = parse(src)
  const tags = []
  const visit = (n) => {
    if (ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) tags.push(n)
    ts.forEachChild(n, visit)
  }
  visit(sf)
  for (const n of tags) {
    // The caller's pattern, matched only from the tag's start.
    pattern.lastIndex = 0
    const m = pattern.exec(`<${n.tagName.getText(sf)} `)
    if (!m || m.index !== 0) continue
    const acc = { ranges: [], ids: new Set() }
    const attr = n.attributes.properties.find((p) => ts.isJsxAttribute(p) && p.name.getText(sf) === 'className')
    if (attr?.initializer) walkClasses(ts, sf, ts.isJsxExpression(attr.initializer) ? attr.initializer.expression : attr.initializer, acc)
    const classes = acc.ranges.flatMap(([a, b]) => src.slice(a, b).split(/\s+/)).filter((c) => CLASS_SHAPE.test(c))
    const start = n.getStart(sf)
    yield { name: m[1], open: src.slice(start, n.end), line: sf.getLineAndCharacterOfPosition(start).line + 1, classes, ids: [...acc.ids] }
  }
}

/** Every constant a file declares, with the classes in its initialiser — a string, a
 * template, a class-merge call, an array or a map — so a className that names it is read
 * as those classes. `exported` collects the ones another file may import. */
export function constantClasses(src, exported = new Map()) {
  const ts = loadTypeScript()
  const sf = parse(src)
  const local = new Map()
  const visit = (n) => {
    if (ts.isVariableDeclaration(n) && ts.isIdentifier(n.name) && n.initializer) {
      const init = n.initializer
      const list =
        ts.isStringLiteral(init) ||
        ts.isNoSubstitutionTemplateLiteral(init) ||
        ts.isTemplateExpression(init) ||
        ts.isArrayLiteralExpression(init) ||
        ts.isObjectLiteralExpression(init) ||
        ts.isParenthesizedExpression(init) ||
        (ts.isCallExpression(init) && ts.isIdentifier(init.expression) && CONSTANT_HELPERS.has(init.expression.text))
      if (list) {
        const ranges = []
        const collect = (c) => {
          if (!literalRanges(ts, c, sf, ranges) || ts.isTemplateExpression(c)) ts.forEachChild(c, collect)
        }
        collect(init)
        const classes = ranges.flatMap(([a, b]) => src.slice(a, b).split(/\s+/)).filter(Boolean)
        if (classes.length) {
          local.set(n.name.text, classes)
          const stmt = n.parent?.parent
          if (stmt && ts.isVariableStatement(stmt) && stmt.modifiers?.some((mod) => mod.kind === ts.SyntaxKind.ExportKeyword)) exported.set(n.name.text, classes)
        }
      }
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
  return local
}

const isColour = (v) => /^(#[0-9a-f]{3,8}|oklch\(|oklab\(|rgba?\(|hsla?\(|color-mix\()/i.test(v.trim())

/** Every class a Tailwind `@source inline()` pattern names: `{bg,text}-{a,b}` → bg-a bg-b text-a text-b. */
export function expandBraces(pattern) {
  const m = /\{([^{}]*)\}/.exec(pattern)
  if (!m) return pattern.split(/\s+/).filter(Boolean)
  return m[1].split(',').flatMap((alt) => expandBraces(pattern.slice(0, m.index) + alt + pattern.slice(m.index + m[0].length)))
}

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
      out.push(`${file}  ${k}  — other tokens build on this colour, and the dark theme does not redefine it, so they stay light on a dark surface — give it a dark value: the same value when it should not change (a brand colour), a colour picked for dark, or one derived from its light value with color-mix(), e.g. color-mix(in oklab, <light value> 70%, black)`)
  return { problems: out, applies: true }
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

  const { dirs: sourceDirs, problems: sourceProblems } = uiSourceDirs(repo, pkgRel)
  if (sourceProblems.length) return { problems: [...problems, ...sourceProblems], notes, counts: null }
  const sourceFiles = [
    ...new Set(sourceDirs.flatMap((d) => globSync(`${d}/**/*.{ts,tsx}`, { cwd: repo }).map(posix))),
  ].filter((f) => !/\.(gen|generated)\.ts$/.test(f) && !/\/node_modules\//.test(f))

  if (!css.length || !sourceFiles.length) {
    problems.push(`scanned ${sourceFiles.length} source file(s) under ${sourceDirs.join(', ') || '(none)'} and ${css.length} stylesheet(s) — nothing to check means the design keys point at the wrong paths, or no workspace depends on the UI package`)
    return { problems, notes, counts: null }
  }
  const designPath = 'design.md'
  const design = existsSync(path.join(repo, designPath)) ? readFileSync(path.join(repo, designPath), 'utf8').replace(/\r\n/g, '\n') : null
  if (design === null) problems.push(`${designPath}  — not found at the repository root; the checks compare the code against it`)

  // --- the roles, read from the CSS -----------------------------------------
  const { colours, radiusRoles, weightRoles, fontFamilies, shadowRoles, textShadowRoles, spacingAliases, leadingRoles, trackingRoles, typeRoles, utilities } = rolesOf(css)
  // A t-shirt size is never a role name: `--radius-md`, `--shadow-lg` and `type-sm` are
  // sizes in token clothing, whichever stylesheet defines them.
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
  // The spacing scale: the project's own steps from its claude-design config, else the
  // kit's (design-opinion.md — 0, 4, 8, 12, 16, 24, 32, 48px).
  let spacingSteps = [0, 1, 2, 3, 4, 6, 8, 12]
  let spacingFrom = "the kit's default"
  const scaleConfig = path.join(pkg, 'design-system/design-system.config.mjs')
  if (existsSync(scaleConfig)) {
    const { readConfig } = await import(new URL('../../claude-design/scripts/config.mjs', import.meta.url).href)
    const { ctx } = await readConfig(scaleConfig)
    if (ctx?.CONFIG?.spacing?.steps) {
      spacingSteps = ctx.CONFIG.spacing.steps
      spacingFrom = `${pkgRel}/design-system/design-system.config.mjs`
    }
  }
  const onScale = new Set(spacingSteps.map(String))
  const scaleList = spacingSteps.map((n) => `${n * 4}`).join(', ')
  notes.push(`spacing scale: ${scaleList}px, from ${spacingFrom}; judged on changed lines only`)
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
      // A step between the scale's steps — judged on changed lines only, like the screen rules.
      each(new RegExp(`(?<![\\w-])-?(?:${SPACE_PROPS})-(\\d+(?:\\.5)?)(?![\\w-])`, 'g'), (m) => {
        if (onScale.has(m[1]) || (m[1].endsWith('.5') && m[1] !== '0.5') || !touched(file, i + 1)) return
        add(at, m[0], `not a step of the spacing scale (${scaleList}px); space between things is a named gap`)
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
  // A colour a screen or feature file fades belongs in a colour role of its own.
  const screenFinding = (base) => {
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
        if (FIXED_SIZE.test(cls.split(':').pop())) add(`${file}:${t.line}`, `<${t.name}> ${cls}`, 'a call site never fixes how tall a component is; that belongs to the component (a size or variant for what the control is)')
        const paint = /^(?:text|bg|border|ring|outline|fill|stroke)-(.+?)(?:\/\d+)?$/.exec(cls.split(':').pop())
        if (paint && colours.has(paint[1])) add(`${file}:${t.line}`, `<${t.name}> ${cls}`, 'a call site never repaints a component\'s colour; add a variant for what it shows')
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
      // A var() with a fallback resolves to the fallback when the token is unset — a value set at run time.
      for (const m of line.matchAll(/var\((--[A-Za-z0-9-]+)\s*(,)?/g)) if (!m[2] && !realDefs.has(m[1])) problems.push(`${file}:${i + 1}  ${m[1]}  — referenced but never defined; resolves to nothing`)
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
  // Tailwind v4's variable shorthand names the token in the utility: `min-h-(--x)`,
  // `hover:bg-(--x)`, `bg-(color:--x)` with a type hint, in a class or an @apply.
  for (const src of [componentSrc, ...css.map(([, s]) => s)])
    for (const m of src.matchAll(/(?<![\w-])[a-z][a-z0-9-]*-\((?:[a-z-]+:)?(--[A-Za-z0-9-]+)\)/g)) reached.add(m[1])
  // A breakpoint is used through the variant Tailwind names after it: `tablet:` and
  // `max-tablet:` in a class, `@variant tablet { … }` in a stylesheet.
  const variants = new Set()
  for (const src of [componentSrc, ...css.map(([, s]) => s)]) for (const m of src.matchAll(/(?<![\w-])(?:max-|min-)?([a-z][a-z0-9-]*):(?=[a-z!-])/g)) variants.add(m[1])
  for (const [, s] of css) for (const m of s.matchAll(/@variant\s+(?:max-|min-)?([a-z][a-z0-9-]*)\s*\{/g)) variants.add(m[1])
  for (const name of realDefs) {
    const bp = /^--breakpoint-(.+)$/.exec(name)
    if (bp && variants.has(bp[1])) reached.add(name)
  }
  // A project that publishes to Claude Design promises designs a bg-/text-/border- class for
  // every published colour, and its generated safelist ships them: the theme entries behind
  // those classes are used by the published system even before a screen writes one.
  let safelistCss = ''
  const publishConfig = path.join(pkg, 'design-system/design-system.config.mjs')
  if (existsSync(publishConfig)) {
    const { readConfig } = await import(new URL('../../claude-design/scripts/config.mjs', import.meta.url).href)
    const { ctx } = await readConfig(publishConfig)
    const file = ctx && path.join(pkg, ctx.CONFIG.generated.safelist)
    if (file && existsSync(file)) safelistCss = [...readFileSync(file, 'utf8').matchAll(/@source\s+inline\("([^"]*)"\)/g)].flatMap((m) => expandBraces(m[1])).join(' ')
  }
  const written = new Set()
  for (const src of [componentSrc, safelistCss, ...css.map(([, s]) => s)]) for (const m of src.matchAll(/(?<![\w-])[a-z][a-z0-9-]*(?![\w-])/g)) written.add(m[0])
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

  // --- every text pair is readable on its background ------------------------
  const contrast = contrastProblems(tokenCss, design)
  problems.push(...contrast.problems)
  for (const s of contrast.skipped) notes.push(`contrast: skipped ${s}`)
  for (const e of contrast.exempt) notes.push(`contrast: exempt ${e} — an inactive control's text (WCAG 1.4.3)`)

  // --- the patterns name only what exists ------------------------------------
  // A role, token or component a pattern reference names in code is one the system has:
  // a type role the stylesheets define, a custom property they declare, a component the
  // UI source defines or imports. A property is checked only in a family the stylesheets
  // declare (`--color-*`, `--radius-*`); another family is a library's own (`--radix-*`).
  // Whether a name is the right one is the design review's call.
  const patternsDir = path.join(repo, '.claude/skills/ui-patterns/references')
  const patternFiles = existsSync(patternsDir) ? readdirSync(patternsDir).filter((f) => f.endsWith('.md') && f !== 'README.md').sort() : []
  if (patternFiles.length) {
    const components = new Set()
    for (const src of sources.values()) {
      for (const m of src.matchAll(/export\s+(?:default\s+)?(?:async\s+)?(?:function|const|class)\s+([A-Z]\w*)/g)) components.add(m[1])
      for (const m of src.matchAll(/(?:export|import)\s+(?:type\s+)?\{([^}]+)\}/g))
        for (const n of m[1].split(',')) {
          const id = n.trim().split(/\s+as\s+/).pop()
          if (/^[A-Z]/.test(id)) components.add(id)
        }
      for (const m of src.matchAll(/import\s+([A-Z]\w*)\s*(?:,|\s+from)/g)) components.add(m[1])
    }
    const properties = new Set()
    for (const [, src] of css) for (const m of src.matchAll(/(--[A-Za-z0-9-]+)\s*:/g)) properties.add(m[1])
    const family = (name) => name.slice(2).split('-')[0]
    const families = new Set([...properties].map(family))
    for (const f of patternFiles) {
      const at = `.claude/skills/ui-patterns/references/${f}`
      const lines = readFileSync(path.join(patternsDir, f), 'utf8').replace(/\r\n/g, '\n').split('\n')
      let fenced = false
      lines.forEach((line, i) => {
        if (/^\s*```/.test(line)) {
          fenced = !fenced
          return
        }
        if (/design-accepted/.test(line) || /design-accepted/.test(lines[i - 1] ?? '')) return
        for (const code of fenced ? [line] : [...line.matchAll(/`([^`]+)`/g)].map((m) => m[1])) {
          for (const m of code.matchAll(/(?<![\w-])(type-[a-z0-9-]*[a-z0-9])/g))
            if (!typeRoles.has(m[1])) add(`${at}:${i + 1}`, m[1], 'a pattern names a type role the stylesheets do not define')
          for (const m of code.matchAll(/(?<![\w-])(--[A-Za-z][A-Za-z0-9-]*[A-Za-z0-9])/g))
            if (families.has(family(m[1])) && !properties.has(m[1])) add(`${at}:${i + 1}`, m[1], 'a pattern names a token the stylesheets do not declare')
          // An element is code: a fenced block, or an inline span that opens with it. A
          // generic (`Column<Row>`) or a label template (`Download <Document> PDF`) is not.
          if (!fenced && !code.trimStart().startsWith('<')) continue
          for (const m of code.matchAll(/(?<![\w.])<([A-Z][A-Za-z0-9]*)(?=[\s/>])/g))
            if (!components.has(m[1])) add(`${at}:${i + 1}`, `<${m[1]}>`, 'a pattern names a component the UI source neither defines nor imports')
        }
      })
    }
  }

  // --- design.md describes what the code is ---------------------------------
  if (design !== null) {
    const lineOf = (i) => design.slice(0, i).split('\n').length
    const declared = {}
    let group = null
    // The frontmatter is what lies between the first two lines that are exactly `---`;
    // a `---` inside a YAML comment or a value does not end it.
    for (const line of (design.split(/^---$/m)[1] ?? '').split('\n')) {
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
    // A pixel value the frontmatter states is on the grid, unless the stylesheets declare
    // it (an odd type step, a pill's 999) or it is a 1px hairline.
    const declaredPx = new Set()
    for (const [, s] of css) for (const m of s.matchAll(/(?<![\w.])(\d+(?:\.\d+)?)px/g)) declaredPx.add(m[1])
    const fmStart = design.search(/^---$/m)
    const fmEnd = fmStart < 0 ? -1 : design.slice(fmStart + 3).search(/^---$/m)
    const frontmatter = fmEnd < 0 ? '' : design.slice(0, fmStart + 3 + fmEnd)
    for (const m of frontmatter.matchAll(/(?<![\w.])(\d+(?:\.\d+)?)px/g)) {
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
      contrastPairs: contrast.pairs,
      contrastMeasured: contrast.measured,
      themes: contrast.themes,
      generated: generatedChecked,
      projectChecks: projectChecks.length,
      patterns: patternFiles.length,
    },
  }
}

async function main() {
  // The repository root, from this script's own place: .claude/skills/design-system/scripts/.
  const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..')
  const argv = process.argv.slice(2)
  if (argv.includes('--roles') || argv.includes('--purposes')) {
    const at = argv.indexOf('--repo')
    const of = at >= 0 ? path.resolve(argv[at + 1]) : repo
    const roles = argv.includes('--purposes') ? rolePurposes(of) : roleList(of)
    if (!roles) {
      console.error('design roles: the design keys in .claude/sync-substitutions.json are not set')
      process.exit(2)
    }
    console.log(roles)
    return
  }
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
      `${counts.colours} colours; ${counts.tokens} tokens resolve; ${counts.contrastPairs} text pairs measured in ${counts.themes} theme(s) (${counts.contrastMeasured} measurements); ${counts.generated} generated files current; ${counts.projectChecks} project checks; ${counts.patterns} pattern references`,
  )
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) await main()
