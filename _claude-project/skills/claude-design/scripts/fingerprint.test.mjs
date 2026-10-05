import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { contentFingerprint, noteFingerprint } from './fingerprint.mjs'

function build(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ds-fingerprint-'))
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), content)
  }
  return dir
}
const system = (stamp, ref, day, token = '#123456') => ({
  'README.md': `# Acme\n\n${stamp}, from the repository's UI package.\n`,
  'tokens.json': JSON.stringify({ meta: { ref, synced: day }, color: { ink: token } }),
  'components/Cover/preview.html': `<p>${stamp}</p>`,
  'fonts/inter.woff2': Buffer.from([0, 1, 2, 3]),
})

test('two builds of the same code agree, whatever their release, day and commit', () => {
  const a = build(system('Release 11 · built 2026-10-04 from 6b376e2', '6b376e2', '2026-10-04'))
  const b = build(system('Release 12 · built 2026-10-05 from 9f00a1c+uncommitted', '9f00a1c+uncommitted', '2026-10-05'))
  try {
    assert.equal(contentFingerprint(a, ['Release 11 · built 2026-10-04 from 6b376e2', '6b376e2', '2026-10-04']),
      contentFingerprint(b, ['Release 12 · built 2026-10-05 from 9f00a1c+uncommitted', '9f00a1c+uncommitted', '2026-10-05']))
  } finally {
    fs.rmSync(a, { recursive: true, force: true })
    fs.rmSync(b, { recursive: true, force: true })
  }
})

test('a changed token, a changed binary, an added file or a renamed file each change it', () => {
  const stamp = 'Release 1 · built 2026-10-05 from abc1234'
  const vol = [stamp, 'abc1234', '2026-10-05']
  const base = system(stamp, 'abc1234', '2026-10-05')
  const variants = [
    base,
    system(stamp, 'abc1234', '2026-10-05', '#654321'),
    { ...base, 'fonts/inter.woff2': Buffer.from([0, 1, 2, 4]) },
    { ...base, 'components/Button/README.md': '# Button\n' },
    Object.fromEntries(Object.entries(base).map(([k, v]) => [k === 'README.md' ? 'ABOUT.md' : k, v])),
  ]
  const dirs = variants.map(build)
  try {
    const prints = dirs.map((d) => contentFingerprint(d, vol))
    assert.equal(new Set(prints).size, prints.length, prints.join(' '))
    for (const p of prints) assert.match(p, /^[0-9a-f]{12}$/)
  } finally {
    for (const d of dirs) fs.rmSync(d, { recursive: true, force: true })
  }
})

test('the note carries the fingerprint; an older note has none', () => {
  assert.equal(noteFingerprint('Release 12 · built 2026-10-05 from 6b376e2 · content 0123456789ab.'), '0123456789ab')
  assert.equal(noteFingerprint('Release 11 · built 2026-10-04 from 6b376e2.'), null)
  assert.equal(noteFingerprint(undefined), null)
})
