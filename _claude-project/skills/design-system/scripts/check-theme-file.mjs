#!/usr/bin/env node
/**
 * Checks a theme file: the stylesheet of user settings (accent colour, colour-blind
 * mode, text size, spacing) that overrides the design system's tokens. Run by hand;
 * never a gate.
 *
 *   node .claude/skills/design-system/scripts/check-theme-file.mjs <theme file>
 *
 * The token stylesheets are DESIGN_TOKEN_FILES under DESIGN_UI_PACKAGE, read from
 * .claude/sync-substitutions.json at the repository root. Two checks, each naming the
 * selector and the variable:
 *   exists     every variable the theme file sets is a token the token stylesheets declare;
 *   dark       every colour a setting overrides is overridden again under the dark theme
 *              for that same setting, even when the value is the same.
 * A setting's dark block is its selector with a dark-theme selector added
 * (`html[data-theme="dark"][data-accent="green"]` for `html[data-accent="green"]`).
 *
 * Prints what it inspected, and fails when the theme file sets nothing.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const DARK = /\[data-theme=["']?dark["']?\]|\.dark\b/g
const COLOUR = /^(#[0-9a-f]{3,8}|(?:rgba?|hsla?|oklch|oklab|lab|lch|color|color-mix)\(|transparent$)/i

/** Every top-level `selector { body }` of a stylesheet, comments removed. */
export function blocksOf(css) {
  const src = css.replace(/\/\*[\s\S]*?\*\//g, '')
  const out = []
  let depth = 0
  let start = 0
  let open = -1
  for (let i = 0; i < src.length; i++) {
    if (src[i] === '{') {
      if (depth === 0) open = i
      depth++
    } else if (src[i] === '}') {
      depth--
      if (depth === 0) {
        out.push({ selector: src.slice(start, open).trim(), body: src.slice(open + 1, i) })
        start = i + 1
      }
    }
  }
  return out
}

/** The custom properties a block body declares, in order. */
export function declsOf(body) {
  return [...body.matchAll(/(--[\w-]+)\s*:\s*([^;]+);?/g)].map((m) => ({ name: m[1], value: m[2].trim() }))
}

/** A selector with its dark-theme part and its root element removed: the setting it switches on. */
const settingOf = (selector) =>
  selector
    .replace(DARK, '')
    .replace(/^\s*(html|:root)(?=[\s[.:]|$)/, '')
    .replace(/\s+/g, '')
    .replace(/["']/g, '')

/** The problems with a theme file, given the tokens the token stylesheets declare. */
export function checkThemeFile(themeCss, tokens) {
  const problems = []
  const blocks = blocksOf(themeCss).flatMap((b) => b.selector.split(',').map((s) => ({ selector: s.trim(), decls: declsOf(b.body) })))
  const isColour = (name, depth = 0) => {
    const v = tokens.get(name)
    if (v === undefined || depth > 16) return false
    const ref = /^var\((--[\w-]+)\)$/.exec(v)
    return ref ? isColour(ref[1], depth + 1) : COLOUR.test(v)
  }
  const darkSets = new Map()
  for (const b of blocks)
    if (b.selector.match(DARK)) {
      const key = settingOf(b.selector)
      darkSets.set(key, new Set([...(darkSets.get(key) ?? []), ...b.decls.map((d) => d.name)]))
    }
  let variables = 0
  for (const b of blocks) {
    for (const d of b.decls) {
      variables++
      if (!tokens.has(d.name)) problems.push(`${b.selector}  ${d.name}  — not a token the token stylesheets declare; a setting overrides an existing token`)
    }
    if (b.selector.match(DARK)) continue
    const dark = darkSets.get(settingOf(b.selector))
    for (const d of b.decls)
      if (isColour(d.name) && !dark?.has(d.name))
        problems.push(`${b.selector}  ${d.name}  — a colour with no dark value for this setting; override it again under the dark theme, even with the same value`)
  }
  return { problems, blocks: blocks.length, variables }
}

/** Every token the token stylesheets declare, with its light value. */
export function readTokens(repo) {
  const subs = JSON.parse(readFileSync(path.join(repo, '.claude/sync-substitutions.json'), 'utf8'))
  const pkg = String(subs.DESIGN_UI_PACKAGE ?? '').trim()
  const files = String(subs.DESIGN_TOKEN_FILES ?? '').split(/\s+/).filter(Boolean)
  if (!files.length) throw new Error('DESIGN_TOKEN_FILES is empty in .claude/sync-substitutions.json — there are no tokens to override')
  const tokens = new Map()
  for (const rel of files) {
    const file = path.join(repo, pkg, rel)
    if (!existsSync(file)) throw new Error(`${path.join(pkg, rel)}: a token stylesheet DESIGN_TOKEN_FILES names, not found`)
    for (const b of blocksOf(readFileSync(file, 'utf8')))
      for (const d of declsOf(b.body)) if (!b.selector.match(DARK) && !tokens.has(d.name)) tokens.set(d.name, d.value)
  }
  return tokens
}

function main() {
  const given = process.argv[2]
  if (!given) {
    console.error('usage: check-theme-file.mjs <theme file>')
    process.exit(2)
  }
  const repo = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
  let tokens
  try {
    tokens = readTokens(repo)
  } catch (e) {
    console.error(`check-theme-file: ${e.message}`)
    process.exit(2)
  }
  const { problems, blocks, variables } = checkThemeFile(readFileSync(path.resolve(given), 'utf8'), tokens)
  if (!variables) {
    console.error(`check-theme-file: ${given} sets no variables — nothing to check`)
    process.exit(1)
  }
  for (const p of problems) console.log(`  ✗ ${p}`)
  console.log(`check-theme-file: ${blocks} selector(s), ${variables} variable(s) against ${tokens.size} token(s) — ${problems.length ? `${problems.length} problem(s)` : 'clean'}`)
  process.exit(problems.length ? 1 : 0)
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) main()
