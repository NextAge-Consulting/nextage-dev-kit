/* Loads a project's design-system config for every engine script, the way the
 * engine reads it: the project's paths from .claude/sync-substitutions.json, the
 * boilerplate from the defaults below, the content from the config. A config key
 * the engine does not read, a required key left out, or a substitution not set
 * fails by name — never a silent default for a value only the project knows.
 *
 * The engine is built for the kit's UI stack — Tailwind v4, shadcn/Radix,
 * @fontsource-variable fonts, an icon package (or local module) exporting `icons`,
 * React 18 on the design page — and `checkPrerequisites` fails by name when a
 * piece of it is missing from the UI package. Every package is resolved from the
 * UI package's own package.json, never the repository root, so a workspace that
 * declares its own esbuild or font gets exactly that one. */

import { execSync } from 'node:child_process'
import fs from 'node:fs'
import { createRequire } from 'node:module'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

/** Where the config lives inside the UI package. */
export const CONFIG_REL = 'design-system/design-system.config.mjs'

/** The substitutions the engine reads. `required` ones must hold a value; the
 * others may be empty, which turns that part off. */
export const DESIGN_KEYS = {
  DESIGN_UI_PACKAGE: { required: true, list: false },
  DESIGN_FEED_BARREL: { required: true, list: false },
  DESIGN_TOKEN_FILES: { required: true, list: true },
  DESIGN_TYPE_FILE: { required: false, list: false },
  DESIGN_STYLES_FILE: { required: false, list: false },
}

/* The config's shape. Each key: 'required', 'optional', or a nested shape. A
 * nested shape marked `$optional` may be left out whole. */
const SHAPE = {
  title: 'required',
  namespace: 'required',
  artifact: 'required',
  tagline: 'optional',
  timeZone: 'required',
  tsconfig: 'optional',
  typeRoles: { $optional: true, utilityPrefix: 'optional' },
  typeFamilies: 'optional',
  themeSelectors: 'optional',
  families: { $optional: true, radius: 'optional', shadow: 'optional', skip: 'optional' },
  spacing: { base: 'optional', steps: 'required' },
  css: { build: 'required', file: 'required', darkClass: 'optional', lightClass: 'optional' },
  types: { $optional: true, build: 'required', dir: 'required' },
  icons: 'optional',
  previewStyle: 'optional',
  readme: { $optional: true, source: 'optional', sections: 'optional', vocabularyIntro: 'optional', vocabulary: 'optional' },
  docSources: { $optional: true, inventory: 'optional', design: 'optional', sourceRoot: 'optional' },
  components: 'required',
  requiredProps: 'optional',
  notPreviewed: 'optional',
  cover: 'optional',
  assets: 'optional',
  out: 'optional',
  generated: { $optional: true, safelist: 'optional', classMerge: 'optional' },
}
/** Where the value of a key that is not the config's lives. */
const ELSEWHERE = {
  package: 'the UI package is the folder the config sits in, and DESIGN_UI_PACKAGE in .claude/sync-substitutions.json',
  feed: 'the feed barrel is DESIGN_FEED_BARREL in .claude/sync-substitutions.json',
  tokens: 'the token files are DESIGN_TOKEN_FILES in .claude/sync-substitutions.json',
  styles: 'the styles file is DESIGN_STYLES_FILE in .claude/sync-substitutions.json',
  'typeRoles.file': 'the type-role file is DESIGN_TYPE_FILE in .claude/sync-substitutions.json',
}
const COMPONENT_SHAPE = { name: 'required', group: 'required', height: 'required', width: 'optional', cardMode: 'optional', doc: 'required', render: 'required' }

/** Every problem with a config's keys, each naming the key: unknown, missing, wrong type. */
export function validateConfig(config) {
  const problems = []
  const walk = (obj, shape, at) => {
    for (const key of Object.keys(obj)) {
      if (!(key in shape) || key === '$optional')
        problems.push(`${at}${key}: not a config key the engine reads — ${ELSEWHERE[`${at}${key}`] ?? 'see references/config-example.mjs'}`)
    }
    for (const [key, rule] of Object.entries(shape)) {
      if (key === '$optional') continue
      const v = obj[key]
      if (typeof rule === 'object') {
        if (v === undefined) {
          if (!rule.$optional) problems.push(`${at}${key}: required, and missing`)
        } else if (typeof v !== 'object' || Array.isArray(v) || v === null) problems.push(`${at}${key}: must be an object`)
        else walk(v, rule, `${at}${key}.`)
      } else if (rule === 'required' && (v === undefined || v === null)) problems.push(`${at}${key}: required, and missing`)
    }
  }
  if (!config || typeof config !== 'object') return ['the config has no default export object']
  walk(config, SHAPE, '')
  if (config.components !== undefined) {
    if (!Array.isArray(config.components)) problems.push('components: must be an array')
    else
      config.components.forEach((c, i) => {
        const at = `components[${c?.name ?? i}].`
        for (const key of Object.keys(c ?? {})) if (!(key in COMPONENT_SHAPE)) problems.push(`${at}${key}: not a component key the engine reads`)
        for (const [key, rule] of Object.entries(COMPONENT_SHAPE)) if (rule === 'required' && c?.[key] === undefined) problems.push(`${at}${key}: required, and missing`)
        if (c?.cardMode !== undefined && c.cardMode !== 'overlay') problems.push(`${at}cardMode: the only mode is 'overlay'`)
      })
  }
  if (config.spacing?.steps !== undefined && !Array.isArray(config.spacing.steps)) problems.push('spacing.steps: must be an array of numbers')
  for (const [key, v] of Object.entries(config.families ?? {}))
    if (key in SHAPE.families && !(v instanceof RegExp)) problems.push(`families.${key}: must be a RegExp literal such as /^radius-/, not a string: ${JSON.stringify(v)}`)
  return problems
}

/** The design keys from a repository's .claude/sync-substitutions.json, split into
 * lists where the key is a list; problems name each key missing or empty that the
 * engine needs. */
export function readDesignSubstitutions(repo, keys = DESIGN_KEYS) {
  const file = path.join(repo, '.claude/sync-substitutions.json')
  const problems = []
  let subs = {}
  if (!fs.existsSync(file)) problems.push('.claude/sync-substitutions.json not found — the design keys live there')
  else subs = JSON.parse(fs.readFileSync(file, 'utf8'))
  const values = {}
  for (const [key, spec] of Object.entries(keys)) {
    const raw = subs[key]
    if (raw === undefined) {
      if (fs.existsSync(file)) problems.push(`${key}: not set in .claude/sync-substitutions.json`)
      values[key] = spec.list ? [] : ''
      continue
    }
    const v = String(raw).trim()
    if (spec.required && !v) problems.push(`${key}: empty in .claude/sync-substitutions.json, and the engine needs it`)
    values[key] = spec.list ? v.split(/\s+/).filter(Boolean) : v
  }
  return { values, problems }
}

/** Apply the engine's defaults and the substitutions to a validated config. */
export function withDefaults(config, subs) {
  const c = structuredClone({ ...config, components: undefined })
  c.components = config.components
  c.package = subs.DESIGN_UI_PACKAGE
  c.feed = subs.DESIGN_FEED_BARREL
  c.tokens = subs.DESIGN_TOKEN_FILES
  c.styles = subs.DESIGN_STYLES_FILE || undefined
  c.typeRoles = subs.DESIGN_TYPE_FILE ? { file: subs.DESIGN_TYPE_FILE, utilityPrefix: config.typeRoles?.utilityPrefix ?? 'type-' } : undefined
  c.typeFamilies = config.typeFamilies ?? { sans: 'font-sans', mono: 'font-mono' }
  c.families = { radius: /^radius-/, shadow: /^shadow-/, skip: /^$/, ...config.families }
  c.spacing = { base: 4, ...config.spacing }
  c.css = { darkClass: '.dark', lightClass: '.light', ...config.css }
  c.types = config.types ?? {
    build: 'npx tsc -p design-system/tsconfig.types.json',
    dir: path.posix.join('dist/design-system-types', path.posix.dirname(c.feed)),
  }
  c.tsconfig = config.tsconfig ?? 'tsconfig.json'
  c.readme = { source: 'design.md', ...config.readme }
  c.docSources = { inventory: '.claude/rules/project/ui-inventory.md', design: 'design.md', sourceRoot: 'src', ...config.docSources }
  c.out = config.out ?? 'dist/design-system'
  c.generated = { safelist: 'design-system/safelist.generated.css', classMerge: 'src/lib/design-tokens.generated.ts', ...config.generated }
  return c
}

/** Read, validate and complete a config: `{ problems, ctx }`, where ctx is
 * `{ CONFIG, CONFIG_FILE, CONFIG_DIR, REPO, PKG }` when there are no problems. */
export async function readConfig(configPath) {
  // Real path: git reports the repository's real path, and a config reached through
  // a symlink (a temp folder on macOS) would otherwise sit "outside" it.
  const CONFIG_FILE = fs.realpathSync(path.resolve(configPath))
  const CONFIG_DIR = path.dirname(CONFIG_FILE)
  const REPO = execSync('git rev-parse --show-toplevel', { cwd: CONFIG_DIR }).toString().trim()
  const raw = (await import(pathToFileURL(CONFIG_FILE).href)).default
  const problems = validateConfig(raw)
  const { values, problems: subProblems } = readDesignSubstitutions(REPO)
  problems.push(...subProblems)
  // The UI package is the folder the config sits in, one level up; the
  // substitution has to name the same one, or the checker and the engine read
  // different packages.
  const derived = path.relative(REPO, path.dirname(CONFIG_DIR)).split(path.sep).join('/')
  if (path.basename(CONFIG_DIR) !== 'design-system') problems.push(`the config sits in ${path.relative(REPO, CONFIG_DIR)} — it belongs at <UI package>/${CONFIG_REL}`)
  else if (values.DESIGN_UI_PACKAGE && values.DESIGN_UI_PACKAGE.replace(/\/$/, '') !== derived)
    problems.push(`DESIGN_UI_PACKAGE is "${values.DESIGN_UI_PACKAGE}" but the config sits in ${derived}/design-system`)
  if (problems.length) return { problems, ctx: null }
  const CONFIG = withDefaults(raw, { ...values, DESIGN_UI_PACKAGE: derived })
  return { problems, ctx: { CONFIG, CONFIG_FILE, CONFIG_DIR, REPO, PKG: path.join(REPO, CONFIG.package) } }
}

/** readConfig for a command-line script: exits 2, naming every problem, when the
 * config or the substitutions are not usable. */
export async function loadConfig(configPath, { tool = 'design-system' } = {}) {
  if (!configPath) {
    console.error(`usage: ${tool} <path/to/${CONFIG_REL}>`)
    process.exit(2)
  }
  const { problems, ctx } = await readConfig(configPath)
  if (problems.length) {
    console.error(`${tool}: ${problems.length} config problem(s) — ${path.relative(process.cwd(), path.resolve(configPath))}\n`)
    for (const p of problems) console.error(`  ✗ ${p}`)
    process.exit(2)
  }
  return ctx
}

/** A require() bound to the UI package, so every package resolves from it. */
export function packageRequire(PKG) {
  return createRequire(path.join(PKG, 'package.json'))
}

/** The `icons` value as esbuild should import it: a package name stays as it is,
 * a relative path resolves against the config's own folder. */
export function iconsSpecifier(icons, CONFIG_DIR) {
  if (!icons) return null
  return /^\.{1,2}\//.test(icons) ? path.resolve(CONFIG_DIR, icons) : icons
}

/** The engine's stack, checked before any work: each missing piece named. */
export function checkPrerequisites({ CONFIG, CONFIG_DIR, PKG }) {
  const req = packageRequire(PKG)
  const problems = []
  // Found the way Node would find the package from the UI package, read from its
  // folder directly: not every package exports its package.json.
  const version = (name) => {
    for (const dir of req.resolve.paths(name) ?? []) {
      const file = path.join(dir, name, 'package.json')
      if (!fs.existsSync(file)) continue
      // A package.json that does not parse is a broken install, never "not installed".
      try {
        return JSON.parse(fs.readFileSync(file, 'utf8')).version
      } catch (err) {
        throw new Error(`${file} is not valid JSON — reinstall ${name}`, { cause: err })
      }
    }
    return null
  }
  if (!fs.existsSync(path.join(PKG, 'package.json'))) problems.push(`${CONFIG.package}/package.json not found — the UI package is where the engine resolves its stack`)
  if (!version('esbuild')) problems.push(`esbuild: not installed for ${CONFIG.package} — add it as a dev dependency there`)
  const tw = version('tailwindcss')
  if (!tw) problems.push(`tailwindcss: not installed for ${CONFIG.package} — the engine is built for Tailwind v4`)
  else if (Number(tw.split('.')[0]) < 4) problems.push(`tailwindcss ${tw}: the engine is built for Tailwind v4`)
  if (/\btailwindcss\b/.test(CONFIG.css.build) && !version('@tailwindcss/cli')) problems.push(`@tailwindcss/cli: css.build runs the Tailwind CLI, which is not installed for ${CONFIG.package}`)
  const icons = iconsSpecifier(CONFIG.icons, CONFIG_DIR)
  if (icons && path.isAbsolute(icons)) {
    if (!['', '.ts', '.tsx', '.js', '.mjs', '.jsx'].some((ext) => fs.existsSync(icons + ext))) problems.push(`icons: ${CONFIG.icons} not found beside the config`)
  } else if (icons && !version(icons)) problems.push(`icons: the package ${icons} is not installed for ${CONFIG.package}`)
  return problems
}
