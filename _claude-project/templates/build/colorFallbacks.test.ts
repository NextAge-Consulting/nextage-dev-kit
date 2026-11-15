import postcss from 'postcss'
import { describe, expect, it } from 'vitest'
import { colorFallbacks, plainValue } from './colorFallbacks'

const FALLBACK = '@supports not ((color: oklch(0 0 0)) and (color: color-mix(in oklab, red, red)))'

async function run(css: string) {
  const result = await postcss([colorFallbacks()]).process(css, { from: 'tokens.css' })
  // Whitespace collapsed: the assertions are about what is added, not how it is laid out.
  return { css: result.css.replace(/\s+/g, ' '), warnings: result.warnings().map((w) => w.text) }
}

describe('colour fallbacks', () => {
  it('adds each oklch token in hex, behind a block only older browsers apply', async () => {
    const { css } = await run(':root { --hue: 252.8; --popover: oklch(1 0 var(--hue)); --ink: oklch(0 0 0); --size: 4px }')
    expect(css).toContain(`${FALLBACK} { :root { --popover: #ffffff; --ink: #000000}}`)
  })

  it("resolves a dark theme's color-mix through its own tokens before the root's", async () => {
    const { css } = await run(
      ':root { --input: oklch(1 0 0) } :root:where(.dark, .dark *) { --input: oklch(0 0 0); --field: color-mix(in oklab, var(--input) 50%, transparent) }',
    )
    expect(css).toContain(`${FALLBACK} { :root:where(.dark, .dark *) { --input: #000000; --field: #00000080 }}`)
  })

  it('gives a token the minifier moved into a colour-support block its fallback after that block, through its theme', async () => {
    // Tailwind's build leaves a cruder value outside and the real one inside a block testing for color-mix().
    const { css, warnings } = await run(
      ':root { --input: oklch(1 0 0) } :root:where(.dark, .dark *) { --input: oklch(0 0 0); --field: var(--input) } @supports (color: color-mix(in lab, red, red)) { :root:where(.dark, .dark *) { --field: color-mix(in oklab, var(--input) 30%, transparent) } }',
    )
    expect(warnings).toEqual([])
    const enhancement = css.indexOf('@supports (color: color-mix(in lab, red, red))')
    const fallback = css.indexOf(`${FALLBACK} { :root:where(.dark, .dark *) { --field: #0000004d }}`)
    expect(enhancement).toBeGreaterThan(-1)
    expect(fallback).toBeGreaterThan(enhancement)
  })

  it('leaves utilities, a support test of anything but colour, and its own blocks alone', async () => {
    const { css } = await run(
      '@supports (color: color-mix(in lab, red, red)) { .bg-x { background: color-mix(in oklab, red 50%, transparent) } } @supports (not (-webkit-appearance: -apple-pay-button)) { :root { --x: oklch(1 0 0) } }',
    )
    expect(css).not.toContain('@supports not')
    const own = await run(`${FALLBACK} { :root { --x: oklch(1 0 0) } }`)
    expect(own.css.split('@supports not').length).toBe(2)
  })

  it('reports a token it cannot resolve, and adds nothing for it', async () => {
    const { css, warnings } = await run(':root { --x: oklch(0.5 0.1 var(--missing)) }')
    expect(css).not.toContain('@supports not')
    expect(warnings).toEqual(['no plain-colour fallback for --x: oklch(0.5 0.1 var(--missing))'])
  })

  it('converts colours inside a longer value, such as a shadow', () => {
    expect(plainValue('0 4px 8px oklch(0 0 0 / 50%)', new Map())).toBe('0 4px 8px #00000080')
  })

  it("resolves a var() from its token, never reaching a fallback that names an unset one", () => {
    expect(plainValue('oklch(1 0 var(--hue, var(--unset)))', new Map([['--hue', '0']]))).toBe('#ffffff')
  })

  it('reads the alpha of a comma-separated rgb() as it does for rgba()', () => {
    expect(plainValue('color-mix(in oklab, rgb(0, 0, 0, 0.5) 100%, transparent)', new Map())).toBe('#00000080')
  })

  it('matches the browser on a saturated colour', () => {
    // Chrome draws oklch(0.6279 0.2577 29.23) as rgb(255, 0, 0).
    expect(plainValue('oklch(0.6279 0.2577 29.23)', new Map())).toBe('#ff0000')
  })
})
