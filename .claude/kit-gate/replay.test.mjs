import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { acceptsFor, findingsOf } from './replay.mjs'

test('a finding is its two-space line plus the deeper lines beneath it', () => {
  const out = [
    '◇ injected env (12) from .env // tip: a different tip every run',
    '✗ stack standard violations:',
    '  package.json: vitest is "^4.1.4" — declare the exact blessed version "4.1.11".',
    '      A range lets a fresh install drift off the kit\'s version.',
    '  package-lock.json: vitest resolves to 4.1.9, blessed is 4.1.11.',
  ].join('\n')
  assert.deepEqual(findingsOf(out), [
    'package.json: vitest is "^4.1.4" — declare the exact blessed version "4.1.11".\nA range lets a fresh install drift off the kit\'s version.',
    'package-lock.json: vitest resolves to 4.1.9, blessed is 4.1.11.',
  ])
})

test('output with no indented line holds no finding', () => {
  assert.deepEqual(findingsOf('✓ stack: every pin matches\n◇ injected env (3)'), [])
})

test('a changed migration contributes its gate-accepts fragments; comments and blanks are not fragments', () => {
  const kit = fs.mkdtempSync(path.join(os.tmpdir(), 'replay-test-'))
  try {
    const dir = path.join(kit, '_claude-maintainer/migrations/pin-something')
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(path.join(dir, 'gate-accepts.txt'), '# why\n\n: vitest is "\n')
    fs.writeFileSync(path.join(dir, 'PROMPT.md'), 'x')
    assert.deepEqual(acceptsFor(kit, new Set(['_claude-maintainer/migrations/pin-something/PROMPT.md'])), [
      { fragment: ': vitest is "', migration: 'pin-something' },
    ])
  } finally {
    fs.rmSync(kit, { recursive: true, force: true })
  }
})

test('a migration that is not among the changed paths accepts nothing', () => {
  const kit = fs.mkdtempSync(path.join(os.tmpdir(), 'replay-test-'))
  try {
    const dir = path.join(kit, '_claude-maintainer/migrations/old')
    fs.mkdirSync(dir, { recursive: true })
    fs.writeFileSync(path.join(dir, 'gate-accepts.txt'), ': vitest is "\n')
    assert.deepEqual(acceptsFor(kit, new Set(['_claude-project/stack-manifest.json'])), [])
  } finally {
    fs.rmSync(kit, { recursive: true, force: true })
  }
})
