#!/usr/bin/env node
/* design.md, generated from the token stylesheet.
 *
 *   node .claude/skills/claude-design/scripts/design-md.mjs [--repo <root>] [--check]
 *
 * The token stylesheet and the components are the system; design.md is a published view
 * of it in the DESIGN.md format, so it can never disagree with the stylesheet. This
 * script writes the file's token frontmatter — colors, typography, rounded, spacing —
 * from the same reading of the stylesheets the Claude Design build uses (model.mjs), and
 * keeps everything hand-written: the `components:` block, which has no source in code,
 * and the prose body. The stylesheet's publish markers decide what is carried: a token
 * inside /* publish: off *\/ … /* publish: on *\/ is left out here as it is left out of
 * the published system.
 *
 * With a design-system config (<UI package>/design-system/design-system.config.mjs) the
 * config's spacing steps and type prefix are read; without one, the defaults apply and the
 * project's paths come from the DESIGN_* keys alone. A project with no design.md gets one
 * with the spec's sections as empty headings for the human to fill.
 *
 * --check writes nothing and exits 1 when the file's frontmatter differs from what would
 * be generated; the token checker runs the same comparison. build.mjs and generate.mjs
 * write the file as part of the build. */

import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { execSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { CONFIG_REL, readConfig, readDesignSubstitutions, withDefaults } from './config.mjs'
import { buildModel } from './model.mjs'

const Color = createRequire(import.meta.url)('../vendor/color.cjs').default

const SECTIONS = ['Overview', 'Colors', 'Typography', 'Layout', 'Elevation & Depth', 'Shapes', 'Components', "Do's and Don'ts"]

/** The engine's context for a repository: its config when it has one, else the defaults
 * over the DESIGN_* keys. Problems name what is missing. */
export async function contextFor(repo) {
  const { values, problems } = readDesignSubstitutions(repo)
  if (problems.length) return { problems, ctx: null }
  const configFile = path.join(repo, values.DESIGN_UI_PACKAGE, CONFIG_REL)
  if (fs.existsSync(configFile)) return readConfig(configFile)
  const CONFIG = withDefaults(
    { title: '', namespace: '', artifact: '', timeZone: 'UTC', spacing: { steps: [] }, css: { build: '', file: '' }, components: [] },
    values,
  )
  return { problems: [], ctx: { CONFIG, CONFIG_FILE: null, CONFIG_DIR: null, REPO: repo, PKG: path.join(repo, CONFIG.package) } }
}

/** A colour the format writes: hex, from any value the engine resolves. */
function hex(value) {
  return new Color(value).to('srgb').toString({ format: 'hex', collapse: false })
}

/** The frontmatter's token groups from the model, as YAML lines. */
export function tokenFrontmatter(model) {
  const lines = []
  const byName = new Map(model.colorTokens.map((t) => [t.name, t]))
  const resolve = (v, depth = 0) => {
    const alias = /^\{([\w-]+)\}$/.exec(v)
    if (!alias) return v
    const t = byName.get(alias[1])
    if (!t || depth > 16) throw new Error(`colour alias ${v} names no published token`)
    return resolve(t.value.light, depth + 1)
  }
  if (model.colorTokens.length) {
    lines.push('colors:')
    for (const t of model.colorTokens) lines.push(`  ${t.name}: "${hex(resolve(t.value.light))}"`)
  }
  const styles = model.groups.flatMap((g) => g.styles.map((s) => ({ ...s, group: g })))
  if (styles.length) {
    lines.push('typography:')
    for (const s of styles) {
      lines.push(`  ${s.name}:`)
      lines.push(`    fontFamily: "${s.family === 'mono' ? 'mono' : 'sans'}"`)
      lines.push(`    fontSize: ${s.fontSize}`)
      lines.push(`    lineHeight: ${s.lineHeight}`)
      lines.push(`    fontWeight: ${s.fontWeight}`)
      if (s.letterSpacing) lines.push(`    letterSpacing: ${s.letterSpacing}`)
    }
  }
  if (model.radius.length) {
    lines.push('rounded:')
    for (const t of model.radius) lines.push(`  ${t.name.replace(model.families.radius, '')}: ${t.value}`)
  }
  if (model.spacing.length) {
    lines.push('spacing:')
    for (const t of model.spacing) lines.push(`  ${t.name.replace(/^spacing-/, '')}: ${t.value}`)
  }
  return lines
}

/** The existing file's hand-written parts: its `components:` block and its body. */
export function handWritten(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/)
  if (!m) return { components: [], body: text }
  const front = m[1].split('\n')
  const components = []
  let inside = false
  for (const line of front) {
    if (/^components:\s*$/.test(line)) {
      inside = true
      components.push(line)
      continue
    }
    if (/^[A-Za-z]+:/.test(line)) inside = false
    if (inside) components.push(line)
  }
  return { components, body: m[2] }
}

/** The whole file: generated token groups, the kept `components:` block, the kept body. */
export function renderDesignMd(model, existing, { title = 'Design system' } = {}) {
  const { components, body } = handWritten(existing ?? '')
  const front = ['---', `name: ${nameOf(existing) ?? title}`, ...tokenFrontmatter(model), ...components, '---']
  const text = body.trim() ? body.replace(/^\n+/, '') : skeleton(title)
  return `${front.join('\n')}\n\n${text.replace(/\n*$/, '\n')}`
}

function nameOf(existing) {
  return existing?.match(/^---\n(?:[\s\S]*?\n)?name:\s*(.+?)\s*\n[\s\S]*?\n---/)?.[1] ?? null
}

function skeleton(title) {
  return [`# ${title}`, '', ...SECTIONS.flatMap((s) => [`## ${s}`, '', `_To be written._`, ''])].join('\n')
}

/** Generate for a repository: { text, current, file, problems }. `current` is whether the
 * file on disk already holds this text. */
export async function generateDesignMd(repo) {
  const { problems, ctx } = await contextFor(repo)
  if (problems.length) return { problems, text: null, current: false, file: path.join(repo, 'design.md') }
  const model = buildModel(ctx)
  if (model.problems.length) return { problems: model.problems, text: null, current: false, file: path.join(repo, 'design.md') }
  const file = path.join(repo, 'design.md')
  const existing = fs.existsSync(file) ? fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n') : null
  const text = renderDesignMd(model, existing, { title: ctx.CONFIG.title || 'Design system' })
  return { problems: [], text, current: existing === text, file }
}

/** Write it; returns true when the file changed. */
export async function writeDesignMd(repo) {
  const r = await generateDesignMd(repo)
  if (r.problems.length) throw new Error(r.problems.join('\n'))
  if (!r.current) fs.writeFileSync(r.file, r.text)
  return !r.current
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  const at = argv.indexOf('--repo')
  const repo = at >= 0 ? path.resolve(argv[at + 1]) : execSync('git rev-parse --show-toplevel', { encoding: 'utf8' }).trim()
  const r = await generateDesignMd(repo)
  if (r.problems.length) {
    console.error(`design-md: ${r.problems.length} problem(s)\n`)
    for (const p of r.problems) console.error(`  ✗ ${p}`)
    process.exit(2)
  }
  if (argv.includes('--check')) {
    if (r.current) console.log('design-md: design.md token section is current')
    else {
      console.error("design-md: design.md's token section differs from the stylesheet — run npm run build:design-system (or design-md.mjs) and commit it")
      process.exit(1)
    }
  } else {
    const changed = await writeDesignMd(repo)
    console.log(`design-md: design.md ${changed ? 'rewritten' : 'already current'}`)
  }
}
