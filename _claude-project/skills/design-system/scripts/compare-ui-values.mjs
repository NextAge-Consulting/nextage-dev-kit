#!/usr/bin/env node
/**
 * Proves a UI change leaves what the user sees unchanged — or lists exactly what moved.
 *
 *   node .claude/skills/design-system/scripts/compare-ui-values.mjs [--base <git-ref>]
 *
 * Compares the working tree against <git-ref> (default HEAD). Tailwind itself compiles
 * both sides with each side's own stylesheets, so every class resolves to the values
 * the browser gets. For every changed line of .ts/.tsx, the classes removed and the
 * classes added are resolved to final values — lengths in px, colours as literals —
 * and compared. Every theme variable both sides define is compared too.
 *
 * Prints:
 *   changed      each difference, grouped (`font-size: 13px → 12px`), with file:line;
 *   uncompared   a changed line it could not pair or resolve, so nothing passes unseen.
 * Exits 0 when nothing a user sees changed and everything was compared; 1 otherwise.
 * Prints what it inspected, and fails when that is nothing.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, readlinkSync, rmSync, symlinkSync } from 'node:fs'
import { createRequire } from 'node:module'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const ENTRY = /^\s*@import\s+["']tailwindcss["']/m
const ROOT_PX = 16

const git = (repo, args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 })

/** Every string literal's words on a line: the candidate classes. Tailwind ignores the rest. */
export function candidates(line) {
  const out = []
  for (const m of line.matchAll(/(["'`])((?:\\.|(?!\1).)*)\1/g)) for (const w of m[2].split(/\s+/)) if (w && !w.includes('${')) out.push(w)
  return out
}

/** + - * / and parentheses over plain numbers; null for anything else. */
export function arithmetic(src) {
  const tokens = src.match(/\d*\.?\d+|[-+*/()]/g)
  if (!tokens || tokens.join('') !== src.replace(/\s+/g, '')) return null
  let i = 0
  const factor = () => {
    const t = tokens[i++]
    if (t === '(') {
      const v = sum()
      return tokens[i++] === ')' ? v : Number.NaN
    }
    if (t === '-') return -factor()
    return Number(t)
  }
  const product = () => {
    let v = factor()
    while (tokens[i] === '*' || tokens[i] === '/') v = tokens[i++] === '*' ? v * factor() : v / factor()
    return v
  }
  const sum = () => {
    let v = product()
    while (tokens[i] === '+' || tokens[i] === '-') v = tokens[i++] === '+' ? v + product() : v - product()
    return v
  }
  const v = sum()
  return i === tokens.length && Number.isFinite(v) ? v : null
}

/** A plain length or number in px where it can be; anything else unchanged. */
export function toPx(value) {
  const v = value.trim()
  let m = v.match(/^(-?[\d.]+)(px|rem)$/)
  if (m) return `${+(Number(m[1]) * (m[2] === 'rem' ? ROOT_PX : 1)).toFixed(3)}px`
  m = v.match(/^calc\((.+)\)$/)
  if (m) {
    const expr = m[1].replace(/(-?[\d.]+)(px|rem)/g, (_, n, u) => `(${Number(n) * (u === 'rem' ? ROOT_PX : 1)}px)`)
    const unit = /px/.test(expr) ? 'px' : ''
    const arith = expr.replace(/px/g, '')
    const n = arithmetic(arith)
    // A length rounds to a thousandth of a px; a bare number keeps its precision for the line-height step.
    if (n !== null) return unit ? `${+n.toFixed(3)}px` : `${n}`
  }
  return v
}

/** Replace every var() with its value from `vars`, or its fallback; repeat until none is left. */
export function resolveVars(value, vars) {
  let v = value
  for (let i = 0; i < 20 && v.includes('var('); i++) {
    v = v.replace(/var\((--[\w-]+)(?:\s*,\s*((?:[^()]|\([^()]*\))*))?\)/g, (_, name, fallback) => vars.get(name) ?? fallback ?? `<undefined ${name}>`)
  }
  return v
}

/** Theme variables: every custom property on :root / :host / html outside a dark block. */
export function themeVars(css) {
  const vars = new Map()
  const stack = []
  let buf = ''
  for (const ch of css) {
    if (ch === '{') {
      stack.push(buf.trim())
      buf = ''
    } else if (ch === '}') {
      stack.pop()
      buf = ''
    } else if (ch === ';') {
      const sel = stack.at(-1) ?? ''
      const m = buf.trim().match(/^(--[\w-]+)\s*:\s*([\s\S]+)$/)
      if (m && /(^|,|\s)(:root|:host|html)\b|^\*/.test(sel) && !stack.some((s) => /\.dark|prefers-color-scheme:\s*dark/.test(s)) && !vars.has(m[1])) vars.set(m[1], m[2].trim())
      const init = buf.trim().match(/^initial-value\s*:\s*([\s\S]+)$/)
      const prop = sel.match(/^@property\s+(--[\w-]+)/)
      if (init && prop && !vars.has(prop[1])) vars.set(prop[1], init[1].trim())
      buf = ''
    } else buf += ch
  }
  return vars
}

/** Where a class's selector appears in a rule's selector — not as the prefix of a longer class. */
export function ownSelector(selector) {
  const at = (sel) => {
    const hits = []
    for (let i = sel.indexOf(selector); i !== -1; i = sel.indexOf(selector, i + 1)) {
      // A word character, a hyphen or an escape (`py-2\.5`) after the match means a longer class.
      if (!/[\w\\-]/.test(sel[i + selector.length] ?? '')) hits.push(i)
    }
    return hits
  }
  return {
    within: (sel) => at(sel).length > 0,
    replaced: (sel) => {
      let out = sel
      for (const i of at(sel).reverse()) out = `${out.slice(0, i)}&${out.slice(i + selector.length)}`
      return out
    },
  }
}

/** The declarations one utility produces, as `context|property` → raw value, custom properties included. */
export function declarations(css, cls) {
  const out = new Map()
  const stack = []
  let buf = ''
  let inside = 0
  // The class as CSS writes it in a selector (`hover\:bg-x`), matched as plain text.
  const selector = `.${cls.replace(/[^\w-]/g, (c) => `\\${c}`)}`
  const own = ownSelector(selector)
  for (const ch of css) {
    if (ch === '{') {
      const sel = buf.trim()
      stack.push(sel)
      if (own.within(sel) || (inside && stack.length > inside)) inside ||= stack.length
      buf = ''
    } else if (ch === '}') {
      if (stack.length === inside) inside = 0
      stack.pop()
      buf = ''
    } else if (ch === ';') {
      if (inside) {
        const m = buf.trim().match(/^([\w-]+)\s*:\s*([\s\S]+)$/)
        if (m) {
          const context = stack.slice(inside).map((s) => own.replaced(s)).concat(stack.slice(0, inside).filter((s) => /^@media|^@supports|^@container/.test(s)))
          out.set(`${context.join(' ')}|${m[1]}`, m[2].trim())
        }
      }
      buf = ''
    } else buf += ch
  }
  return out
}

/** A compiler for one tree: classes → resolved declarations, cached. */
export async function compilerFor(root, entry) {
  const req = createRequire(path.join(root, 'package.json'))
  const tw = await import(pathToFileURL(req.resolve('@tailwindcss/node')).href)
  const full = path.join(root, entry)
  const compiled = await tw.compile(readFileSync(full, 'utf8'), { base: path.dirname(full), onDependency() {} })
  // build() is cumulative and writes only the theme variables its classes use, so the
  // variables are re-read from the latest output whenever a new class was built.
  let vars = themeVars(compiled.build([]))
  const cache = new Map()
  return {
    get vars() {
      return vars
    },
    resolve(classes) {
      let built = false
      const raw = new Map()
      for (const c of classes) {
        if (!cache.has(c)) {
          cache.set(c, declarations(compiled.build([c]), c))
          built = true
        }
        for (const [k, v] of cache.get(c)) raw.set(k, v)
      }
      if (built) vars = themeVars(compiled.build([]))
      // Custom properties the element's own classes set (`--tw-shadow`) resolve first, over the theme.
      const local = new Map(vars)
      for (const [k, v] of raw) if (k.split('|')[1].startsWith('--')) local.set(k.split('|')[1], v)
      const merged = new Map()
      for (const [k, v] of raw) if (!k.split('|')[1].startsWith('--')) merged.set(k, toPx(resolveVars(v, local)))
      // A unitless line height is relative to the font size beside it.
      for (const [k, v] of merged) {
        const [ctx, prop] = k.split('|')
        const size = merged.get(`${ctx}|font-size`)
        if (prop === 'line-height' && /^[\d.]+$/.test(v) && size?.endsWith('px')) merged.set(k, `${+(Number(v) * Number.parseFloat(size)).toFixed(3)}px`)
      }
      return merged
    },
  }
}

/** The base tree, extracted read-only, with node_modules mirrored so its own workspaces resolve. */
function extractBase(repo, ref) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'ui-values-'))
  execFileSync('bash', ['-c', `git -C "$1" archive "$2" | tar -x -C "$3"`, '_', repo, ref, dir])
  const mirror = (from, to) => {
    if (!existsSync(from)) return
    mkdirSync(to, { recursive: true })
    for (const name of readdirSync(from)) {
      const src = path.join(from, name)
      const dst = path.join(to, name)
      if (name.startsWith('@') && lstatSync(src).isDirectory()) {
        mirror(src, dst)
        continue
      }
      let target = src
      if (lstatSync(src).isSymbolicLink()) {
        const real = path.resolve(path.dirname(src), readlinkSync(src))
        if (real.startsWith(`${repo}${path.sep}`)) target = path.join(dir, path.relative(repo, real))
      }
      if (!existsSync(dst)) symlinkSync(target, dst)
    }
  }
  mirror(path.join(repo, 'node_modules'), path.join(dir, 'node_modules'))
  return dir
}

/** A line with the text inside its string literals blanked: what it is, apart from its classes. */
const shape = (line) => line.replace(/(["'`])(?:\\.|(?!\1).)*\1/g, '$1$1').trim()

/**
 * Pairs a hunk's removed and added lines: lines of the same shape match in order, and the
 * lines between two matches pair one to one when both sides hold the same number. Every
 * other line is left over — never merged with another.
 */
export function pairLines(removed, added) {
  const a = removed.map(shape)
  const b = added.map(shape)
  const lcs = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0))
  for (let i = a.length - 1; i >= 0; i--) for (let j = b.length - 1; j >= 0; j--) lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1])
  const anchors = []
  for (let i = 0, j = 0; i < a.length && j < b.length; ) {
    if (a[i] === b[j]) anchors.push([i++, j++])
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) i++
    else j++
  }
  const pairs = []
  const leftover = []
  let pi = 0
  let pj = 0
  for (const [ai, bj] of [...anchors, [a.length, b.length]]) {
    if (ai - pi === bj - pj) for (let k = 0; k < ai - pi; k++) pairs.push([pi + k, pj + k])
    else {
      for (let k = pi; k < ai; k++) leftover.push({ side: 'removed', index: k })
      for (let k = pj; k < bj; k++) leftover.push({ side: 'added', index: k })
    }
    if (ai < a.length) pairs.push([ai, bj])
    pi = ai + 1
    pj = bj + 1
  }
  return { pairs, leftover }
}

/** Changed lines per file: hunks of removed and added lines, with the new-side line number. */
export function hunks(diff) {
  const out = []
  let file = null
  let cur = null
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ ')) file = line.slice(4).replace(/^b\//, '')
    else if (line.startsWith('@@')) {
      const m = line.match(/\+(\d+)/)
      cur = { file, line: Number(m[1]), removed: [], added: [] }
      out.push(cur)
    } else if (cur && line.startsWith('-') && !line.startsWith('---')) cur.removed.push(line.slice(1))
    else if (cur && line.startsWith('+') && !line.startsWith('+++')) cur.added.push(line.slice(1))
  }
  return out.filter((h) => h.file && h.file !== '/dev/null')
}

function entryFor(entries, file) {
  const scored = entries.map((e) => [e, path.dirname(e).split('/').filter((p, i) => file.split('/')[i] === p).length])
  scored.sort((a, b) => b[1] - a[1] || (a[0].startsWith('apps/') ? -1 : 1))
  return scored[0]?.[0]
}

export async function compareUiValues(repo, { base = 'HEAD' } = {}) {
  const diff = git(repo, ['diff', '-U0', base, '--', '*.ts', '*.tsx'])
  const changes = hunks(diff)
  const tracked = git(repo, ['ls-files', '--cached', '--others', '--exclude-standard', '--', '*.css']).split('\n').filter(Boolean)
  const entries = tracked.filter((f) => !f.includes('node_modules') && ENTRY.test(readFileSync(path.join(repo, f), 'utf8')))
  if (!entries.length) return { problems: ['no stylesheet imports tailwindcss — nothing to compile the classes with'], changed: [], uncompared: [], counts: null }

  const baseDir = extractBase(repo, base)
  try {
    const compilers = new Map()
    const get = async (side, entry) => {
      const k = `${side}:${entry}`
      if (!compilers.has(k)) compilers.set(k, existsSync(path.join(side === 'new' ? repo : baseDir, entry)) ? await compilerFor(side === 'new' ? repo : baseDir, entry) : null)
      return compilers.get(k)
    }

    const changed = new Map()
    const uncompared = []
    const note = (what, at) => {
      if (!changed.has(what)) changed.set(what, [])
      changed.get(what).push(at)
    }

    // Theme variables both sides define.
    let varsCompared = 0
    for (const entry of entries) {
      const before = await get('old', entry)
      const after = await get('new', entry)
      if (!before || !after) continue
      for (const [name, v] of before.vars) {
        if (!after.vars.has(name)) continue
        varsCompared++
        const a = toPx(resolveVars(v, before.vars))
        const b = toPx(resolveVars(after.vars.get(name), after.vars))
        if (a !== b) note(`${name}: ${a} → ${b} (everything using it)`, entry)
      }
    }

    let linesCompared = 0
    for (const h of changes) {
      const at = `${h.file}:${h.line}`
      const entry = entryFor(entries, h.file)
      const before = await get('old', entry)
      const after = await get('new', entry)
      if (!before || !after) {
        uncompared.push(`${at}  — no stylesheet on one side to compile with`)
        continue
      }
      const { pairs, leftover } = pairLines(h.removed, h.added)
      for (const l of leftover) {
        const text = l.side === 'removed' ? h.removed[l.index] : h.added[l.index]
        if (candidates(text).length) uncompared.push(`${h.file}:${h.line + (l.side === 'added' ? l.index : 0)}  — a line with classes was ${l.side}, not swapped in place; check it by hand`)
      }
      for (const [ri, ai] of pairs) {
        const i = ai
        const oldC = candidates(h.removed[ri])
        const newC = candidates(h.added[ai])
        if (oldC.join(' ') === newC.join(' ')) continue
        linesCompared++
        const x = before.resolve(oldC)
        const y = after.resolve(newC)
        const where = `${h.file}:${h.line + i}`
        for (const k of new Set([...x.keys(), ...y.keys()])) {
          const [ctx, prop] = k.split('|')
          const va = x.get(k) ?? '(unset)'
          const vb = y.get(k) ?? '(unset)'
          const undef = `${va} ${vb}`.match(/<undefined (--[\w-]+)>/)
          if (undef) uncompared.push(`${where}  — ${prop} uses ${undef[1]}, which nothing defines`)
          else if (va !== vb) note(`${ctx ? `${ctx} ` : ''}${prop}: ${va} → ${vb}`, where)
        }
      }
    }

    return {
      problems: [],
      changed: [...changed].map(([what, at]) => ({ what, at })),
      uncompared,
      counts: { hunks: changes.length, linesCompared, varsCompared, entries: entries.length },
    }
  } finally {
    rmSync(baseDir, { recursive: true, force: true })
  }
}

async function main() {
  const i = process.argv.indexOf('--base')
  const base = i > -1 ? process.argv[i + 1] : 'HEAD'
  const repo = git(process.cwd(), ['rev-parse', '--show-toplevel']).trim()
  const { problems, changed, uncompared, counts } = await compareUiValues(repo, { base })
  if (problems.length) {
    for (const p of problems) console.error(`✗ ${p}`)
    process.exit(1)
  }
  const scanned = `compared ${counts.linesCompared} changed class lines in ${counts.hunks} hunks and ${counts.varsCompared} theme variables against ${base}, through ${counts.entries} Tailwind entry stylesheet(s)`
  if (counts.linesCompared === 0 && counts.varsCompared === 0) {
    console.error(`✗ nothing compared: ${scanned}`)
    process.exit(1)
  }
  if (!changed.length && !uncompared.length) {
    console.log(`✓ nothing a user sees changed: ${scanned}`)
    return
  }
  if (changed.length) {
    console.error(`\n✗ what a user sees changed (${changed.length}):`)
    for (const c of changed) console.error(`  ${c.what}  — ${c.at.length} place(s): ${c.at.slice(0, 12).join(', ')}${c.at.length > 12 ? ', …' : ''}`)
  }
  if (uncompared.length) {
    console.error(`\n✗ could not compare (${uncompared.length}):`)
    for (const u of uncompared) console.error(`  ${u}`)
  }
  console.error(`\n  (${scanned})`)
  process.exit(1)
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) await main()

