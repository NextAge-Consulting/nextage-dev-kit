import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseDesignChecks, readDesignChecks } from './design-checks.mjs'

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), 'design-checks.mjs')

test('the shipped checks parse: every layer has checks, names are unique', () => {
  const checks = readDesignChecks()
  assert.deepEqual([...new Set(checks.map((c) => c.layer))], [1, 2, 3, 4])
  for (const name of ['TOKEN-GAP', 'PART-TOKEN', 'PATTERN-TOKEN', 'SCREEN-TOKEN', 'SCREEN-PATTERN', 'CALL-SITE-REPAINT']) {
    assert.ok(checks.some((c) => c.name === name), name)
  }
  assert.ok(checks.find((c) => c.name === 'TOKEN-GAP').wholeLayer)
  assert.ok(!checks.find((c) => c.name === 'SCREEN-TOKEN').wholeLayer)
})

test('only headings under a numbered layer are checks, and the marker belongs to its own check', () => {
  const checks = parseDesignChecks(
    [
      '## Reporting', '### NOT-A-CHECK — prose', '',
      '## 1. Tokens', '### A-ONE — first', '*Whole layer.* text', '### A-TWO — second', 'text',
      '## Never report', '### NOR-THIS — prose',
    ].join('\n'),
  )
  assert.deepEqual(checks, [
    { name: 'A-ONE', layer: 1, title: 'first', wholeLayer: true },
    { name: 'A-TWO', layer: 1, title: 'second', wholeLayer: false },
  ])
})

test('the review list leaves out the whole-layer checks; the full list keeps them', () => {
  const all = execFileSync('node', [CLI, '--names'], { encoding: 'utf8' }).trim().split('\n')
  const review = execFileSync('node', [CLI, '--names', '--review'], { encoding: 'utf8' }).trim().split('\n')
  assert.ok(all.includes('TOKEN-GAP') && !review.includes('TOKEN-GAP'))
  assert.ok(review.includes('SCREEN-PATTERN'))
  assert.equal(all.length - review.length, readDesignChecks().filter((c) => c.wholeLayer).length)
})
