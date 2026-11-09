#!/usr/bin/env node
/**
 * The judge: one question, one candidate, three answers, majority wins.
 *
 *   node judge.mjs --question <NAME> --candidate <file.json> [--runs 3] [--model sonnet]
 *       Asks the question of the candidate and prints the majority answer with its quotes.
 *   node judge.mjs --test [--question <NAME>] [--runs 3] [--model sonnet]
 *       Runs every case under judge-fixtures/<NAME>/ and reports, per question, how many
 *       cases gave the known answer in every run, in a majority of runs, and in none.
 *   node judge.mjs --candidates <file.jsonl> [--ledger <path>] [--repo <root>] [--runs 3] [--model sonnet]
 *       Asks every candidate the locator wrote (locate.mjs), one JSON object per line, and
 *       prints each yes. A `finding` line is code's own yes and is not asked. With --ledger,
 *       every yes is written to that file as a pending item for the human's walk-through
 *       (check-ui-status.mjs reads it), keyed by question and place, with the fingerprint of
 *       the line it names. An item leaves the ledger on the human's word alone — the line
 *       carries design-accepted or design-deferred — or when the line's code changes; a later
 *       no from the judge is a re-asked question, not an answer, and removes nothing. Exit 0
 *       whether or not there were yeses: the judge never stops a commit. Exit 2 when it
 *       cannot run.
 *   node judge.mjs --list
 *       Prints the questions the references file holds.
 *
 * The questions are references/judge-questions.md: each `## NAME — title` section with its
 * bold fields. The judge is given the question's text and the candidate's fields, nothing
 * else — no tools, no settings, no project files. An answer must quote text that appears in
 * the candidate, or it is discarded by code and counted as no answer.
 *
 * A candidate is a JSON object whose keys are the question's Given fields; a fixture adds
 * `answer` ("yes" or "no") and may add `why` for the reader. Nested fields (`a.name`) are
 * nested objects.
 *
 * JUDGE_CLAUDE names the CLI (default `claude`); the suite points it at a stub. The three
 * answers to a candidate, and the candidates themselves, are asked at once, up to
 * JUDGE_CONCURRENCY calls in flight (default 8).
 */

import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { fingerprint, lineCode } from '../../ui-patterns/scripts/check-ui-status.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
export const LEDGER = '.claude/ui-pending.json'
export const QUESTIONS = path.resolve(HERE, '../references/judge-questions.md')
export const FIXTURES = path.resolve(HERE, 'judge-fixtures')
const FIELDS = ['Asked about', 'Given', 'Quote', 'Yes when', 'No when', 'Example yes', 'Example no']

/** Every question in the references text: { name, title, fields: { 'Asked about': …, … } }. */
export function parseQuestions(text) {
  const out = []
  let q = null
  let field = null
  for (const line of text.split('\n')) {
    const head = line.match(/^## ([A-Z][A-Z-]*[A-Z]) — (.+)$/)
    if (head) {
      q = { name: head[1], title: head[2].trim(), fields: {} }
      out.push(q)
      field = null
      continue
    }
    if (/^## /.test(line) || /^---\s*$/.test(line)) {
      q = null
      field = null
      continue
    }
    if (!q) continue
    const f = line.match(/^\*\*([A-Za-z ]+):\*\*\s*(.*)$/)
    if (f && FIELDS.includes(f[1])) {
      field = f[1]
      q.fields[field] = f[2]
      continue
    }
    if (field && line.trim()) q.fields[field] += ` ${line.trim()}`
    else if (field && !line.trim()) field = null
  }
  for (const x of out) {
    const missing = FIELDS.filter((f) => !x.fields[f])
    if (missing.length) throw new Error(`${x.name}: missing ${missing.join(', ')}`)
    x.given = givenKeys(x.fields.Given)
    if (!x.given.length) throw new Error(`${x.name}: Given names no field`)
  }
  return out
}

/** The candidate keys a Given line names: one backticked key per comma-separated item,
 * the item's parenthetical description ignored (`screen` (the code, with `design-accepted`
 * comments) names `screen` alone). */
export function givenKeys(given) {
  const items = []
  let depth = 0
  let cur = ''
  for (const ch of given) {
    if (ch === '(') depth++
    else if (ch === ')') depth--
    if (ch === ',' && depth === 0) {
      items.push(cur)
      cur = ''
    } else cur += ch
  }
  items.push(cur)
  return items.map((it) => it.replace(/\([^)]*\)/g, '').match(/`([^`]+)`/)?.[1]).filter(Boolean)
}

export function readQuestions(file = QUESTIONS) {
  if (!existsSync(file)) throw new Error(`${file}: the judge questions are missing`)
  const qs = parseQuestions(readFileSync(file, 'utf8'))
  if (!qs.length) throw new Error(`${file}: no questions found`)
  return qs
}

/** A candidate's field by dotted key. */
const get = (obj, key) => key.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj)

/** The candidate's fields rendered for the judge, each under its own heading. */
export function renderCandidate(question, candidate) {
  const parts = []
  for (const key of question.given) {
    const v = get(candidate, key)
    if (v === undefined) throw new Error(`candidate has no field ${key}`)
    parts.push(`=== ${key} ===\n${typeof v === 'string' ? v : JSON.stringify(v, null, 2)}`)
  }
  return parts.join('\n\n')
}

/** Everything a quote may be drawn from: every string in the candidate's given fields. */
function candidateText(question, candidate) {
  const strings = []
  const walk = (v) => {
    if (typeof v === 'string') strings.push(v)
    else if (Array.isArray(v)) v.forEach(walk)
    else if (v && typeof v === 'object') Object.values(v).forEach(walk)
  }
  for (const key of question.given) walk(get(candidate, key))
  return strings.join('\n')
}

export function systemPrompt(question) {
  const f = question.fields
  return [
    `You answer one question about one candidate from a business application's design system, yes or no. You are given only the fields below and nothing else exists: do not assume a token, block, rule or screen that is not given. Answer "yes" only when the Yes case below is met on the evidence given; answer "no" otherwise, including when the evidence is not enough to say yes. Give the evidence as one or more quotes, each copied exactly from one field as it appears there, so each can be matched by text; never join two pieces of evidence into one quote. Do not explain, grade your confidence, or propose a change.`,
    '',
    `Question: ${question.name} — ${question.title}`,
    `Asked about: ${f['Asked about']}`,
    `Quote: ${f.Quote}`,
    `Yes when: ${f['Yes when']}`,
    `No when: ${f['No when']}`,
    `Example of yes: ${f['Example yes']}`,
    `Example of no: ${f['Example no']}`,
  ].join('\n')
}

const SCHEMA = JSON.stringify({
  type: 'object',
  properties: { answer: { type: 'string', enum: ['yes', 'no'] }, quotes: { type: 'array', items: { type: 'string' }, minItems: 1 } },
  required: ['answer', 'quotes'],
})

/** At most JUDGE_CONCURRENCY judge processes at once; the rest wait their turn. */
const MAX_IN_FLIGHT = Math.max(1, Number(process.env.JUDGE_CONCURRENCY) || 8)
let inFlight = 0
const waiting = []
async function withSlot(fn) {
  if (inFlight >= MAX_IN_FLIGHT) await new Promise((resolve) => waiting.push(resolve))
  inFlight++
  try {
    return await fn()
  } finally {
    inFlight--
    waiting.shift()?.()
  }
}

/** Run the CLI once with `input` on stdin: { status, stdout, stderr }. */
function run(bin, args, input) {
  return new Promise((resolve) => {
    const child = spawn(bin, args, { stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.setEncoding('utf8').on('data', (d) => (stdout += d))
    child.stderr.setEncoding('utf8').on('data', (d) => (stderr += d))
    child.on('error', (e) => resolve({ status: -1, stdout, stderr: `${stderr}${e.message}` }))
    child.on('close', (status) => resolve({ status, stdout, stderr }))
    child.stdin.on('error', () => {})
    child.stdin.end(input)
  })
}

/** One answer from a fresh judge: { answer, quote } or { error }. */
export async function askOnce(question, candidate, { model = 'sonnet', bin = process.env.JUDGE_CLAUDE ?? 'claude' } = {}) {
  const r = await withSlot(() =>
    run(
      bin,
      ['-p', '--model', model, '--tools', '', '--system-prompt', systemPrompt(question), '--json-schema', SCHEMA, '--output-format', 'json', '--no-session-persistence', '--disable-slash-commands', '--strict-mcp-config', '--setting-sources', ''],
      renderCandidate(question, candidate),
    ),
  )
  if (r.status !== 0) return { error: `claude exited ${r.status}: ${(r.stderr || '').trim().slice(0, 300)}` }
  let out
  try {
    out = JSON.parse(r.stdout)
  } catch {
    return { error: 'unparseable output' }
  }
  if (out.is_error) return { error: out.result ?? 'is_error' }
  const a = out.structured_output
  if (!a || !['yes', 'no'].includes(a.answer)) return { error: 'no answer' }
  const cost = typeof out.total_cost_usd === 'number' ? out.total_cost_usd : 0
  // Every quote must be text the candidate holds, each on its own; whitespace is folded on both sides.
  const fold = (s) => s.replace(/\s+/g, ' ').trim()
  const text = fold(candidateText(question, candidate))
  const quotes = Array.isArray(a.quotes) ? a.quotes.filter((q) => typeof q === 'string' && q.trim()) : []
  if (!quotes.length) return { error: 'no quote', cost }
  const missing = quotes.find((q) => !text.includes(fold(q)))
  if (missing !== undefined) return { error: `quote not in candidate: ${missing.slice(0, 80)}`, cost }
  return { answer: a.answer, quote: quotes.join(' | '), cost }
}

/** The majority of n answers, asked at once: { answer, votes: {yes, no, none}, quotes, cost }. */
export async function ask(question, candidate, { runs = 3, ...opts } = {}) {
  const votes = { yes: 0, no: 0, none: 0 }
  const quotes = []
  const errors = []
  let cost = 0
  const answers = await Promise.all(Array.from({ length: runs }, () => askOnce(question, candidate, opts)))
  for (const r of answers) {
    cost += r.cost ?? 0
    if (r.error) {
      votes.none++
      errors.push(r.error)
      continue
    }
    votes[r.answer]++
    quotes.push(r.quote)
  }
  const answer = votes.yes > votes.no ? 'yes' : votes.no > votes.yes ? 'no' : 'none'
  return { answer, votes, quotes: [...new Set(quotes)], errors, cost }
}

/** Every fixture under judge-fixtures/<NAME>/: { name, file, answer, candidate }. */
export function fixturesFor(name, dir = FIXTURES) {
  const folder = path.join(dir, name)
  if (!existsSync(folder)) return []
  return readdirSync(folder)
    .filter((f) => f.endsWith('.json'))
    .sort()
    .map((f) => {
      const { answer, why, ...candidate } = JSON.parse(readFileSync(path.join(folder, f), 'utf8'))
      if (!['yes', 'no'].includes(answer)) throw new Error(`${name}/${f}: answer must be yes or no`)
      return { name: f.replace(/\.json$/, ''), file: path.join(folder, f), answer, why, candidate }
    })
}

/** The code at a place (`file:line`), fingerprinted as a deferred line is; null when gone. */
export function placeFingerprint(repo, at) {
  const m = at.match(/^(.*):(\d+)$/)
  if (!m) return null
  const file = path.join(repo, m[1])
  if (!existsSync(file)) return null
  const line = readFileSync(file, 'utf8').split('\n')[Number(m[2]) - 1]
  if (line === undefined) return null
  return { fingerprint: fingerprint(lineCode(line)), excepted: /design-(?:accepted|deferred)\b/.test(line) }
}

/** Read a ledger; a missing or unreadable file is an empty one. */
export function readLedger(file) {
  if (!existsSync(file)) return []
  try {
    const items = JSON.parse(readFileSync(file, 'utf8'))
    return Array.isArray(items) ? items : []
  } catch {
    return []
  }
}

/**
 * The ledger after a run: existing items kept while their line is unchanged and not
 * excepted; each yes added or refreshed. A no removes nothing: only the human's word on
 * the line, or a change to its code, settles an item.
 */
export function mergeLedger(repo, items, { yes = [] }) {
  const keyOf = (i) => `${i.question}\u0000${i.at}`
  const out = new Map()
  for (const i of items) {
    const now = placeFingerprint(repo, i.at)
    if (!now || now.excepted || now.fingerprint !== i.fingerprint) continue
    out.set(keyOf(i), i)
  }
  for (const y of yes) {
    const now = placeFingerprint(repo, y.at)
    if (!now || now.excepted) continue
    out.set(keyOf(y), { question: y.question, at: y.at, quote: y.quote, fingerprint: now.fingerprint, since: y.since ?? new Date().toISOString().slice(0, 10) })
  }
  return [...out.values()].sort((a, b) => a.at.localeCompare(b.at) || a.question.localeCompare(b.question))
}

/** Ask every candidate in a JSON-lines file, all at once: { yes, no, errors, cost, asked }. */
export async function judgeCandidates(questions, text, opts = {}) {
  const yes = []
  const no = []
  const errors = []
  let cost = 0
  let asked = 0
  const pending = []
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    let c
    try {
      c = JSON.parse(line)
    } catch {
      errors.push(`not JSON: ${line.slice(0, 80)}`)
      continue
    }
    if (c.finding) {
      yes.push({ question: c.finding, at: c.at, quote: c.text })
      continue
    }
    const q = questions.find((x) => x.name === c.question)
    if (!q) {
      errors.push(`${c.at}: no question named ${c.question}`)
      continue
    }
    asked++
    pending.push(ask(q, c.candidate, opts).then((r) => ({ q, c, r })))
  }
  for (const { q, c, r } of await Promise.all(pending)) {
    cost += r.cost
    if (r.answer === 'yes') yes.push({ question: q.name, at: c.at, quote: r.quotes.join(' | ') })
    else if (r.answer === 'no') no.push({ question: q.name, at: c.at })
    else errors.push(`${c.at} ${q.name}: no majority (${r.errors[0] ?? 'split'})`)
  }
  return { yes, no, errors, cost, asked }
}

async function main() {
  const argv = process.argv.slice(2)
  const opt = (k) => {
    const i = argv.indexOf(k)
    return i >= 0 ? argv[i + 1] : undefined
  }
  const runs = Number(opt('--runs') ?? 3)
  const model = opt('--model') ?? 'sonnet'
  const questions = readQuestions()

  if (argv.includes('--list')) {
    for (const q of questions) console.log(`${q.name} — ${q.title}`)
    return
  }

  const candidatesFile = opt('--candidates')
  if (candidatesFile) {
    const repo = path.resolve(opt('--repo') ?? process.cwd())
    const text = readFileSync(path.resolve(candidatesFile), 'utf8')
    const { yes, no, errors, cost, asked } = await judgeCandidates(questions, text, { runs, model })
    for (const y of yes) console.log(`  ✗ ${y.at}  ${y.question}\n      ${y.quote}`)
    for (const e of errors) console.log(`  ! ${e}`)
    const ledger = opt('--ledger')
    if (ledger) {
      const file = path.resolve(repo, ledger)
      const next = mergeLedger(repo, readLedger(file), { yes })
      mkdirSync(path.dirname(file), { recursive: true })
      writeFileSync(file, `${JSON.stringify(next, null, 2)}\n`)
      console.log(`judge: ${yes.length} yes, ${no.length} no from ${asked} question(s) asked; ${next.length} pending item(s) in ${path.relative(repo, file)}; $${cost.toFixed(2)}`)
    } else console.log(`judge: ${yes.length} yes, ${no.length} no from ${asked} question(s) asked; $${cost.toFixed(2)}`)
    // Nothing decided at all is a judge that could not run; a mix of answers and errors ran.
    process.exit(errors.length && !yes.length && !no.length ? 2 : 0)
  }

  if (argv.includes('--test')) {
    const only = opt('--question')
    const chosen = only ? questions.filter((q) => q.name === only) : questions
    if (only && !chosen.length) throw new Error(`no question named ${only}`)
    let total = 0
    let agreed = 0
    let cost = 0
    const summary = []
    for (const q of chosen) {
      const cases = fixturesFor(q.name)
      if (!cases.length) {
        summary.push(`${q.name}: NO CASES — a question with no cases is not trusted`)
        continue
      }
      let unanimous = 0
      let majority = 0
      let wrong = 0
      const lines = []
      const results = await Promise.all(cases.map((c) => ask(q, c.candidate, { runs, model })))
      for (const [i, c] of cases.entries()) {
        const r = results[i]
        cost += r.cost
        total++
        const right = r.answer === c.answer
        const all = r.votes[c.answer] === runs
        if (all) unanimous++
        else if (right) majority++
        else wrong++
        if (right) agreed++
        lines.push(`  ${right ? (all ? '✓' : '~') : '✗'} ${c.name}: want ${c.answer}, got ${r.answer} (yes ${r.votes.yes}, no ${r.votes.no}, none ${r.votes.none})${r.errors.length ? ` — ${r.errors[0]}` : ''}`)
      }
      console.log(`${q.name}: ${cases.length} cases — ${unanimous} unanimous, ${majority} by majority, ${wrong} wrong`)
      for (const l of lines) console.log(l)
      summary.push(`${q.name}: ${agreedOf(unanimous + majority, cases.length)}${wrong ? ` — ${wrong} wrong` : ''}`)
    }
    console.log(`\njudge: ${agreed}/${total} cases gave the known answer over ${runs} runs each, model ${model}, cost $${cost.toFixed(2)}`)
    for (const s of summary) console.log(`  ${s}`)
    process.exit(agreed === total ? 0 : 1)
  }

  const name = opt('--question')
  const file = opt('--candidate')
  if (!name || !file) {
    console.error('usage: judge.mjs --question <NAME> --candidate <file.json> | --test [--question <NAME>] | --list')
    process.exit(2)
  }
  const q = questions.find((x) => x.name === name)
  if (!q) throw new Error(`no question named ${name}`)
  const r = await ask(q, JSON.parse(readFileSync(file, 'utf8')), { runs, model })
  console.log(`${name}: ${r.answer} (yes ${r.votes.yes}, no ${r.votes.no}, none ${r.votes.none}) — $${r.cost.toFixed(3)}`)
  for (const quote of r.quotes) console.log(`  "${quote}"`)
  for (const e of r.errors) console.log(`  ! ${e}`)
  process.exit(r.answer === 'yes' ? 1 : 0)
}

const agreedOf = (n, of) => `${n}/${of} right`

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main()
