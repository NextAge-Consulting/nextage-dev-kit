/* The design system as the engine reads it from the UI package's CSS: colour
 * tokens resolved per theme, radius and shadow families, spacing, type roles and
 * fonts — and the class vocabulary the system promises a design. build.mjs writes
 * the artifact from it; generate.mjs writes the files a project imports from it;
 * the token checker compares those files against it. One reading, so the three
 * never disagree about what the system holds.
 *
 * Problems are collected, never thrown one at a time, so a run names every
 * offender at once. */

import fs from 'node:fs'
import path from 'node:path'
import { packageRequire } from './config.mjs'
import { DEFAULT_THEME_SELECTORS, isColorValue, parseTokenBlocks, resolveColor } from './resolve.mjs'

/** The spacing utilities the README promises at every spacing step. */
export const SPACING_UTILITIES = ['p', 'px', 'py', 'pt', 'pr', 'pb', 'pl', 'm', 'mx', 'my', 'mt', 'mr', 'mb', 'ml', 'gap', 'gap-x', 'gap-y']

/** A source file as text with LF line endings. Every parse in the engine matches
 * `\n`, and a Windows checkout under core.autocrlf hands over CRLF. */
export function readText(file) {
  return fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n')
}

export function buildModel({ CONFIG, PKG }) {
  const problems = []
  const notCarried = []
  const missing = new Set()
  const read = (rel) => {
    const file = path.join(PKG, rel)
    if (fs.existsSync(file)) return readText(file)
    if (!missing.has(rel)) problems.push(`${CONFIG.package}/${rel}: not found`)
    missing.add(rel)
    return ''
  }
  // RegExp literals from the config or the engine's defaults — never built from a string.
  const families = CONFIG.families

  // ─── token CSS → per-theme environments ──────────────────────────────────
  let blocks = []
  for (const rel of CONFIG.tokens) {
    try {
      blocks = blocks.concat(parseTokenBlocks(read(rel), CONFIG.themeSelectors ?? DEFAULT_THEME_SELECTORS))
    } catch (e) {
      problems.push(`${rel}: ${e.message}`)
    }
  }
  const lightDecls = blocks.filter((b) => b.theme === 'light').flatMap((b) => b.decls)
  const darkDecls = blocks.filter((b) => b.theme === 'dark').flatMap((b) => b.decls)
  const lightEnv = new Map(lightDecls.map((d) => [d.name, d.value]))
  const darkEnv = new Map([...lightEnv, ...darkDecls.map((d) => [d.name, d.value])])
  const usageOf = new Map(lightDecls.map((d) => [d.name, d.usage]))
  const requireUsage = (name) => {
    const u = usageOf.get(name)
    if (!u) problems.push(`--${name}: no usage comment — every token says what it is for`)
    return u ?? ''
  }

  const chase = (v, env, depth = 0) => {
    const ref = /^var\(--([\w-]+)\)$/.exec(v)
    return ref && depth < 16 ? chase(env.get(ref[1]) ?? '', env, depth + 1) : v
  }
  const colorNames = new Set(
    lightDecls.filter((d) => isColorValue(d.value) || (/^var\(--[\w-]+\)$/.test(d.value) && isColorValue(chase(d.value, lightEnv)))).map((d) => d.name),
  )

  const colorTokens = []
  for (const d of lightDecls) {
    if (!colorNames.has(d.name)) continue
    const value = {}
    for (const [theme, env] of [
      ['light', lightEnv],
      ['dark', darkEnv],
    ]) {
      try {
        value[theme] = resolveColor(env.get(d.name), env, colorNames)
      } catch (e) {
        problems.push(`--${d.name} (${theme}): ${e.message}`)
      }
    }
    if (value.dark === value.light) delete value.dark
    colorTokens.push({ name: d.name, value, usage: requireUsage(d.name) })
  }
  if (!colorTokens.length) problems.push(`no colour tokens found in ${CONFIG.tokens.join(', ')} — the token files hold the system's colours, so a read of none means the paths or the theme selectors are wrong`)

  // Every other token lands in a family, or is one the config says the type
  // roles or spacing consume.
  const radius = []
  const shadow = []
  for (const d of lightDecls) {
    if (colorNames.has(d.name) || families.skip.test(d.name)) continue
    if (families.radius.test(d.name)) radius.push({ name: d.name, value: d.value, usage: requireUsage(d.name) })
    else if (families.shadow.test(d.name)) {
      const dark = darkEnv.get(d.name)
      shadow.push({ name: d.name, value: dark === d.value ? d.value : { light: d.value, dark }, usage: requireUsage(d.name) })
    } else problems.push(`--${d.name}: no design-system family for this token — map it in the config's families rather than dropping it`)
  }

  // Spacing: the framework's scale as named steps, plus named measurements the
  // styles expose as spacing aliases (`--spacing-control: var(--size-control)`).
  const stylesCss = CONFIG.styles ? read(CONFIG.styles) : ''
  const spacing = CONFIG.spacing.steps.map((n) => ({
    name: `spacing-${n}`,
    value: `${n * CONFIG.spacing.base}px`,
    usage: `Step ${n} — \`p-${n}\`, \`gap-${n}\`, \`m-${n}\`.`,
  }))
  const spacingAliases = []
  for (const m of stylesCss.matchAll(/--spacing-([\w-]+):\s*var\(--([\w-]+)\)/g)) {
    spacingAliases.push(m[1])
    spacing.push({ name: `spacing-${m[1]}`, value: lightEnv.get(m[2]), usage: requireUsage(m[2]) })
  }
  // Weight roles the CSS exposes (`--font-weight-body: …`), as `font-<role>`.
  const allCss = [stylesCss, ...CONFIG.tokens.map(read), CONFIG.typeRoles ? read(CONFIG.typeRoles.file) : ''].join('\n')
  const weights = [...new Set([...allCss.matchAll(/--font-weight-([\w-]+)\s*:/g)].map((m) => m[1]))]

  // ─── type roles ──────────────────────────────────────────────────────────
  const groups = []
  const typePrefix = CONFIG.typeRoles?.utilityPrefix ?? 'type-'
  if (CONFIG.typeRoles) {
    const typeCss = read(CONFIG.typeRoles.file)
    const scale = (v) => v?.replace(/var\(--([\w-]+)\)/, (_, n) => lightEnv.get(n))
    let group = null
    const items = [
      ...[...typeCss.matchAll(/\/\*\s*─+\s*([^─*]+?)\s*─+\s*\*\//g)].map((m) => ({ at: m.index, header: m[1].trim() })),
      ...[...typeCss.matchAll(/@utility ([\w-]+)\s*\{([\s\S]*?)\n\}/g)]
        .filter((m) => m[1].startsWith(typePrefix))
        .map((m) => ({ at: m.index, name: m[1].slice(typePrefix.length), body: m[2] })),
    ].sort((a, b) => a.at - b.at)
    for (const it of items) {
      if (it.header) {
        group = { name: it.header.charAt(0).toUpperCase() + it.header.slice(1), family: 'sans', styles: [] }
        groups.push(group)
        continue
      }
      const before = typeCss.slice(0, it.at).trimEnd()
      const c = /\/\*((?:(?!\*\/)[\s\S])*)\*\/$/.exec(before)
      const usage = c && !/─|={5}/.test(c[1]) ? c[1].replace(/\s+/g, ' ').trim() : ''
      if (!usage) problems.push(`${typePrefix}${it.name}: no usage comment above it in ${CONFIG.typeRoles.file}`)
      const base = it.body.replace(/@media[\s\S]*?\}/, '')
      const declared = Object.fromEntries([...base.matchAll(/(?:^|\n)\s*([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]))
      const get = (k) => declared[k]
      const style = {
        name: it.name,
        fontSize: scale(get('font-size')),
        lineHeight: scale(get('line-height')),
        fontWeight: Number(scale(get('font-weight'))),
        usage,
      }
      const ls = get('letter-spacing')
      if (ls) style.letterSpacing = scale(ls)
      if (get('font-family')) style.family = 'mono'
      if (!style.fontSize || !style.lineHeight || !style.fontWeight) problems.push(`${typePrefix}${it.name}: missing size, line height or weight`)
      if (/@media/.test(it.body)) notCarried.push(`\`${typePrefix}${it.name}\` changes size at a breakpoint; the format holds one, so it carries the base size (its usage note names the other).`)
      if (/font-variant-numeric/.test(it.body)) notCarried.push(`\`${typePrefix}${it.name}\` sets \`font-variant-numeric\`, which the format has no field for.`)
      if (!group) problems.push(`${typePrefix}${it.name}: sits above the first group header in ${CONFIG.typeRoles.file}`)
      else group.styles.push(style)
    }
  }

  // ─── fonts: variable fonts the styles import from @fontsource-variable ───
  const req = packageRequire(PKG)
  const fonts = []
  for (const m of stylesCss.matchAll(/@import\s+"@fontsource-variable\/([\w-]+)"/g)) {
    const pkg = m[1]
    const file = `${pkg}-latin-wght-normal.woff2`
    let src
    try {
      src = req.resolve(`@fontsource-variable/${pkg}/files/${file}`)
    } catch {
      problems.push(`font @fontsource-variable/${pkg}: ${file} not found from ${CONFIG.package} — install the font there`)
      continue
    }
    fonts.push({ src, entry: { family: `${pkg.charAt(0).toUpperCase()}${pkg.slice(1)} Variable`, file: `fonts/${file}`, weight: '100 900', style: 'normal' } })
  }

  return { problems, notCarried, families, lightDecls, darkDecls, lightEnv, colorTokens, radius, shadow, spacing, spacingAliases, weights, groups, typePrefix, fonts }
}

/** Every class the README promises a design: each spacing step on each spacing
 * utility, each colour token as fill, text and border, each radius role and each
 * type role. The package's CSS must ship every one. */
export function promisedClasses(model, CONFIG) {
  return [
    ...CONFIG.spacing.steps.flatMap((n) => SPACING_UTILITIES.map((u) => `${u}-${n}`)),
    ...model.colorTokens.flatMap((t) => ['bg', 'text', 'border'].map((u) => `${u}-${t.name}`)),
    ...model.radius.map((t) => t.name.replace(model.families.radius, 'rounded-')),
    ...model.groups.flatMap((g) => g.styles.map((st) => `${model.typePrefix}${st.name}`)),
  ]
}
