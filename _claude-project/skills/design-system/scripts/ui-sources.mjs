/**
 * The project's UI source, found rather than listed: the UI package, and every workspace
 * that depends on it by name. An app added to the repository is checked from its first
 * commit, with nothing to remember.
 *
 *   uiSourceDirs(repo, uiPackage)  → { dirs, problems }, `dirs` from the repository root
 *   uiPackages(repo, uiPackage)    → { packages, problems }: the UI package's workspace folder
 *                                  and every dependant's, from the repository root
 *   workspaceImports(repo, dir)    → the source folders of workspace `dir` and of every
 *                                  workspace it depends on, transitively — what its build
 *                                  bundles, so what its stylesheet has to scan
 *   node ui-sources.mjs [--repo <dir>]
 *                                  prints the dirs one per line, reading DESIGN_UI_PACKAGE
 *                                  from .claude/sync-substitutions.json; exits 1 naming the
 *                                  problem when there is none to print
 *
 * Each workspace contributes its `src` folder, or the workspace itself when it has none.
 * A repository whose root package.json declares no workspaces is one package: its `src`,
 * or the root.
 */

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const posix = (p) => p.split(path.sep).join('/')
const DEP_FIELDS = ['dependencies', 'devDependencies', 'peerDependencies', 'optionalDependencies']

function readJson(file) {
  return JSON.parse(readFileSync(file, 'utf8'))
}

/** Where a package's source lives: its `src`, or the package folder itself. */
function sourceOf(repo, dir) {
  const src = dir === '.' ? 'src' : `${dir}/src`
  return existsSync(path.join(repo, src)) && statSync(path.join(repo, src)).isDirectory() ? src : dir
}

/** The workspace folders the root package.json declares, from the repository root. */
export function workspaceDirs(repo) {
  const rootManifest = path.join(repo, 'package.json')
  if (!existsSync(rootManifest)) return { dirs: [], problems: [] }
  const declared = readJson(rootManifest).workspaces
  const globs = Array.isArray(declared) ? declared : (declared?.packages ?? [])
  const dirs = []
  const problems = []
  for (const raw of globs) {
    const glob = raw.replace(/^\.\//, '').replace(/\/+$/, '')
    if (!/[*?[{]/.test(glob)) {
      if (existsSync(path.join(repo, glob, 'package.json'))) dirs.push(glob)
      continue
    }
    if (!/^[^*?[{]+\/\*$/.test(glob)) {
      problems.push(`package.json workspaces: "${raw}" — only a folder or "<folder>/*" can be expanded to find the UI source`)
      continue
    }
    const parent = glob.slice(0, -2)
    if (!existsSync(path.join(repo, parent))) continue
    for (const name of readdirSync(path.join(repo, parent)).sort()) {
      if (existsSync(path.join(repo, parent, name, 'package.json'))) dirs.push(`${parent}/${name}`)
    }
  }
  return { dirs: [...new Set(dirs)], problems }
}

/** The UI package's workspace folder and every workspace's that depends on it by name. A
 * repository with no workspaces is one package: the root and the UI package. */
export function uiPackages(repo, uiPackage) {
  const pkg = posix(uiPackage).replace(/^\.\//, '').replace(/\/+$/, '') || '.'
  const { dirs: workspaces, problems } = workspaceDirs(repo)
  if (problems.length) return { packages: [], problems }
  if (!workspaces.length) return { packages: ['.', pkg], problems: [] }
  const manifest = path.join(repo, pkg, 'package.json')
  if (!existsSync(manifest)) return { packages: [], problems: [`${pkg}/package.json  — not found; the UI package's name is how its dependants are found`] }
  const name = readJson(manifest).name
  if (!name) return { packages: [], problems: [`${pkg}/package.json  — has no "name"; the UI package's name is how its dependants are found`] }
  const dependants = workspaces.filter((w) => {
    if (w === pkg) return false
    const m = readJson(path.join(repo, w, 'package.json'))
    return DEP_FIELDS.some((f) => m[f] && Object.hasOwn(m[f], name))
  })
  return { packages: [pkg, ...dependants], problems: [] }
}

/** The source folders of workspace `dir` and of every workspace it depends on, transitively:
 * the code its build bundles. Its own folder comes first. */
export function workspaceImports(repo, dir) {
  const { dirs: workspaces } = workspaceDirs(repo)
  const byName = new Map()
  for (const w of workspaces) {
    const name = readJson(path.join(repo, w, 'package.json')).name
    if (name) byName.set(name, w)
  }
  const seen = new Set([dir])
  const queue = [dir]
  while (queue.length) {
    const w = queue.shift()
    const file = path.join(repo, w, 'package.json')
    if (!existsSync(file)) continue
    const m = readJson(file)
    for (const f of DEP_FIELDS) {
      for (const name of Object.keys(m[f] ?? {})) {
        const d = byName.get(name)
        if (d && !seen.has(d)) {
          seen.add(d)
          queue.push(d)
        }
      }
    }
  }
  return [...new Set([...seen].map((w) => sourceOf(repo, w)))]
}

/** The source folders of the UI package and of every workspace depending on it. */
export function uiSourceDirs(repo, uiPackage) {
  const { packages, problems } = uiPackages(repo, uiPackage)
  if (problems.length) return { dirs: [], problems }

  // A folder inside another one already listed adds nothing.
  const sources = [...new Set(packages.map((d) => sourceOf(repo, d)))]
  const within = (d, outer) => outer === '.' || d.startsWith(`${outer}/`)
  const dirs = sources.filter((d) => !sources.some((o) => o !== d && within(d, o)))
  return { dirs, problems: [] }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const at = process.argv.indexOf('--repo')
  const repo = path.resolve(at === -1 ? '.' : process.argv[at + 1])
  const subsFile = path.join(repo, '.claude/sync-substitutions.json')
  const ui = existsSync(subsFile) ? String(readJson(subsFile).DESIGN_UI_PACKAGE ?? '').trim() : ''
  if (!ui) {
    console.error('ui-sources: DESIGN_UI_PACKAGE is not set in .claude/sync-substitutions.json, so there is no UI package to start from')
    process.exit(1)
  }
  const { dirs, problems } = uiSourceDirs(repo, ui)
  if (problems.length || !dirs.length) {
    for (const p of problems) console.error(`ui-sources: ${p}`)
    if (!problems.length) console.error('ui-sources: found no UI source')
    process.exit(1)
  }
  console.log(dirs.join('\n'))
}
