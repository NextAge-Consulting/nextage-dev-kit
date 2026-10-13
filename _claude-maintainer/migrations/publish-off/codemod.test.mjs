// node --test _claude-maintainer/migrations/publish-off/codemod.test.mjs
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { after, test } from 'node:test'
import { fileURLToPath } from 'node:url'

const codemod = join(dirname(fileURLToPath(import.meta.url)), 'codemod.mjs')
const dirs = []
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true })
})

function repo(tokens, config = "export default { families: { skip: /^(step-|font-)/ } }\n") {
  const root = mkdtempSync(join(tmpdir(), 'publish-off-'))
  dirs.push(root)
  const put = (p, text) => {
    mkdirSync(dirname(join(root, p)), { recursive: true })
    writeFileSync(join(root, p), text)
  }
  put('.claude/sync-substitutions.json', JSON.stringify({ DESIGN_UI_PACKAGE: 'packages/ui', DESIGN_TOKEN_FILES: 'src/tokens.css' }))
  put('packages/ui/design-system/design-system.config.mjs', config)
  put('packages/ui/src/tokens.css', tokens)
  return root
}
const run = (root, ...flags) => execFileSync('node', [codemod, root, ...flags], { encoding: 'utf8' })
const tokensOf = (root) => readFileSync(join(root, 'packages/ui/src/tokens.css'), 'utf8')

const TOKENS = `:root {
  /* ─── type ─── */
  /* the body size */
  --step-14: 14px;
  --step-16: 16px;
  --primary: oklch(0.5 0.1 250); /* actions */
  --font-sans: Inter, sans-serif;
}
.dark {
  --primary: oklch(0.7 0.1 250);
}
`

test('wraps each run of skipped declarations, carrying the comments above them, and keeps the order', () => {
  const root = repo(TOKENS)
  const report = run(root)
  assert.match(report, /3 declaration\(s\) in 2 publish: off pair/)
  assert.equal(
    tokensOf(root),
    `:root {
  /* publish: off */
  /* ─── type ─── */
  /* the body size */
  --step-14: 14px;
  --step-16: 16px;
  /* publish: on */
  --primary: oklch(0.5 0.1 250); /* actions */
  /* publish: off */
  --font-sans: Inter, sans-serif;
  /* publish: on */
}
.dark {
  --primary: oklch(0.7 0.1 250);
}
`,
  )
})

test('a dry run reports and writes nothing', () => {
  const root = repo(TOKENS)
  assert.match(run(root, '--dry-run'), /dry run — nothing written/)
  assert.equal(tokensOf(root), TOKENS)
})

test('a one-line block holding a skipped token is left for hand review', () => {
  const root = repo(':root { --step-14: 14px; }\n')
  assert.match(run(root), /hand review: line 1/)
})

test('no skip pattern means nothing to migrate', () => {
  const root = repo(TOKENS, 'export default {}\n')
  assert.match(run(root), /no families.skip — nothing to migrate/)
  assert.equal(tokensOf(root), TOKENS)
})
