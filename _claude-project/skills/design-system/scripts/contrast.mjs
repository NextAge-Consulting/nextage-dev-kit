/**
 * WCAG contrast of the design system's text pairs, per theme — the check-design-tokens
 * section that keeps every text colour readable on the background it is used on.
 *
 * Pairs come from design.md's frontmatter components (`textColor` on `backgroundColor`,
 * each `{colors.<key>}` naming the token `--<key>`) and from the naming convention
 * `--<x>-foreground` on `--<x>` (`--foreground` on `--background`). Values come from the
 * token stylesheets, resolved per theme by the claude-design engine and measured with the
 * vendored Color.js (WCAG 2.1): 4.5:1, every pair being text.
 *
 * A translucent colour is laid over what is under it: text over its background, a
 * translucent background over `--background`. A pair that cannot be resolved or laid
 * over an opaque colour is skipped and listed, never passed.
 *
 * A pair with a `disabled` token is exempt: WCAG 1.4.3 sets no contrast requirement for
 * an inactive control's text. It is counted and listed, never measured.
 *
 * An accepted failure says so on the text token's declaration:
 *   --muted-foreground: oklch(…); /* contrast-accepted: 3.8 — placeholder text only *\/
 * A pair measuring below its accepted ratio fails: the colour got worse.
 */

import { createRequire } from 'node:module'
import { isColorToken, parseTokenBlocks, resolveColor } from '../../claude-design/scripts/resolve.mjs'

const Color = createRequire(import.meta.url)('../../claude-design/vendor/color.cjs').default

const MINIMUM = 4.5
const ACCEPTED = /\/\*\s*contrast-accepted:\s*([\d.]+)\s*[—-]\s*(.+?)\s*\*\//

/** Every text pair the project declares: `{ text, background, from }`, de-duplicated. */
export function contrastPairs(lightEnv, design) {
  const pairs = new Map()
  const unknown = []
  // `{colors.primary}` is `--primary`, or `--color-primary` in a Tailwind v4 theme.
  const tokenOf = (key) => (lightEnv.has(key) ? key : lightEnv.has(`color-${key}`) ? `color-${key}` : null)
  const add = (text, background, from) => {
    const key = `${text}|${background}`
    if (!pairs.has(key)) pairs.set(key, { text, background, from })
  }
  // design.md frontmatter: components.<name>.{textColor,backgroundColor} = "{colors.<key>}".
  if (design) {
    const front = design.split(/^---$/m)[1] ?? ''
    let group = null
    let component = null
    const props = new Map()
    const flush = () => {
      if (!component) return
      const t = props.get('textColor')
      const b = props.get('backgroundColor')
      if (t && b) {
        for (const [prop, key] of [['textColor', t], ['backgroundColor', b]])
          if (!tokenOf(key)) unknown.push(`design.md  components.${component}.${prop}  — {colors.${key}} names no token in the token stylesheets, so its contrast cannot be measured`)
        if (tokenOf(t) && tokenOf(b)) add(tokenOf(t), tokenOf(b), `components.${component}`)
      }
      props.clear()
    }
    for (const line of front.split('\n')) {
      const g = /^([A-Za-z]+):\s*$/.exec(line)
      if (g) {
        flush()
        component = null
        group = g[1]
        continue
      }
      if (group !== 'components') continue
      const c = /^ {2}([A-Za-z0-9-]+):\s*$/.exec(line)
      if (c) {
        flush()
        component = c[1]
        continue
      }
      const p = /^ {4}(textColor|backgroundColor):\s*["']?\{colors\.([A-Za-z0-9-]+)\}["']?\s*$/.exec(line)
      if (p && component) props.set(p[1], p[2])
    }
    flush()
  }
  // The naming convention: --<x>-foreground on --<x>, and --foreground on --background
  // (each also with the `color-` prefix).
  for (const name of lightEnv.keys()) {
    for (const p of ['', 'color-']) if (name === `${p}foreground` && lightEnv.has(`${p}background`)) add(name, `${p}background`, 'naming')
    const m = /^(.+)-foreground$/.exec(name)
    if (m && lightEnv.has(m[1])) add(name, m[1], 'naming')
  }
  return { pairs: [...pairs.values()], unknown }
}

/** A colour laid over an opaque one, in sRGB. */
function over(top, under) {
  if (top.alpha >= 1) return top
  const a = top.alpha
  const t = top.to('srgb').coords
  const u = under.to('srgb').coords
  return new Color('srgb', t.map((c, i) => a * (c ?? 0) + (1 - a) * (u[i] ?? 0)), 1)
}

/**
 * The contrast problems of the token stylesheets ([[file, css], …]) given design.md.
 * Returns { problems, skipped, pairs, themes, colourTokens }.
 */
export function contrastProblems(tokenCss, design) {
  const blocks = []
  for (const [file, css] of tokenCss) {
    try {
      for (const b of parseTokenBlocks(css)) blocks.push({ ...b, file })
    } catch {
      // A token file that does not parse is already a problem the parity check reports.
    }
  }
  const lightEnv = new Map(blocks.filter((b) => b.theme === 'light').flatMap((b) => b.decls).map((d) => [d.name, d.value]))
  const darkDecls = blocks.filter((b) => b.theme === 'dark').flatMap((b) => b.decls)
  const themes = [['light', lightEnv]]
  if (darkDecls.length) themes.push(['dark', new Map([...lightEnv, ...darkDecls.map((d) => [d.name, d.value])])])
  const colourTokens = [...lightEnv.keys()].filter((n) => isColorToken(lightEnv.get(n), lightEnv, Color)).length

  // Where each light declaration sits, and what its line accepts.
  const lineOf = new Map()
  for (const [file, css] of tokenCss)
    css.split('\n').forEach((line, i) => {
      const d = /^\s*--([\w-]+)\s*:/.exec(line)
      if (d && !lineOf.has(d[1])) lineOf.set(d[1], { at: `${file}:${i + 1}`, accepted: ACCEPTED.exec(line) })
    })

  const { pairs, unknown } = contrastPairs(lightEnv, design)
  const problems = [...unknown]
  const skipped = []
  const exempt = []
  let measured = 0
  for (const { text, background } of pairs) {
    if ([text, background].some((n) => n.split('-').includes('disabled'))) {
      exempt.push(`--${text} on --${background}`)
      continue
    }
    for (const [theme, env] of themes) {
      const label = `--${text} on --${background} (${theme})`
      let fg
      let bg
      try {
        fg = new Color(resolveColor(env.get(text), env, new Set(), Color))
        bg = new Color(resolveColor(env.get(background), env, new Set(), Color))
        if (bg.alpha < 1) {
          if (!env.has('background') || background === 'background') throw new Error('a translucent background with no opaque --background under it')
          const page = new Color(resolveColor(env.get('background'), env, new Set(), Color))
          if (page.alpha < 1) throw new Error('--background is translucent')
          bg = over(bg, page)
        }
        fg = over(fg, bg)
      } catch (e) {
        skipped.push(`${label}: ${e.message}`)
        continue
      }
      measured++
      const ratio = fg.contrast(bg, 'WCAG21')
      if (ratio >= MINIMUM) continue
      const at = lineOf.get(text)?.at ?? `--${text}`
      const accepted = lineOf.get(text)?.accepted
      const shown = ratio.toFixed(2)
      if (accepted && ratio + 0.005 >= Number(accepted[1])) continue
      problems.push(
        accepted
          ? `${at}  ${label}  — contrast ${shown}:1, below its accepted ${Number(accepted[1]).toFixed(2)}:1 — the colour got worse`
          : `${at}  ${label}  — contrast ${shown}:1, below ${MINIMUM}:1 for text; change a colour, or mark the text token /* contrast-accepted: ${shown} — <reason> */`,
      )
    }
  }
  if (colourTokens && !pairs.length && !unknown.length)
    problems.push('contrast: no text pairs to measure — name them in design.md components (textColor on backgroundColor), or as --<x>-foreground on --<x>')
  return { problems, skipped, exempt, pairs: pairs.length, measured, themes: themes.length, colourTokens }
}
