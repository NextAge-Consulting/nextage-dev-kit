#!/usr/bin/env node
/**
 * Replays the kit's project-facing checks against every consumer project on this machine,
 * before the kit ships them: the committed version and the working-tree version of each
 * check that changed run read-only on each project, and a finding the new version adds is
 * a regression — the CI failure a project would meet on its next sync.
 *
 *   node .claude/kit-gate/replay.mjs <changed path>…
 *
 * Consumers are the kit's sibling folders holding .claude/.kit-sync.json. A check that does
 * not apply to a project (no design system, no package.json) is skipped for it, and said so.
 *
 * A change that breaks projects on purpose — a new pin — ships the migration that brings
 * them onto it. When a migration folder is among the changed paths, its gate-accepts.txt
 * names those findings, one literal fragment per line, and a finding holding one is
 * reported as resolved by that migration rather than as a regression.
 *
 * Prints what it replayed; exits 1 on any regression, 0 otherwise.
 */

import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const P = '_claude-project'

// What each check reads, so a change to it — or to a module it imports — replays it.
const BLOCK_TYPES = [`${P}/skills/design-system/scripts/block-types.mjs`, `${P}/skills/design-system/references/block-types.md`]
const CHECKS = [
  { name: 'token check', files: [`${P}/skills/design-system/scripts/check-design-tokens.mjs`, `${P}/skills/claude-design/scripts/resolve.mjs`, ...BLOCK_TYPES], run: tokenCheck },
  { name: 'comparison tool', files: [`${P}/skills/design-system/scripts/compare-ui-values.mjs`, `${P}/skills/design-system/scripts/check-design-tokens.mjs`], run: compareTool },
  { name: 'UI status check', files: [`${P}/skills/ui-patterns/scripts/check-ui-status.mjs`, ...BLOCK_TYPES], run: statusCheck },
  { name: 'knip config', files: [`${P}/templates/knip.config.ts`], run: knipConfig },
  { name: 'check-stack', files: [`${P}/templates/scripts/check-stack.mjs`, `${P}/stack-manifest.json`], run: (o, n, c) => scriptCheck('check-stack.mjs', o, n, c) },
  { name: 'workspace tiers', files: [`${P}/templates/scripts/check-workspace-tiers.mjs`], run: (o, n, c) => scriptCheck('check-workspace-tiers.mjs', o, n, c) },
]

// A migration folder among the changed paths may name, in gate-accepts.txt, findings it resolves.
export function acceptsFor(kit, changed) {
  const accepts = []
  for (const dir of new Set([...changed].map((f) => f.match(/^_claude-maintainer\/migrations\/[^/]+/)?.[0]).filter(Boolean))) {
    const file = path.join(kit, dir, 'gate-accepts.txt')
    if (!existsSync(file)) continue
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const fragment = line.trim()
      if (fragment && !fragment.startsWith('#')) accepts.push({ fragment, migration: path.basename(dir) })
    }
  }
  return accepts
}

async function main(paths) {
  const kit = execFileSync('git', ['rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim()
  const changed = new Set(paths)
  const accepts = acceptsFor(kit, changed)
  const acceptedBy = (finding) => accepts.find((a) => finding.includes(a.fragment))?.migration

  const due = CHECKS.filter((c) => c.files.some((f) => changed.has(f)))
  if (!due.length) {
    console.log('replay: no check that runs on project code changed — nothing to replay.')
    process.exit(0)
  }

  const consumers = readdirSync(path.dirname(kit))
    .map((n) => path.join(path.dirname(kit), n))
    .filter((d) => d !== kit && existsSync(path.join(d, '.claude/.kit-sync.json')))
  if (!consumers.length) {
    console.error('replay: no consumer project found beside the kit — nothing to replay against, so this fails.')
    process.exit(1)
  }

  // The committed kit, extracted read-only, so its checks run beside the working tree's.
  const work = mkdtempSync(path.join(os.tmpdir(), 'kit-replay-'))
  execFileSync('bash', ['-c', `git -C "$1" archive HEAD ${P} | tar -x -C "$2"`, '_', kit, work])
  const OLD = path.join(work, P)
  const NEW = path.join(kit, P)

  let regressions = 0
  let accepted = 0
  try {
    for (const check of due) {
      const started = Date.now()
      const notes = []
      let ran = 0
      for (const consumer of consumers) {
        const name = path.basename(consumer)
        let result
        try {
          result = await check.run(OLD, NEW, consumer)
        } catch (err) {
          result = { added: [`the new version failed to run: ${String(err.message ?? err).split('\n')[0]}`] }
        }
        if (result.skip) {
          notes.push(`  · ${name}: ${result.skip}`)
          continue
        }
        ran++
        const expected = result.added.filter((a) => acceptedBy(a))
        const unexpected = result.added.filter((a) => !acceptedBy(a))
        if (expected.length) {
          accepted += expected.length
          const by = [...new Set(expected.map(acceptedBy))].join(', ')
          notes.push(`  ~ ${name}: ${expected.length} new finding(s) the ${by} migration resolves`)
        }
        if (unexpected.length) {
          regressions += unexpected.length
          notes.push(`  ✗ ${name}: ${unexpected.length} new finding(s)`)
          for (const a of unexpected.slice(0, 8)) notes.push(`      ${a.split('\n')[0]}`)
          if (unexpected.length > 8) notes.push(`      … ${unexpected.length - 8} more`)
        }
      }
      console.log(`replay: ${check.name} — old and new run on ${ran} project(s), ${((Date.now() - started) / 1000).toFixed(1)}s`)
      for (const n of notes) console.log(n)
    }
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
  if (regressions) {
    console.error(`\nreplay: ${regressions} finding(s) the new version adds in projects that do not have them today. Fix the check, or the project first.`)
    process.exit(1)
  }
  console.log(
    accepted
      ? `replay: no project gains a finding beyond the ${accepted} its shipped migration resolves.`
      : 'replay: no project gains a finding.',
  )
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main(process.argv.slice(2))

// --- the checks -----------------------------------------------------------------------

function added(before, after) {
  const had = new Set(before)
  return after.filter((x) => !had.has(x))
}

async function tokenCheck(OLD, NEW, consumer) {
  const rel = 'skills/design-system/scripts/check-design-tokens.mjs'
  const run = async (root) => (await import(pathToFileURL(path.join(root, rel)).href)).checkDesignTokens(consumer)
  const now = await run(NEW)
  if (now.notApplicable) return { skip: 'no UI package' }
  const before = await run(OLD)
  return { added: added(before.problems ?? [], now.problems ?? []) }
}

async function compareTool(OLD, NEW, consumer) {
  if (!existsSync(path.join(consumer, '.git'))) return { skip: 'not a git repository' }
  const rel = 'skills/design-system/scripts/compare-ui-values.mjs'
  const run = async (root) => (await import(pathToFileURL(path.join(root, rel)).href)).compareUiValues(consumer)
  const now = await run(NEW)
  if (now.problems?.length && /no stylesheet imports tailwindcss/.test(now.problems[0])) return { skip: 'no Tailwind entry stylesheet' }
  const before = await run(OLD)
  // What it lists is the project's uncommitted work, for a reviewer: a changed group and a
  // line it could not compare cost the same look. Only growth in that total is reported,
  // so a line it now compares instead of giving up on is not a regression.
  const review = (r) => (r.changed?.length ?? 0) + (r.uncompared?.length ?? 0)
  const out = []
  const grew = review(now) - review(before)
  if (grew > 0) out.push(`${grew} more item(s) for review than the committed version lists`, ...added((before.uncompared ?? []).map(String), (now.uncompared ?? []).map(String)))
  return { added: out }
}

async function statusCheck(OLD, NEW, consumer) {
  // The check lists the project's files through git.
  if (!existsSync(path.join(consumer, '.git'))) return { skip: 'not a git repository' }
  const rel = 'skills/ui-patterns/scripts/check-ui-status.mjs'
  const run = async (root) => (await import(pathToFileURL(path.join(root, rel)).href)).checkUiStatus(consumer)
  const now = await run(NEW)
  if (now.notApplicable) return { skip: 'no component or pattern files' }
  const before = await run(OLD)
  const list = (r) => [...(r.problems ?? []), ...(r.pending ?? [])]
  return { added: added(list(before), list(now)) }
}

function knipFindings(config, consumer) {
  // The knip the project's own gate runs: the version its stack manifest pins.
  const version = JSON.parse(readFileSync(path.join(consumer, '.claude/stack-manifest.json'), 'utf8')).packages?.knip?.version
  if (!version) throw new Error('its stack manifest pins no knip version')
  const r = spawnSync('npx', ['--yes', `knip@${version}`, '--no-config-hints', '--config', config, '--reporter', 'json'], {
    cwd: consumer,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
  })
  // The report is one JSON line; a .env loader the project's config imports may print first.
  const report = r.stdout.split('\n').find((l) => l.startsWith('{"'))
  if (!report) throw new Error(`knip printed no report: ${(r.stderr || r.stdout).trim().split('\n')[0]}`)
  const j = JSON.parse(report)
  const out = (j.files ?? []).filter((f) => !f.endsWith('knip.config.ts')).map((f) => `unused file ${f}`)
  for (const i of j.issues ?? [])
    for (const [kind, items] of Object.entries(i)) if (Array.isArray(items)) for (const it of items) out.push(`${i.file}: ${kind} ${it.name}`)
  return out
}

async function knipConfig(OLD, NEW, consumer) {
  if (!existsSync(path.join(consumer, 'package.json'))) return { skip: 'no package.json' }
  if (!existsSync(path.join(consumer, '.claude/stack-manifest.json'))) return { skip: 'no stack manifest' }
  const now = knipFindings(path.join(NEW, 'templates/knip.config.ts'), consumer)
  const before = knipFindings(path.join(OLD, 'templates/knip.config.ts'), consumer)
  return { added: added(before, now) }
}

// A project's script finds the repository from its own place (scripts/..), so it runs
// from a mirror of the project — every entry linked, scripts/ holding the kit's copy.
function scriptCheck(script, OLD, NEW, consumer) {
  if (!existsSync(path.join(consumer, 'package.json'))) return { skip: 'no package.json' }
  const run = (root) => {
    const mirror = mkdtempSync(path.join(os.tmpdir(), 'kit-mirror-'))
    try {
      for (const entry of readdirSync(consumer)) {
        if (entry === 'scripts') continue
        symlinkSync(path.join(consumer, entry), path.join(mirror, entry))
      }
      mkdirSync(path.join(mirror, 'scripts'))
      if (existsSync(path.join(consumer, 'scripts')))
        for (const f of readdirSync(path.join(consumer, 'scripts'))) symlinkSync(path.join(consumer, 'scripts', f), path.join(mirror, 'scripts', f))
      rmSync(path.join(mirror, 'scripts', script), { force: true })
      cpSync(path.join(root, 'templates/scripts', script), path.join(mirror, 'scripts', script))
      // check-stack reads the stack manifest from .claude/; the kit's version is the one under test.
      if (script === 'check-stack.mjs' && lstatSync(path.join(mirror, '.claude')).isSymbolicLink()) {
        rmSync(path.join(mirror, '.claude'))
        mkdirSync(path.join(mirror, '.claude'))
        for (const e of readdirSync(path.join(consumer, '.claude'))) symlinkSync(path.join(consumer, '.claude', e), path.join(mirror, '.claude', e))
        rmSync(path.join(mirror, '.claude/stack-manifest.json'), { force: true })
        cpSync(path.join(root, 'stack-manifest.json'), path.join(mirror, '.claude/stack-manifest.json'))
      }
      const r = spawnSync('node', ['--preserve-symlinks', '--preserve-symlinks-main', path.join(mirror, 'scripts', script)], { cwd: mirror, encoding: 'utf8' })
      return { code: r.status, findings: findingsOf(`${r.stdout}\n${r.stderr}`) }
    } finally {
      rmSync(mirror, { recursive: true, force: true })
    }
  }
  const now = run(NEW)
  const before = run(OLD)
  if (now.code === 0) return { added: [] }
  const out = added(before.findings, now.findings)
  if (!out.length && before.code === 0) out.push(`exits ${now.code}, where the committed version passes`)
  return { added: out }
}

// The scripts list each finding two spaces in, its explanation on deeper-indented lines
// beneath; anything else they or the project's .env loader print is not a finding.
export function findingsOf(output) {
  const out = []
  for (const line of output.split('\n')) {
    if (/^ {2}\S/.test(line)) out.push(line.trim())
    else if (/^ {3,}\S/.test(line) && out.length) out[out.length - 1] += `\n${line.trim()}`
  }
  return out
}

