import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { uiSourceDirs } from './ui-sources.mjs'

const CLI = path.join(path.dirname(fileURLToPath(import.meta.url)), 'ui-sources.mjs')

function repo(files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ui-sources-'))
  for (const [rel, content] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), typeof content === 'string' ? content : JSON.stringify(content))
  }
  return dir
}

const MONOREPO = {
  'package.json': { workspaces: ['apps/*', 'packages/*'] },
  'packages/ui/package.json': { name: '@acme/ui' },
  'packages/ui/src/button.tsx': '',
  'apps/office/package.json': { name: 'office', dependencies: { '@acme/ui': '*' } },
  'apps/office/src/main.tsx': '',
  'apps/portal/package.json': { name: 'portal', devDependencies: { '@acme/ui': '*' } },
  'apps/portal/src/main.tsx': '',
  'apps/worker/package.json': { name: 'worker', dependencies: { pg: '*' } },
  'apps/worker/src/main.ts': '',
}

test('every workspace that depends on the UI package is found, and nothing else', () => {
  const { dirs, problems } = uiSourceDirs(repo(MONOREPO), 'packages/ui')
  assert.deepEqual(problems, [])
  assert.deepEqual(dirs, ['packages/ui/src', 'apps/office/src', 'apps/portal/src'])
})

test('an app added later is found with no setting changed', () => {
  const dir = repo(MONOREPO)
  assert.ok(!uiSourceDirs(dir, 'packages/ui').dirs.includes('apps/kiosk/src'))
  fs.mkdirSync(path.join(dir, 'apps/kiosk/src'), { recursive: true })
  fs.writeFileSync(path.join(dir, 'apps/kiosk/package.json'), JSON.stringify({ name: 'kiosk', dependencies: { '@acme/ui': '*' } }))
  assert.ok(uiSourceDirs(dir, 'packages/ui').dirs.includes('apps/kiosk/src'))
})

test('a workspace with no src contributes its own folder', () => {
  const dir = repo({ ...MONOREPO, 'apps/flat/package.json': { name: 'flat', peerDependencies: { '@acme/ui': '*' } }, 'apps/flat/main.tsx': '' })
  assert.ok(uiSourceDirs(dir, 'packages/ui').dirs.includes('apps/flat'))
})

test('the workspaces field may be an object and may list folders by name', () => {
  const dir = repo({ ...MONOREPO, 'package.json': { workspaces: { packages: ['packages/ui', './apps/office/'] } } })
  assert.deepEqual(uiSourceDirs(dir, 'packages/ui').dirs, ['packages/ui/src', 'apps/office/src'])
})

test('a repository with no workspaces is one package: its src', () => {
  assert.deepEqual(uiSourceDirs(repo({ 'package.json': { name: 'web' }, 'src/main.tsx': '' }), 'src').dirs, ['src'])
  assert.deepEqual(uiSourceDirs(repo({ 'src/main.tsx': '' }), '.').dirs, ['src'])
})

test('a single-package UI folder outside src is checked too', () => {
  assert.deepEqual(uiSourceDirs(repo({ 'src/main.tsx': '', 'ui/button.tsx': '' }), 'ui').dirs, ['src', 'ui'])
})

test('a UI package with no name fails by name, since dependants are found by it', () => {
  const { dirs, problems } = uiSourceDirs(repo({ ...MONOREPO, 'packages/ui/package.json': {} }), 'packages/ui')
  assert.deepEqual(dirs, [])
  assert.match(problems[0], /packages\/ui\/package\.json {2}— has no "name"/)
})

test('a workspace pattern it cannot expand fails rather than skipping apps', () => {
  const { problems } = uiSourceDirs(repo({ ...MONOREPO, 'package.json': { workspaces: ['apps/**'] } }), 'packages/ui')
  assert.match(problems[0], /"apps\/\*\*" — only a folder or "<folder>\/\*" can be expanded/)
})

test('the command prints one folder per line from the project settings', () => {
  const dir = repo({ ...MONOREPO, '.claude/sync-substitutions.json': { DESIGN_UI_PACKAGE: 'packages/ui' } })
  assert.equal(execFileSync('node', [CLI, '--repo', dir], { encoding: 'utf8' }), 'packages/ui/src\napps/office/src\napps/portal/src\n')
})

test('the command fails loud when there is no UI package to start from', () => {
  const dir = repo({ ...MONOREPO, '.claude/sync-substitutions.json': { DESIGN_UI_PACKAGE: '' } })
  assert.throws(() => execFileSync('node', [CLI, '--repo', dir], { stdio: 'pipe' }), (e) => e.status === 1 && /DESIGN_UI_PACKAGE is not set/.test(e.stderr))
})
