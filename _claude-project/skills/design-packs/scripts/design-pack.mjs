#!/usr/bin/env node
/**
 * Design Packs: lift one piece of a project's User Experience System out, as a folder
 * another project can install under its own tokens and roles.
 *
 *   node .claude/skills/design-packs/scripts/design-pack.mjs extract <piece> [--out <dir>] [--pack <app pack file>]
 *   node .claude/skills/design-packs/scripts/design-pack.mjs roles <folder of pieces>
 *   node .claude/skills/design-packs/scripts/design-pack.mjs coverage <folder of pieces>
 *   node .claude/skills/design-packs/scripts/design-pack.mjs approve
 *   node .claude/skills/design-packs/scripts/design-pack.mjs prove <piece folder> [--keep]
 *   node .claude/skills/design-packs/scripts/design-pack.mjs prove-all <folder of pieces> [--all | --check]
 *
 * A piece is cut from the source project and then adjusted in its folder to what any
 * project would use: what the source project added for itself comes out, there.
 *
 * A piece is a behaviour rule with its code, a recipe with its frame, or a block. Every
 * file of the system has one home piece, read from the file alone:
 *   a file carrying one rule (`// ui-behaviour`, `// ui-behaviour-code`)   that rule;
 *   a file carrying several                                               itself, named as its
 *                                                                         file is. It depends on
 *                                                                         each of those rules;
 *                                                                         they name it a carrier
 *                                                                         and are whole without it;
 *   a recipe's frame carrying none                                        that recipe;
 *   any other block                                                       itself.
 * A vendored atom is a control: a piece of its own, which a piece that imports it expects
 * of the receiving project, and which install lands only where the project has none. An
 * atom the project made travels: with the rule it carries, or with whatever imports it. A helper with no pointer travels
 * with whatever imports it, unless it is built on a generated file — the class-merge helper
 * over the generated class groups — which is the project's own and is expected like an atom.
 * A piece's files come from the UI package and the workspaces other workspaces build on.
 * An app's own code, a screen, server code and code outside the workspaces the UI lives in
 * are the source project's own: listed as a rule's code they stay behind, named for the
 * guide; imported by a piece's file they refuse the piece.
 *
 * extract   works the piece out from its pointers and imports, refuses what a pack never
 *           holds, and writes the piece folder:
 *             piece.json     files, pieces, atoms, roles, packages — and workspaces and
 *                            imports, where its files sat and what each import meant
 *             inventory.md   its inventory lines
 *             references/    the rule or recipe
 *             <the code, at its path in the source project>
 *           Code is copied as it is; a workspace's package name on an import becomes
 *           `@design-pack/<its folder>`, and a reference loses the lines naming the source
 *           project's apps and screens. It then lists what a person rewrites in the folder:
 *           comments and prose.
 *
 * A piece is found and reused by what it is called, so it reads best in words any project
 * would use. Domain words are listed for rewording; they refuse nothing.
 *
 * prove     checks the folder after that work: its code is the source's, comments
 *           aside or adjusted — it says which files were adjusted — and counts what still
 *           reads in the source project's own domain words, as advice. Then it installs the piece, with every piece it depends on, into an
 *           empty project — the expected atoms as stubs, the packages linked at the versions
 *           it ran on, the source project's stylesheets and nothing else of it — where it
 *           must typecheck, build, and pass the token check and the status check.
 *
 * Both run in the source project, against a clean tree with nothing pending, and change
 * nothing in it. Each prints what it inspected and exits 1 naming every problem.
 */

import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { checkDesignTokens, classNames, classText, loadTypeScript, parityProblems, purposesOf, rolesOf } from '../../design-system/scripts/check-design-tokens.mjs'
import { classTokens, componentBindings, readRepo } from '../../design-system/scripts/locate.mjs'
import { uiPackages } from '../../design-system/scripts/ui-sources.mjs'
import { checkUiStatus, frontmatter, headers, isComponent, key, listOf } from '../../ui-patterns/scripts/check-ui-status.mjs'

export const PACK_SCOPE = '@design-pack'
export const DEFAULT_OUT = 'project-documentation/temporary/design-pack'
/** The answers a person gives while a pack is installed: `standIn` and `beside`. */
export const ANSWERS = 'project-documentation/temporary/design-pack-answers.json'
/** Files every project built on the kit has one of its own, by name: a piece imports the
 * project's and never holds it. */
const EVERY_PROJECT_HAS = new Set(['logger', 'userfacingerror'])
export const PACKS_REPOSITORY = 'https://github.com/NextAge-Consulting/uxes-design-packs'
const REFERENCES = '.claude/skills/ui-patterns/references'
const INVENTORY = '.claude/rules/project/ui-inventory.md'
const posix = (p) => p.split(path.sep).join('/')
const isCode = (f) => /\.tsx?$/.test(f) && !f.endsWith('.d.ts')
const isGenerated = (f) => /\.(gen|generated)\.tsx?$/.test(f)

/** Words too common in any codebase to name a project: folder and route names that say nothing. */
const GENERIC = new Set(
  'index route routes root new edit api app apps ui web src lib libs shared core client server home login logout settings search help error errors auth layout layouts components features packages test tests main www site design system public assets styles hooks utils types'.split(' '),
)

// ─── reading the system ──────────────────────────────────────────────────────

/** A file's name as a piece or an inventory line names it: its own, or its folder's for an index. */
export function stemOf(file) {
  const parts = file.split('/')
  const base = parts.at(-1).replace(/\.(tsx?|md)$/, '')
  return base === 'index' ? parts.at(-2) : base
}

/** Everything extract reads about the source project, once. `problems` when it cannot be read. */
export function readSystem(repo) {
  const R = readRepo(repo, { all: true })
  if (R.notApplicable) return { problems: [R.notApplicable] }
  if (R.problems) return { problems: R.problems }
  const root = fs.realpathSync(repo)
  // The workspaces the system lives in: the UI package and every workspace depending on it.
  const homes = uiPackages(root, R.pkgRel).packages.filter((w) => w !== '.')
  const inSystem = (f) => !R.workspaces.length || homes.some((w) => f.startsWith(`${w}/`))
  // A piece's files come from the workspaces others build on: the UI package, and any
  // workspace of the system another workspace depends on. An app's own code is its own.
  const manifests = new Map()
  const manifest = (w) => {
    if (!manifests.has(w)) {
      try {
        manifests.set(w, JSON.parse(fs.readFileSync(path.join(root, w, 'package.json'), 'utf8')))
      } catch {
        manifests.set(w, {})
      }
    }
    return manifests.get(w)
  }
  const dependsOn = (w, name) => ['dependencies', 'devDependencies', 'peerDependencies'].some((k) => name && manifest(w)[k] && Object.hasOwn(manifest(w)[k], name))
  const shared = homes.filter((w) => w === R.pkgRel || R.workspaces.some((o) => o !== w && dependsOn(o, manifest(w).name)))
  const travels = (f) => !R.workspaces.length || shared.some((w) => f.startsWith(`${w}/`))
  const packOf = (w) => `${PACK_SCOPE}/${path.basename(w)}`
  const refs = new Map() // piece name → { file, text, fm }
  for (const [file, text] of R.refs) refs.set(path.basename(file, '.md'), { file, text, fm: frontmatter(text) ?? {} })
  const frames = new Map() // a frame component's key → the recipe that names it
  for (const [name, r] of refs) if (r.fm.kind === 'recipe' && r.fm.frame) frames.set(key(r.fm.frame.split('/').at(-1)), name)
  // Each workspace's package name, with the name a pack gives it on an import.
  const names = new Map()
  for (const w of R.workspaces) if (manifest(w).name) names.set(manifest(w).name, packOf(w))
  return { repo: root, R, pkgRel: R.pkgRel, homes, inSystem, travels, packOf, refs, frames, names, ts: loadTypeScript(root) }
}

/**
 * What a file of the project is to a pack:
 *   piece      a block, or code carrying a rule: `piece` is its home;
 *   atom       an atom: `home` is its home when it carries a rule, else null;
 *   helper     code with no pointer, travelling with what imports it;
 *   ambient    a declaration file, travelling as it is;
 *   generated  a generated file, which never travels;
 *   own        the source project's own — business code, an app's code, a screen, server
 *              code — which no piece holds: `why` says which.
 */
export function classify(S, file) {
  if (isGenerated(file)) return { kind: 'generated' }
  if (!S.inSystem(file)) return { kind: 'own', why: "it is the project's own code, outside the workspaces its UI lives in" }
  if (!S.travels(file)) return { kind: 'own', why: "it is an app's own code" }
  if (/\.server\.tsx?$/.test(file)) return { kind: 'own', why: 'it is server code' }
  const parts = file.split('/')
  if (parts.includes('features') || parts.includes('routes')) return { kind: 'own', why: 'it is a screen or a screen\'s content' }
  if (file.endsWith('.d.ts') || !/\.tsx?$/.test(file)) return { kind: 'ambient' }
  const src = S.R.sources.get(file)
  if (src === undefined) return { kind: 'own', why: 'it is not in the UI source' }
  const h = headers(src)
  if (h.recipe) return { kind: 'own', why: 'it is a screen' }
  const rules = [...h.behaviour, ...h.behaviourCode].map((r) => r.replace(/\.md$/, ''))
  // One rule: the rule's piece. Several: a piece of its own, which each of them depends on.
  const carried = rules.length === 1 ? rules[0] : rules.length ? stemOf(file) : null
  if (isComponent(file)) {
    if (h.atom || S.R.isAtomFile(file)) return { kind: 'atom', rules, home: carried }
    return { kind: 'piece', rules, piece: carried ?? S.frames.get(key(stemOf(file))) ?? stemOf(file) }
  }
  return carried ? { kind: 'piece', rules, piece: carried } : { kind: 'helper', rules }
}

/** The compiler options the nearest tsconfig gives a file. */
function optionsFor(S, file) {
  S.options ??= new Map()
  let d = path.dirname(file)
  while (d !== '.' && !fs.existsSync(path.join(S.repo, d, 'tsconfig.json'))) d = path.dirname(d)
  const cfg = fs.existsSync(path.join(S.repo, d, 'tsconfig.json')) ? path.join(S.repo, d, 'tsconfig.json') : ''
  if (!S.options.has(cfg)) {
    const { ts } = S
    const parsed = cfg ? ts.getParsedCommandLineOfConfigFile(cfg, {}, { ...ts.sys, onUnRecoverableConfigFileDiagnostic() {} }) : null
    S.options.set(cfg, { jsx: ts.JsxEmit.Preserve, moduleResolution: ts.ModuleResolutionKind.Bundler, module: ts.ModuleKind.ESNext, ...(parsed?.options ?? {}), noEmit: true })
  }
  return S.options.get(cfg)
}

/** The project file a module specifier resolves to from `file`, from the repository root;
 * null when it is a package's or resolves to nothing. */
export function resolveModule(S, file, spec) {
  const { ts } = S
  const hit = ts.resolveModuleName(spec, path.join(S.repo, file), optionsFor(S, file), ts.sys).resolvedModule?.resolvedFileName
  if (!hit) return null
  let real = hit
  try {
    real = fs.realpathSync(hit)
  } catch {}
  const rel = posix(path.relative(S.repo, real))
  return rel.startsWith('..') || rel.split('/').includes('node_modules') ? null : rel
}

/** Every module a source file names: each import, re-export and dynamic import, with the
 * names it binds and where its specifier sits in the text. */
export function importsOf(ts, file, text) {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  const out = []
  const at = (lit) => ({ spec: lit.text, start: lit.getStart(sf) + 1, end: lit.end - 1 })
  const visit = (n) => {
    if (ts.isImportDeclaration(n) && ts.isStringLiteral(n.moduleSpecifier)) {
      const c = n.importClause
      const nb = c?.namedBindings
      out.push({
        ...at(n.moduleSpecifier),
        bound: [
          ...(c?.name ? [{ imported: 'default', local: c.name.text }] : []),
          ...(nb && ts.isNamedImports(nb) ? nb.elements.map((e) => ({ imported: (e.propertyName ?? e.name).text, local: e.name.text })) : []),
        ],
        namespace: nb && ts.isNamespaceImport(nb) ? nb.name.text : null,
        whole: !c,
      })
    } else if (ts.isExportDeclaration(n) && n.moduleSpecifier && ts.isStringLiteral(n.moduleSpecifier)) {
      out.push({ ...at(n.moduleSpecifier), bound: [], namespace: null, whole: true })
    } else if (ts.isCallExpression(n) && n.expression.kind === ts.SyntaxKind.ImportKeyword && n.arguments[0] && ts.isStringLiteral(n.arguments[0])) {
      out.push({ ...at(n.arguments[0]), bound: [], namespace: null, whole: true })
    } else if (ts.isImportTypeNode(n) && ts.isLiteralTypeNode(n.argument) && ts.isStringLiteral(n.argument.literal)) {
      out.push({ ...at(n.argument.literal), bound: [], namespace: null, whole: true })
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
  return out
}

/** A package's name from a bare specifier: `react-aria` of `react-aria/x`, `@a/b` of `@a/b/c`. */
export const packageOf = (spec) => spec.split('/').slice(0, spec.startsWith('@') ? 2 : 1).join('/')

/** Where a package is installed for code in `fromDir`, walking up as Node does; null when it is not. */
export function packageDir(name, fromDir) {
  for (let d = fromDir; ; d = path.dirname(d)) {
    const at = path.join(d, 'node_modules', name)
    if (fs.existsSync(path.join(at, 'package.json'))) return at
    if (path.dirname(d) === d) return null
  }
}

/**
 * What one source file depends on: `files`, each project file with the names taken from it;
 * `packages`, each library's name; `unresolved`, each specifier of the project's own code
 * that resolves to nothing.
 */
export function dependenciesOf(S, file) {
  const text = S.R.sources.get(file) ?? fs.readFileSync(path.join(S.repo, file), 'utf8')
  const bind = componentBindings(S.R).get(file) ?? new Map()
  const files = new Map()
  const packages = new Set()
  const unresolved = []
  const take = (target, name) => files.set(target, (files.get(target) ?? new Set()).add(name))
  const isProject = (t) => !!t && !t.startsWith('..') && !t.split('/').includes('node_modules')
  for (const d of importsOf(S.ts, file, text)) {
    const module = resolveModule(S, file, d.spec)
    let project = false
    for (const b of d.bound) {
      const t = bind.get(b.local)
      if (isProject(t)) {
        take(t, b.imported)
        project = true
      } else if (module) {
        take(module, b.imported)
        project = true
      }
    }
    if (d.namespace) {
      let any = false
      for (const [k, t] of bind) {
        if (!k.startsWith(`${d.namespace}.`) || !isProject(t)) continue
        take(t, k.slice(d.namespace.length + 1))
        any = true
      }
      if (!any && module) take(module, '*')
      project ||= any || !!module
    }
    if (d.whole && module) {
      take(module, '*')
      project = true
    }
    if (project) continue
    const own = d.spec.startsWith('.') || d.spec.startsWith('/') || [...S.names.keys()].some((n) => d.spec === n || d.spec.startsWith(`${n}/`))
    if (own) unresolved.push(d.spec)
    else packages.add(packageOf(d.spec))
  }
  files.delete(file)
  return { files, packages, unresolved }
}

/** Whether a helper is built on a generated file, itself or through the helpers it imports. */
function onGenerated(S, file, seen = new Set()) {
  if (seen.has(file)) return false
  seen.add(file)
  for (const t of dependenciesOf(S, file).files.keys()) {
    const c = classify(S, t)
    if (c.kind === 'generated' || (c.kind === 'helper' && onGenerated(S, t, seen))) return true
  }
  return false
}

// ─── working a piece out ─────────────────────────────────────────────────────

/** The component file an inventory name or a frame names — or, with `any`, the file of any
 * kind named so — or null. */
/** Whether a component of the system imports `file`: an atom one does travels with it. */
function carriedByAComponent(S, file) {
  if (!S.importedByComponents) {
    S.importedByComponents = new Set()
    for (const g of S.R.sources.keys()) {
      if (!isComponent(g) || !S.inSystem(g)) continue
      for (const [t] of dependenciesOf(S, g).files) if (t !== g) S.importedByComponents.add(t)
    }
  }
  return S.importedByComponents.has(file)
}

function componentNamed(S, name, any = false) {
  const want = key(name.split('/').at(-1))
  const found = [...S.R.sources.keys()].filter((f) => (any || isComponent(f)) && S.inSystem(f) && key(stemOf(f)) === want)
  return found.find((f) => name.includes('/') && key(f).endsWith(key(name))) ?? found.find(isComponent) ?? found[0] ?? null
}

/**
 * The piece named `name`: `{ kind, reference, files, kept, pieces, atoms, packages, problems }`.
 * `files` are the source files that travel, from the repository root; `kept` the files a
 * rule lists as its code that are the source project's own — its server half, an app's
 * wiring — and stay there; `atoms` maps each expected file to the exports taken from it;
 * `packages` maps each library to its version; `carriers` names the pieces that carry this
 * rule beside others, which it is whole without.
 */
export function workOut(S, name) {
  const problems = []
  const kept = []
  const carriers = new Set()
  const travel = new Set()
  const pieces = new Set()
  const atoms = new Map()
  const packages = new Map()
  const queue = []
  const take = (f) => {
    if (travel.has(f)) return
    travel.add(f)
    if (isCode(f)) queue.push(f)
  }
  const expect = (f, names) => atoms.set(f, new Set([...(atoms.get(f) ?? []), ...names]))
  const ref = S.refs.get(name)
  let kind = null

  if (ref) {
    kind = ref.fm.kind
    if (kind === 'behaviour') {
      for (const f of listOf(ref.fm.code)) {
        const c = classify(S, f)
        const home = c.kind === 'atom' ? c.home : c.piece
        if (c.kind === 'own') kept.push(f)
        else if (c.kind !== 'piece' && c.kind !== 'atom') problems.push(`${ref.file}: lists \`${f}\` as its code, and ${c.why ?? 'it carries no pointer to a rule'} — a rule's code is a block, an atom or code carrying \`// ui-behaviour-code\``)
        else if (home === name) take(f)
        // A file that carries this rule among others is a piece of its own. The rule does
        // not need it: it needs the rule.
        else if (home) carriers.add(home)
        else problems.push(`${ref.file}: lists \`${f}\` as its code, which does not point back at it`)
      }
    } else if (kind === 'recipe') {
      const frame = ref.fm.frame ? componentNamed(S, ref.fm.frame) : null
      if (!frame) problems.push(`${ref.file}: frame \`${ref.fm.frame ?? ''}\` names no component of the system`)
      else {
        const c = classify(S, frame)
        if (c.kind === 'piece' && c.piece === name) take(frame)
        else if (c.kind === 'piece') pieces.add(c.piece)
        else if (c.kind === 'own') problems.push(`${ref.file}: its frame \`${frame}\` cannot travel: ${c.why} — a recipe's frame is a block in a workspace other apps build on`)
        else problems.push(`${ref.file}: its frame \`${frame}\` is not a block`)
      }
      // Every block the instructions name is a piece this one is installed with.
      const body = ref.text.replace(/^---\n[\s\S]*?\n---/, '')
      const named = new Set([...body.matchAll(/`<?([A-Za-z][\w-]*)/g)].map((m) => key(m[1])))
      for (const f of S.R.sources.keys()) {
        if (!isComponent(f) || !S.inSystem(f) || travel.has(f) || !named.has(key(stemOf(f)))) continue
        const c = classify(S, f)
        if (c.kind === 'piece' && c.piece !== name) pieces.add(c.piece)
        else if (c.kind === 'atom' && !S.R.isAtomFile(f) && c.home && c.home !== name) pieces.add(c.home)
        else if (c.kind === 'atom' && !S.R.isAtomFile(f) && !c.home && !carriedByAComponent(S, f)) pieces.add(stemOf(f))
      }
    } else problems.push(`${ref.file}: no \`kind:\` — a reference is a recipe or a behaviour rule`)
    // An atom the project made that the prose tells a builder to use comes with it: a
    // reference never names a component the pack does not hold.
    if (kind === 'behaviour') {
      const body = ref.text.replace(/^---\n[\s\S]*?\n---/, '')
      const named = new Set([...body.matchAll(/`<?([A-Za-z][\w-]*)/g)].map((m) => key(m[1])))
      for (const f of S.R.sources.keys()) {
        if (!isComponent(f) || !S.inSystem(f) || travel.has(f) || S.R.isAtomFile(f) || !named.has(key(stemOf(f)))) continue
        const c = classify(S, f)
        if (c.kind === 'atom' && !c.home && !carriedByAComponent(S, f)) pieces.add(stemOf(f))
      }
    }
  } else {
    const file = componentNamed(S, name, true)
    if (!file) return { problems: [`\`${name}\` names no recipe or behaviour rule in ${REFERENCES}/ and no block of the system`] }
    const c = classify(S, file)
    const home = c.kind === 'atom' ? c.home : c.piece
    // A vendored atom is a control: a piece of its own, which lands only in a project that
    // has no control of that name.
    if (c.kind === 'atom' && !home && S.R.isAtomFile(file)) kind = 'control'
    // An atom the project made that carries no rule is a piece of its own: a recipe or rule
    // that tells a builder to use it brings it.
    else if (c.kind === 'atom' && !home) kind = 'atom'
    else if (c.kind !== 'piece' && c.kind !== 'atom') return { problems: [`\`${name}\` (${file}) is not a block: ${c.why ?? 'it carries no block type and no rule'}`] }
    else if (key(home) !== key(name)) return { problems: [`\`${name}\` (${file}) travels in the piece \`${home}\`, ${c.rules.length === 1 ? 'whose rule it carries' : 'whose frame it is'} — extract that`] }
    else kind = 'block'
    take(file)
  }

  while (queue.length) {
    const f = queue.shift()
    const own = classify(S, f)
    for (const r of own.rules ?? []) if (r !== name) pieces.add(r)
    const deps = dependenciesOf(S, f)
    for (const spec of deps.unresolved) problems.push(`${f}: imports \`${spec}\`, which resolves to nothing`)
    // A file that draws needs React for its markup, whether or not it imports it by name.
    if (f.endsWith('.tsx')) deps.packages.add('react')
    for (const p of deps.packages) {
      if (packages.has(p)) continue
      const dir = packageDir(p, path.dirname(path.join(S.repo, f)))
      if (!dir) problems.push(`${f}: imports \`${p}\`, which is not installed — its version cannot be read`)
      else packages.set(p, JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8')).version)
    }
    for (const [t, names] of deps.files) {
      const c = classify(S, t)
      if (c.kind === 'own' && EVERY_PROJECT_HAS.has(key(stemOf(t)))) expect(t, names)
      else if (c.kind === 'own') problems.push(`${f}: imports \`${t}\`, and ${c.why} — a pack holds no business code`)
      else if (c.kind === 'generated') problems.push(`${f}: imports the generated file \`${t}\`, which only this project's build writes`)
      else if (c.kind === 'ambient') take(t)
      else if (c.kind === 'atom') {
        if (c.home === name) take(t)
        // A vendored atom is stock: the receiving project has its own. An atom the project
        // made is part of what it built: it comes with the rule it carries, or with whatever
        // imports it.
        else if (S.R.isAtomFile(t)) expect(t, names)
        else if (c.home) pieces.add(c.home)
        else take(t)
      } else if (c.kind === 'piece') {
        if (c.piece === name) take(t)
        else pieces.add(c.piece)
      } else if (onGenerated(S, t)) expect(t, names)
      else take(t)
    }
  }
  // A rule with no code of its own is carried only by its carriers: it is installed with them.
  if (kind === 'behaviour' && ![...travel].some(isCode)) {
    for (const c of carriers) pieces.add(c)
    if (!carriers.size) problems.push(`${ref.file}: every file that carries it is the source project's own (${kept.join(', ') || 'none listed'}) — nothing of it can travel`)
  }
  pieces.delete(name)
  return {
    kind,
    kept,
    carriers: [...carriers].sort(),
    reference: ref?.file ?? null,
    files: [...travel].sort(),
    pieces: [...pieces].sort(),
    atoms: new Map([...atoms].sort(([a], [b]) => a.localeCompare(b))),
    packages: new Map([...packages].sort(([a], [b]) => a.localeCompare(b))),
    problems,
  }
}

/**
 * The roles the classes of `files` use, each by name and purpose, with the classes that
 * read it: a type role or a named
 * utility is its own role; any other class uses the tokens Tailwind's build says it reads.
 * `tokensOf(file, class)` is that build's answer; `sources` and `css` are the texts read.
 */
export function rolesUsed({ files, sources, css, tokensOf, carries = [] }) {
  const defined = rolesOf(css)
  const purposes = purposesOf(css)
  const declared = new Set()
  for (const [, s] of css) for (const m of s.matchAll(/(--[A-Za-z0-9-]+)\s*:/g)) declared.add(m[1])
  const names = classNames(sources.values())
  const used = new Map()
  const use = (role, cls) => used.set(role, (used.get(role) ?? new Set()).add(cls))
  for (const file of files) {
    const src = sources.get(file)
    if (src === undefined) continue
    for (const m of src.matchAll(/var\((--[A-Za-z0-9-]+)/g)) if (declared.has(m[1])) use(m[1], `var(${m[1]})`)
    const seen = new Set()
    for (const raw of classText(src, { names }).split(/\s+/)) {
      const cls = raw.replace(/^["'`]+|["'`,]+$/g, '')
      if (!cls || seen.has(cls) || !/^[\w!@[-]/.test(cls)) continue
      seen.add(cls)
      const base = cls.split(':').pop().replace(/^!|!$/g, '')
      if (defined.typeRoles.has(base) || defined.utilities.has(base)) use(base, base)
      for (const t of tokensOf(file, cls)) if (declared.has(t)) use(t, base)
    }
  }
  const values = carries.length ? valuesOf(css) : new Map()
  return [...used].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([name, classes]) => {
    const why = whyCarried(carries, name)
    return { name, purpose: purposes.get(name) ?? '', classes: [...classes].sort(), ...(why && values.has(name) ? { value: values.get(name), why } : {}) }
  })
}

/** Whether `name` matches `pattern`, where `*` stands for any run of characters. */
function matches(pattern, name) {
  const parts = pattern.split('*')
  if (parts.length === 1) return pattern === name
  if (!name.startsWith(parts[0]) || !name.endsWith(parts.at(-1))) return false
  let at = parts[0].length
  for (const part of parts.slice(1, -1)) {
    const found = name.indexOf(part, at)
    if (found === -1) return false
    at = found + part.length
  }
  return at <= name.length - parts.at(-1).length
}

/**
 * The reason a pack carries the value of the role `name`, or null. A pack's file lists what
 * is part of its nature — `carries: [{ roles: ["--gap-*"], why: "a back office is compact" }]`
 * — and only a role one of those entries names travels with a value. The kit decides none
 * of it.
 */
export function whyCarried(carries, name) {
  return carries.find((c) => c.roles.some((r) => matches(r, name)))?.why ?? null
}

/** What is wrong with a pack's `carries` list. A value travels only with its reason. */
export function carriesProblems(carries) {
  if (carries === undefined) return []
  if (!Array.isArray(carries)) return ['`carries` is a list of `{ "roles": [<role names, `*` for any run>], "why": "<why they are part of this pack>" }`']
  return carries.flatMap((c, i) => [
    ...(Array.isArray(c?.roles) && c.roles.length && c.roles.every((r) => typeof r === 'string' && r) ? [] : [`carries[${i}]: \`roles\` names the roles whose values travel`]),
    ...(typeof c?.why === 'string' && c.why.trim() ? [] : [`carries[${i}]: no \`why\` — a pack carries a value only with the reason it is part of what the pack is`]),
  ])
}

/** The source project's value of every token, and the body of every named utility. */
export function valuesOf(css) {
  const out = new Map()
  for (const [, s] of css) {
    for (const m of s.matchAll(/^\s*(--[A-Za-z0-9-]+)\s*:\s*([^;]+);/gm)) if (!out.has(m[1])) out.set(m[1], m[2].trim())
    for (const m of s.matchAll(/@utility\s+([a-z][a-z0-9-]*)\s*\{([^{}]*)\}/g)) {
      if (!out.has(m[1])) out.set(m[1], m[2].split(';').map((d) => d.trim()).filter(Boolean).join('; '))
    }
  }
  return out
}

// ─── business words ──────────────────────────────────────────────────────────

/** A text as lower-case words, a plural folded onto its singular: `MeterReadings` → meter, reading. */
export function wordsOf(text) {
  return (String(text).match(/[A-Za-z][a-z]+|[A-Z]+(?![a-z])/g) ?? []).map((w) => {
    const l = w.toLowerCase()
    return l.length > 3 && l.endsWith('s') && !l.endsWith('ss') ? l.slice(0, -1) : l
  })
}

/**
 * The words that name this project or what it is about, each as the run of words it is
 * written in: the repository, its packages and their scopes, its apps, and every feature
 * folder and route. A word the system's own blocks, references and block types are named
 * with is not one, and neither is a word any codebase uses. `extra` adds words; `allow`
 * removes them.
 */
export function businessWords(S, { extra = [], allow = [] } = {}) {
  const system = new Set()
  for (const f of S.R.sources.keys()) if (isComponent(f) && S.inSystem(f)) for (const w of wordsOf(stemOf(f))) system.add(w)
  for (const name of S.refs.keys()) for (const w of wordsOf(name)) system.add(w)
  for (const t of S.R.types.names ?? []) for (const w of wordsOf(t)) system.add(w)
  const allowed = new Set(allow.flatMap((a) => wordsOf(a)))
  const out = new Map()
  const add = (name, always = false) => {
    const seq = wordsOf(name)
    if (!seq.length) return
    if (!always && seq.every((w) => system.has(w) || GENERIC.has(w) || w.length < 3)) return
    if (seq.every((w) => allowed.has(w))) return
    out.set(seq.join(' '), seq)
  }
  const pkgName = (dir) => {
    try {
      return JSON.parse(fs.readFileSync(path.join(S.repo, dir, 'package.json'), 'utf8')).name ?? ''
    } catch {
      return ''
    }
  }
  add(path.basename(S.repo))
  for (const dir of ['.', ...S.R.workspaces]) {
    if (dir !== '.') add(path.basename(dir))
    for (const part of pkgName(dir).split('/')) add(part.replace(/^@/, ''))
  }
  try {
    const url = execFileSync('git', ['-C', S.repo, 'config', '--get', 'remote.origin.url'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    for (const part of url.replace(/\.git$/, '').split(/[/:]/).slice(-2)) add(part)
  } catch {}
  for (const f of S.R.sources.keys()) {
    const parts = f.split('/')
    for (const dir of ['features', 'routes']) {
      const i = parts.indexOf(dir)
      if (i === -1) continue
      for (const seg of parts.slice(i + 1)) add(seg.replace(/\.(tsx?)$/, '').replace(/[$_.[\]()]/g, ' '))
    }
  }
  for (const w of extra) add(w, true)
  return [...out.values()]
}

/** A file's lines split into the code and the comment each holds. */
export function splitComments(text, isProse = false) {
  let inBlock = false
  return text.split('\n').map((line) => {
    if (isProse) return { code: '', comment: line }
    if (inBlock) {
      if (line.includes('*/')) inBlock = false
      return { code: '', comment: line }
    }
    const open = line.lastIndexOf('/*')
    if (open !== -1 && !line.slice(open).includes('*/')) {
      inBlock = true
      return { code: line.slice(0, open).replace(/\/\/.*$/, ''), comment: line.slice(open) }
    }
    const code = line.replace(/\{\s*\/\*[\s\S]*?\*\/\s*\}/g, '').replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/, '')
    return { code, comment: code.trim() === line.trim() ? '' : line }
  })
}

/** Each business word a text holds: `{ line, word, where }`, `where` being code or comment. */
export function wordHits(text, vocabulary, { prose = false } = {}) {
  const hits = []
  splitComments(text, prose).forEach(({ code, comment }, i) => {
    for (const [where, part] of [['code', code], ['comment', comment]]) {
      if (!part) continue
      const words = wordsOf(where === 'comment' && !prose ? part.replace(code, ' ') : part)
      for (const seq of vocabulary) {
        for (let k = 0; k + seq.length <= words.length; k++) {
          if (!seq.every((w, j) => words[k + j] === w)) continue
          hits.push({ line: i + 1, word: seq.join(' '), where })
          break
        }
      }
    }
  })
  return hits
}

/** The text a person reads in a component: each JSX text and each string holding a capital
 * letter or a long number — where a label or a sample value would sit. */
export function readableStrings(ts, file, text) {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  const out = []
  const line = (n) => sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1
  const visit = (n) => {
    if (ts.isImportDeclaration(n) || ts.isExportDeclaration(n)) return
    if (ts.isJsxText(n) && n.text.trim()) out.push({ line: line(n), text: n.text.replace(/\s+/g, ' ').trim() })
    else if ((ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) && (/[A-Z]/.test(n.text) || /\d{4,}/.test(n.text))) out.push({ line: line(n), text: n.text })
    ts.forEachChild(n, visit)
  }
  visit(sf)
  return out
}

// ─── writing the piece ───────────────────────────────────────────────────────

/** A source text with each workspace's package name on a module specifier replaced by the
 * name `names` gives it. */
export function renamePackage(ts, file, text, names) {
  let out = text
  for (const d of importsOf(ts, file, text).sort((a, b) => b.start - a.start)) {
    for (const [from, to] of names) {
      if (!to || (d.spec !== from && !d.spec.startsWith(`${from}/`))) continue
      out = out.slice(0, d.start) + to + d.spec.slice(from.length) + out.slice(d.end)
      break
    }
  }
  return out
}

/** A reference as the pack holds it: the lines that name the source project's apps and
 * screens left out, and its `code:` without the files in `kept`, which stay behind. */
export function packReference(text, kept = []) {
  const m = text.match(/^---\n([\s\S]*?)\n---/)
  if (!m) return text
  const lines = m[1].split('\n').flatMap((line) => {
    if (/^(apps|reference):/.test(line)) return []
    const code = line.match(/^code:\s*(.*)$/)
    return code ? [`code: [${listOf(code[1]).filter((f) => !kept.includes(f)).join(', ')}]`] : [line]
  })
  return `---\n${lines.join('\n')}\n---${text.slice(m[0].length)}`
}

/** The inventory's lines for a piece's files, each table under the heading row it came from. */
export function inventoryLines(S, plan) {
  const lines = S.R.inventoryLines
  const wanted = new Map()
  for (const f of plan.files) if (isComponent(f)) wanted.set(f, isComponent)
  const refName = plan.reference ? path.basename(plan.reference) : null
  const tables = new Map() // header line number → row line numbers
  for (const row of S.R.rows) {
    const isRef = row.name.endsWith('.md')
    const want = key(row.name.split('/').at(-1))
    const hit = isRef ? refName && key(refName) === want : [...wanted.keys()].some((f) => key(stemOf(f)) === want && (!row.name.includes('/') || key(f).endsWith(key(row.name))))
    if (!hit) continue
    let h = row.line - 1
    while (h > 0 && lines[h - 1].trimStart().startsWith('|')) h--
    tables.set(h, [...(tables.get(h) ?? []), row.line - 1])
  }
  const out = []
  for (const [h, rows] of [...tables].sort(([a], [b]) => a - b)) out.push(lines[h], lines[h + 1], ...rows.map((r) => lines[r]), '')
  return out.join('\n')
}

/**
 * What a piece's code asks of the files it expects, beyond their names: for each export,
 * each prop it is given and each literal value passed for it — `variant: ["quiet"]` — in
 * a tag or in a call with an object of options.
 */
export function usesOf(S, plan) {
  const { ts } = S
  const out = new Map() // expected file → export → prop → values
  const note = (file, name, prop, value) => {
    const exportsOfFile = out.get(file) ?? out.set(file, new Map()).get(file)
    const props = exportsOfFile.get(name) ?? exportsOfFile.set(name, new Map()).get(name)
    const values = props.get(prop) ?? props.set(prop, new Set()).get(prop)
    if (value !== null) values.add(value)
  }
  for (const f of plan.files.filter(isCode)) {
    const text = S.R.sources.get(f)
    if (text === undefined) continue
    const bind = componentBindings(S.R).get(f) ?? new Map()
    const local = new Map() // local name → [expected file, exported name]
    for (const d of importsOf(ts, f, text)) for (const b of d.bound) if (plan.atoms.has(bind.get(b.local))) local.set(b.local, [bind.get(b.local), b.imported])
    if (!local.size) continue
    const sf = ts.createSourceFile(f, text, ts.ScriptTarget.Latest, true, f.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
    const literal = (n) => (n && (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) ? n.text : n && ts.isJsxExpression(n) && n.expression ? literal(n.expression) : null)
    // A variant or an option: a prop given one plain word, and never a class list, an
    // accessibility attribute or a native attribute any element takes.
    const option = (prop, value) => value !== null && /^[a-z][a-z0-9-]*$/.test(value) && !/^(className|class|role|type|id|key|name|htmlFor|autoComplete|inputMode|title|placeholder|label)$|^(aria|data)-|^on[A-Z]/.test(prop)
    const visit = (n) => {
      if ((ts.isJsxOpeningElement(n) || ts.isJsxSelfClosingElement(n)) && ts.isIdentifier(n.tagName) && local.has(n.tagName.text)) {
        for (const a of n.attributes.properties) if (ts.isJsxAttribute(a) && ts.isIdentifier(a.name) && option(a.name.text, literal(a.initializer))) note(...local.get(n.tagName.text), a.name.text, literal(a.initializer))
      } else if (ts.isCallExpression(n) && ts.isIdentifier(n.expression) && local.has(n.expression.text) && n.arguments[0] && ts.isObjectLiteralExpression(n.arguments[0])) {
        for (const a of n.arguments[0].properties) if (ts.isPropertyAssignment(a) && ts.isIdentifier(a.name) && option(a.name.text, literal(a.initializer))) note(...local.get(n.expression.text), a.name.text, literal(a.initializer))
      }
      ts.forEachChild(n, visit)
    }
    visit(sf)
  }
  return out
}

/** The themes the source project's roles hold values for: light, and dark where its token
 * files redefine them for dark. A piece is built to be right in each. */
export function themesOf(S) {
  const tokenFiles = String(S.R.keys.DESIGN_TOKEN_FILES ?? '').split(/\s+/).filter(Boolean).map((r) => posix(path.join(S.pkgRel, r)))
  return parityProblems(S.R.css.filter(([f]) => tokenFiles.includes(f))).applies ? ['light', 'dark'] : ['light']
}

/** piece.json, as extract writes it. */
export function pieceJson(S, plan, roles) {
  const pack = (f) => (f === plan.reference ? `references/${path.basename(f)}` : f)
  // Where its files and the files it expects sat, and what each package-name import meant:
  // what install needs to land them in another project's layout.
  const asked = usesOf(S, plan)
  const held = [...plan.files, ...plan.atoms.keys()]
  const workspaces = Object.fromEntries(S.R.workspaces.filter((w) => held.some((f) => f.startsWith(`${w}/`))).sort().map((w) => [w, S.packOf(w)]))
  const imports = {}
  for (const f of plan.files.filter(isCode)) {
    const text = S.R.sources.get(f)
    if (text === undefined) continue
    for (const d of importsOf(S.ts, f, text)) {
      if (d.spec.startsWith('.')) continue
      const taken = [...dependenciesOf(S, f).files.keys()]
      const module = resolveModule(S, f, d.spec)
      if (!module) continue
      const [from, to] = [...S.names].find(([n]) => d.spec === n || d.spec.startsWith(`${n}/`)) ?? []
      // A barrel is named by the one file taken through it, when it is one.
      const through = taken.includes(module) || !taken.length ? module : (taken.filter((t) => held.includes(t)).length === 1 ? taken.find((t) => held.includes(t)) : module)
      imports[from ? to + d.spec.slice(from.length) : d.spec] = held.includes(module) ? module : through
    }
  }
  return {
    files: [...(plan.reference ? [plan.reference] : []), ...plan.files].map(pack),
    pieces: plan.pieces,
    carriers: plan.carriers,
    atoms: [...plan.atoms].map(([file, names]) => {
      const uses = Object.fromEntries([...(asked.get(file) ?? [])].sort(([a], [b]) => a.localeCompare(b)).map(([name, props]) => [name, Object.fromEntries([...props].sort(([a], [b]) => a.localeCompare(b)).map(([prop, values]) => [prop, [...values].sort()]))]))
      // A control is a piece of the pack too: install lands it where the project has none.
      return { name: stemOf(file), file, exports: [...names].sort(), ...(S.R.isAtomFile(file) ? { piece: stemOf(file) } : {}), ...(Object.keys(uses).length ? { uses } : {}) }
    }),
    roles,
    packages: Object.fromEntries(plan.packages),
    themes: themesOf(S),
    workspaces,
    imports: Object.fromEntries(Object.entries(imports).sort(([a], [b]) => a.localeCompare(b))),
  }
}

/** What stands between the source project and an extract: uncommitted work, or anything
 * the status check holds. `ignore` is a folder whose files are not the project's work. */
export function preconditions(repo, { ignore = null } = {}) {
  const problems = []
  const dirty = execFileSync('git', ['-C', repo, 'status', '--porcelain'], { encoding: 'utf8' })
    .split('\n')
    .filter((l) => l && !(ignore && l.slice(3).replace(/^"|"$/g, '').startsWith(ignore)))
  if (dirty.length) problems.push(`the tree has ${dirty.length} uncommitted change(s) — a piece is cut from committed work`)
  const status = checkUiStatus(repo)
  if (status.notApplicable) problems.push(status.notApplicable)
  for (const p of status.pending ?? []) problems.push(`pending: ${p}`)
  for (const p of status.problems ?? []) problems.push(`status: ${p}`)
  return problems
}

/** The whole of an extract, nothing written: the plan, piece.json, each file's pack text,
 * and what a person has still to read. */
export async function planExtract(repo, name, { words = [], allow = [], tokensOf = null, system = null, carries = [] } = {}) {
  const S = system ?? readSystem(repo)
  if (S.problems) return { problems: S.problems }
  const plan = workOut(S, name)
  if (!plan.files) return { S, problems: plan.problems }
  const problems = [...plan.problems]
  
  if (!tokensOf) {
    S.tailwind ??= await classTokens(S.repo)
    tokensOf = S.tailwind.tokensOf
    if (!tokensOf) problems.push('no stylesheet imports tailwindcss, so the roles the piece uses cannot be read')
  }
  const roles = tokensOf ? rolesUsed({ files: plan.files, sources: S.R.sources, css: S.R.css, tokensOf, carries }) : []

  const vocabulary = businessWords(S, { extra: words, allow })
  const texts = new Map()
  const rewrite = []
  const named = []
  const strings = []
  for (const f of plan.files) {
    const raw = S.R.sources.get(f) ?? fs.readFileSync(path.join(S.repo, f), 'utf8')
    const text = isCode(f) ? renamePackage(S.ts, f, raw, S.names) : raw
    texts.set(f, text)
    for (const h of wordHits(f, vocabulary)) named.push(`${f}: \`${h.word}\` in its path`)
    if (!isCode(f)) continue
    for (const h of wordHits(text, vocabulary)) {
      if (h.where === 'code') named.push(`${f}:${h.line}: \`${h.word}\` in code`)
      else rewrite.push(`${f}:${h.line}: \`${h.word}\` in a comment`)
    }
    for (const s of readableStrings(S.ts, f, text)) strings.push(`${f}:${s.line}: ${s.text}`)
  }
  if (plan.reference) {
    const at = `references/${path.basename(plan.reference)}`
    const text = packReference(S.refs.get(name).text, plan.kept)
    texts.set(at, text)
    for (const h of wordHits(text, vocabulary, { prose: true })) rewrite.push(`${at}:${h.line}: \`${h.word}\``)
  }
  const inventory = inventoryLines(S, plan)
  for (const h of wordHits(inventory, vocabulary, { prose: true })) rewrite.push(`inventory.md:${h.line}: \`${h.word}\``)

  // Wiring the receiving project writes itself: what the source project's own roots and
  // providers take from the piece.
  const wiring = plan.kept.map((f) => `${f}: carries the rule out in the source project`)
  const travelling = new Set(plan.files)
  for (const [f, src] of S.R.sources) {
    if (travelling.has(f) || f.split('/').includes('features') || !headers(src).content) continue
    const taken = [...dependenciesOf(S, f).files].filter(([t]) => travelling.has(t)).flatMap(([, names]) => [...names])
    if (taken.length) wiring.push(`${f}: ${[...new Set(taken)].sort().join(', ')}`)
  }
  return { S, plan, json: pieceJson(S, plan, roles), texts, inventory, rewrite, named, strings, wiring, vocabulary, problems }
}

/** Write a planned piece to `<out>/<name>/`, replacing what an earlier extract left. */
export function writePiece(dir, x) {
  fs.rmSync(dir, { recursive: true, force: true })
  for (const [rel, text] of x.texts) {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), text)
  }
  fs.writeFileSync(path.join(dir, 'inventory.md'), x.inventory)
  fs.writeFileSync(path.join(dir, 'piece.json'), `${JSON.stringify(x.json, null, 2)}\n`)
}

// ─── proving a piece ─────────────────────────────────────────────────────────

/** A source file as the compiler holds it, comments out: what "the same code" is compared on. */
export function codeOnly(ts, file, text) {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, false, file.endsWith('x') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  return ts.createPrinter({ removeComments: true }).printFile(sf)
}

/**
 * A stand-in for a file the piece expects the project to have, as the two files a compiled
 * module is: `js`, each export it takes with no value, and `dts`, what the source project's
 * own file declares — or, without that, each export typed loosely.
 */
export function stubFor(names, declared = null) {
  const taken = [...names].filter((n) => n !== '*')
  const js = taken.map((n) => (n === 'default' ? 'export default undefined' : `export const ${n} = undefined`))
  const loose = taken.flatMap((n) => (n === 'default' ? ['declare const stub: any', 'export default stub'] : [`export declare const ${n}: any`, `export type ${n} = any`]))
  return { js: `${js.join('\n')}\n`, dts: declared ?? `${loose.join('\n')}\n` }
}

/**
 * What the source project's files declare — their exports by their types, as the compiler
 * writes a declaration file — for `files` and for every file of the UI package their
 * declarations name in turn, so a stand-in's types are whole. A file the compiler cannot
 * declare is left out.
 */
export function declarationsOf(S, files) {
  const { ts } = S
  const out = new Map()
  if (!files.length) return out
  const options = { ...optionsFor(S, files[0]), noEmit: false, declaration: true, emitDeclarationOnly: true, declarationMap: false, composite: false, incremental: false }
  const program = ts.createProgram({ rootNames: files.map((f) => path.join(S.repo, f)), options })
  const queue = [...files]
  const seen = new Set(queue)
  while (queue.length) {
    const f = queue.shift()
    if (f.endsWith('.d.ts')) {
      out.set(f, fs.readFileSync(path.join(S.repo, f), 'utf8'))
      continue
    }
    const sf = program.getSourceFile(path.join(S.repo, f))
    if (!sf) continue
    program.emit(sf, (_name, text) => out.set(f, text), undefined, true)
    for (const d of importsOf(ts, f.replace(/\.tsx?$/, '.d.ts'), out.get(f) ?? '')) {
      const t = resolveModule(S, f, d.spec)
      if (!t || seen.has(t) || !S.inSystem(t) || !/\.tsx?$/.test(t)) continue
      seen.add(t)
      queue.push(t)
    }
  }
  return out
}

/** Every stylesheet the keyed ones import by a relative path, the keyed ones included. */
function stylesheetClosure(S, rels) {
  const out = new Set()
  const queue = [...rels]
  while (queue.length) {
    const f = queue.shift()
    if (out.has(f) || !fs.existsSync(path.join(S.repo, f))) continue
    out.add(f)
    for (const m of fs.readFileSync(path.join(S.repo, f), 'utf8').matchAll(/@import\s+["'](\.[^"']+)["']/g)) queue.push(posix(path.join(path.dirname(f), m[1])))
  }
  return [...out]
}

/**
 * Install pieces into an empty project at `dir` and run the four checks. `pieces` is each
 * piece folder with its piece.json, the piece being proved first. Returns the problems and
 * what each check inspected.
 */
export async function proveInFixture(S, dir, pieces) {
  const { ts } = S
  const problems = []
  const notes = []
  const write = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    fs.writeFileSync(path.join(dir, rel), text)
  }
  const keys = S.R.keys
  // Every design key the source project sets, the ones only the publishing engine reads included.
  const subs = JSON.parse(fs.readFileSync(path.join(S.repo, '.claude/sync-substitutions.json'), 'utf8'))
  const design = Object.fromEntries(Object.entries(subs).filter(([k, v]) => k.startsWith('DESIGN_') && typeof v === 'string'))

  // The pieces' own files.
  const installed = new Set()
  const inventory = []
  const references = []
  for (const p of pieces) {
    for (const f of p.json.files) {
      const text = fs.readFileSync(path.join(p.dir, f), 'utf8')
      if (!f.startsWith('references/')) {
        write(f, text)
        installed.add(f)
        continue
      }
      // A recipe names one reference screen; the fixture gives it one.
      const fm = frontmatter(text) ?? {}
      const screen = posix(path.join(S.pkgRel, fs.existsSync(path.join(S.repo, S.pkgRel, 'src')) ? 'src' : '', 'routes', `${path.basename(f, '.md')}.tsx`))
      if (fm.kind === 'recipe') write(screen, `// ui-recipe: ${path.basename(f)}\nexport {}\n`)
      references.push({ at: `${REFERENCES}/${path.basename(f)}`, text: fm.kind === 'recipe' ? text.replace(/^reference:.*\n/m, '').replace(/^---\n/, `---\nreference: ${screen}\n`) : text })
    }
    inventory.push(fs.readFileSync(path.join(p.dir, 'inventory.md'), 'utf8'))
  }

  // A rule lists the code that is here: a carrier not installed with it is not its code yet.
  for (const r of references) write(r.at, r.text.replace(/^code:\s*(.*)$/m, (_, list) => `code: [${listOf(list).filter((c) => installed.has(c)).join(', ')}]`))

  // What they expect the project to have, as stubs.
  const expected = new Map()
  for (const p of pieces) for (const a of p.json.atoms) if (!installed.has(a.file)) expected.set(a.file, new Set([...(expected.get(a.file) ?? []), ...a.exports]))
  const fromDir = path.join(S.repo, S.pkgRel)
  const link = (name, why) => {
    const to = path.join(dir, 'node_modules', name)
    if (fs.existsSync(to)) return true
    const at = packageDir(name, fromDir)
    if (!at) {
      if (why) problems.push(`${name}: ${why}, and it is not installed in the source project`)
      return false
    }
    fs.mkdirSync(path.dirname(to), { recursive: true })
    fs.symlinkSync(fs.realpathSync(at), to)
    return true
  }
  const types = (name) => link(`@types/${name.replace(/^@/, '').replace('/', '__')}`, null)
  const paths = {}
  // Each stand-in is typed as the source project's own file is, with the types that file
  // names: its libraries linked, and the UI package's files it reaches declared beside it.
  const declared = declarationsOf(S, [...expected.keys()].filter((f) => isCode(f) && fs.existsSync(path.join(S.repo, f))))
  for (const [file, names] of expected) {
    const stub = stubFor(names, declared.get(file))
    write(file.replace(/\.tsx?$/, '.js'), stub.js)
    write(file.replace(/\.tsx?$/, '.d.ts'), stub.dts)
  }
  let standIns = 0
  for (const [at, dts] of declared) {
    if (!installed.has(at) && !expected.has(at)) {
      write(at.replace(/(\.d)?\.tsx?$/, '.d.ts'), dts)
      standIns++
    }
    for (const d of importsOf(ts, at.replace(/(\.d)?\.tsx?$/, '.d.ts'), dts)) {
      const t = resolveModule(S, at, d.spec)
      if (t && S.inSystem(t) && !d.spec.startsWith('.')) paths[d.spec] = [t.replace(/(\.d)?\.tsx?$/, '')]
      else if (!t && !d.spec.startsWith('.')) {
        link(packageOf(d.spec), null)
        types(packageOf(d.spec))
      }
    }
  }
  write(INVENTORY, inventory.join('\n'))

  // Each module specifier that is not a relative path, mapped to the file it named in the
  // source project. A module that is not itself in the fixture — a barrel — is written as
  // the re-export of what was taken through it.
  const shims = new Map()
  const main = pieces[0]
  // Each piece says what its package-name imports meant; a piece written in the pack has no
  // source file to resolve them from, so its record is the only one.
  for (const p of pieces) for (const [spec, file] of Object.entries(p.json.imports ?? {})) paths[spec] = [file.replace(/\.tsx?$/, '')]
  for (const p of pieces) {
    for (const f of p.json.files.filter(isCode)) {
      if (!S.R.sources.has(f)) continue
      for (const d of importsOf(ts, f, fs.readFileSync(path.join(p.dir, f), 'utf8'))) {
        const [real, pack] = [...S.names].find(([, to]) => to && (d.spec === to || d.spec.startsWith(`${to}/`))) ?? []
        const at = resolveModule(S, f, real ? real + d.spec.slice(pack.length) : d.spec)
        if (!at) continue
        const present = installed.has(at) || expected.has(at)
        if (!present && !S.inSystem(at)) continue
        if (!d.spec.startsWith('.')) paths[d.spec] = [at.replace(/\.tsx?$/, '')]
        if (present) continue
        const taken = [...dependenciesOf(S, f).files].filter(([t]) => installed.has(t) || expected.has(t))
        for (const [t, names] of taken) {
          const from = posix(path.relative(path.dirname(at), t)).replace(/\.tsx?$/, '')
          const line = `export { ${[...names].filter((n) => n !== '*').join(', ')} } from '${from.startsWith('.') ? from : `./${from}`}'`
          shims.set(at, new Set([...(shims.get(at) ?? []), line]))
        }
      }
    }
  }
  for (const [at, lines] of shims) write(at, `${[...lines].join('\n')}\n`)

  // The libraries, linked at the versions the pieces ran on, and the stylesheets.
  for (const p of pieces) {
    for (const name of Object.keys(p.json.packages)) {
      link(name, 'a library piece.json names')
      types(name)
    }
  }
  const options = optionsFor(S, main.json.files.find(isCode) ?? posix(path.join(S.pkgRel, 'index.ts')))
  // The ambient types each workspace's tsconfig names: `node`, `vite/client`.
  const named = new Set(pieces.flatMap((p) => p.json.files.filter(isCode).flatMap((f) => optionsFor(S, f).types ?? [])))
  const ambient = [...named].filter((t) => link(`@types/${t}`, null) || link(packageOf(t), null))
  for (const name of ['tailwindcss', '@tailwindcss/node', '@tailwindcss/oxide']) link(name, 'the token check compiles the stylesheet with it')

  const list = (v) => String(v ?? '').split(/\s+/).filter(Boolean)
  const keyed = [...new Set([...list(keys.DESIGN_TOKEN_FILES), keys.DESIGN_TYPE_FILE, keys.DESIGN_STYLES_FILE].filter(Boolean))]
  const sheets = stylesheetClosure(S, keyed.map((r) => posix(path.join(S.pkgRel, r))))
  for (const f of sheets) {
    const text = fs.readFileSync(path.join(S.repo, f), 'utf8')
    write(f, text)
    for (const m of text.matchAll(/@import\s+["']([^."'][^"']*)["']/g)) if (m[1] !== 'tailwindcss') link(packageOf(m[1]), `${f} imports it`)
  }
  const hasEntry = sheets.some((f) => /^\s*@import\s+["']tailwindcss["']/m.test(fs.readFileSync(path.join(S.repo, f), 'utf8')))
  if (!hasEntry) {
    const imports = (keys.DESIGN_STYLES_FILE ? [keys.DESIGN_STYLES_FILE] : keyed).map((r) => `@import "./${r}";`)
    write(posix(path.join(S.pkgRel, 'fixture.css')), `@import "tailwindcss";\n${imports.join('\n')}\n`)
  }

  // The source project's own layout: one package, or the workspaces its UI lives in.
  const workspaces = S.R.workspaces.length ? S.homes : []
  write('package.json', `${JSON.stringify({ name: 'design-pack-fixture', private: true, type: 'module', ...(workspaces.length ? { workspaces } : {}) }, null, 2)}\n`)
  for (const w of workspaces) write(`${w}/package.json`, `${JSON.stringify({ name: S.packOf(w), type: 'module', ...(w === S.pkgRel ? {} : { dependencies: { [S.packOf(S.pkgRel)]: '*' } }) }, null, 2)}\n`)
  write('.gitignore', 'node_modules\ndist\n')
  write('tsconfig.json', `${JSON.stringify({ compilerOptions: { jsx: 'react-jsx', module: 'ESNext', moduleResolution: 'Bundler', target: 'ES2022' }, include: ['.'], exclude: ['node_modules', 'dist'] }, null, 2)}\n`)
  write(
    '.claude/sync-substitutions.json',
    `${JSON.stringify({ ...design, _intentionally_empty: [] }, null, 2)}\n`,
  )
  execFileSync('git', ['init', '-q', dir])

  // The declarations a workspace gives every file in it — its `*.d.ts`, and the types they
  // reference — are the project's environment, not the piece's.
  const ambientFiles = []
  for (const w of new Set(pieces.flatMap((p) => Object.keys(p.json.workspaces ?? {})))) {
    for (const f of fs.globSync(`${w}/**/*.d.ts`, { cwd: S.repo, exclude: (p) => /(^|\/)(node_modules|dist)(\/|$)/.test(posix(p)) }).map(posix)) {
      if (installed.has(f) || fs.existsSync(path.join(dir, f))) continue
      const text = fs.readFileSync(path.join(S.repo, f), 'utf8')
      write(f, text)
      ambientFiles.push(f)
      for (const m of text.matchAll(/\/\/\/\s*<reference\s+types=["']([^"']+)["']/g)) link(packageOf(m[1]), null)
    }
  }

  // 1. It typechecks.
  const codeFiles = [...installed, ...shims.keys()].filter(isCode)
  const program = ts.createProgram({
    rootNames: [...codeFiles, ...ambientFiles].map((f) => path.join(dir, f)),
    options: { ...options, noEmit: true, skipLibCheck: true, baseUrl: dir, paths, rootDir: undefined, outDir: undefined, composite: false, incremental: false, types: ambient, typeRoots: undefined, configFilePath: path.join(dir, 'tsconfig.json') },
  })
  const inFixture = (d) => !d.file || !posix(path.relative(dir, d.file.fileName)).startsWith('..')
  for (const d of ts.getPreEmitDiagnostics(program).filter(inFixture)) {
    const at = d.file ? `${posix(path.relative(dir, d.file.fileName))}:${d.file.getLineAndCharacterOfPosition(d.start ?? 0).line + 1}` : 'tsconfig'
    problems.push(`typecheck: ${at}: ${ts.flattenDiagnosticMessageText(d.messageText, ' ')}`)
  }
  notes.push(`typecheck: ${codeFiles.length} file(s) — ${installed.size} of the piece${pieces.length > 1 ? 's' : ''}, against ${expected.size} stand-in(s) for the project's own files, typed from ${standIns} more of its declarations, and ${shims.size} barrel(s)`)

  // 2. It builds.
  const viteAt = [fromDir, ...S.R.workspaces.map((w) => path.join(S.repo, w)), S.repo].map((d) => packageDir('vite', d)).find(Boolean)
  if (!viteAt) problems.push('build: vite is not installed in the source project, so the piece cannot be built')
  else {
    const built = codeFiles.filter((f) => installed.has(f))
    write('fixture-entry.ts', `${built.map((f, i) => `import * as m${i} from './${f.replace(/\.tsx?$/, '')}'`).join('\n')}\nexport const pieces = [${built.map((_, i) => `m${i}`).join(', ')}]\n`)
    try {
      const pkg = JSON.parse(fs.readFileSync(path.join(viteAt, 'package.json'), 'utf8'))
      const entry = typeof pkg.exports?.['.'] === 'string' ? pkg.exports['.'] : (pkg.exports?.['.']?.import?.default ?? pkg.exports?.['.']?.import ?? pkg.module ?? pkg.main)
      const vite = await import(pathToFileURL(path.join(fs.realpathSync(viteAt), entry)).href)
      await vite.build({
        configFile: false,
        root: dir,
        logLevel: 'silent',
        resolve: { alias: Object.entries(paths).map(([spec, [to]]) => ({ find: spec, replacement: path.join(dir, to) })) },
        build: { outDir: path.join(dir, 'dist'), minify: false, lib: { entry: path.join(dir, 'fixture-entry.ts'), formats: ['es'], fileName: 'piece' } },
      })
      notes.push(`build: ${built.length} file(s) bundled with the source project's vite ${pkg.version}`)
    } catch (err) {
      problems.push(`build: ${String(err.message ?? err).split('\n')[0]}`)
    }
    fs.rmSync(path.join(dir, 'fixture-entry.ts'), { force: true })
  }

  // 3. It passes the token check. The stylesheets are the source project's, whole, so the
  // project stays a valid one; a token only the rest of that project reached is marked as
  // the check asks for a token whose screen is not built.
  // The spacing scale is the source project's own, in its design-system config, which the
  // fixture does not hold: the piece is held to it all the same.
  let spacingSteps = null
  const scaleConfig = path.join(S.repo, S.pkgRel, 'design-system/design-system.config.mjs')
  if (fs.existsSync(scaleConfig)) {
    const { readConfig } = await import(new URL('../../claude-design/scripts/config.mjs', import.meta.url).href)
    spacingSteps = (await readConfig(scaleConfig)).ctx?.CONFIG?.spacing?.steps ?? null
  }
  const UNREACHED = /^(\S+):(\d+) {2}(--[\w-]+) {2}— defined but nothing reaches it/
  const byFile = new Map()
  for (const p of (await checkDesignTokens(dir, { all: true, spacingSteps })).problems) {
    const m = p.match(UNREACHED)
    if (m) byFile.set(m[1], [...(byFile.get(m[1]) ?? []), Number(m[2]) - 1])
  }
  let marked = 0
  for (const [file, at] of byFile) {
    const lines = fs.readFileSync(path.join(dir, file), 'utf8').split('\n')
    for (const n of at) lines[n] = `${lines[n]} /* not-yet-built: this project holds only the piece */`
    fs.writeFileSync(path.join(dir, file), lines.join('\n'))
    marked += at.length
  }
  try {
    const { writeDesignMd } = await import(new URL('../../claude-design/scripts/design-md.mjs', import.meta.url).href)
    await writeDesignMd(dir)
  } catch (err) {
    problems.push(`token check: design.md cannot be generated from the stylesheets — ${String(err.message ?? err).split('\n').join('; ')}`)
  }
  const tokens = await checkDesignTokens(dir, { all: true, spacingSteps })
  for (const p of tokens.problems) problems.push(`token check: ${p}`)
  if (tokens.counts) notes.push(`token check: ${spacingSteps ? 'held to the source project\'s spacing scale; ' : 'the source project declares no spacing scale; '}${tokens.counts.sourceFiles} source file(s) and ${tokens.counts.classesChecked} classes against the source project's stylesheets, ${marked} of its ${tokens.counts.tokens} tokens being ones the piece does not reach`)

  // The roles piece.json names are the ones the installed piece reads.
  let tw = { tokensOf: null }
  let why = 'no stylesheet there imports tailwindcss'
  try {
    tw = await classTokens(dir)
  } catch (err) {
    why = String(err.message ?? err).split('\n')[0]
  }
  if (!tw.tokensOf) problems.push(`roles: they cannot be read back from the installed piece — ${why}`)
  else {
    const fixture = readRepo(dir, { all: true })
    const now = rolesUsed({ files: main.json.files.filter(isCode), sources: fixture.sources, css: fixture.css, tokensOf: tw.tokensOf }).map((r) => r.name)
    const named = main.json.roles.map((r) => r.name)
    for (const r of named) if (!now.includes(r)) problems.push(`roles: piece.json names \`${r}\`, which the installed piece does not read`)
    for (const r of now) if (!named.includes(r)) problems.push(`roles: the installed piece reads \`${r}\`, which piece.json does not name`)
    notes.push(`roles: ${named.length} named, ${now.length} read back from the installed piece`)
  }

  // 4. It passes the status check: everything catalogued and every pointer real.
  const status = checkUiStatus(dir)
  if (status.notApplicable) notes.push(`status check: ${status.notApplicable}`)
  else {
    for (const p of status.problems) problems.push(`status check: ${p}`)
    const c = status.counts
    notes.push(`status check: ${c.components} component(s), ${c.references} reference(s), ${c.screens} screen(s) and ${c.catalogue} catalogue line(s)`)
  }
  return { problems, notes }
}

/** A piece folder read back: its piece.json and where it is. */
function readPiece(dir) {
  const file = path.join(dir, 'piece.json')
  if (!fs.existsSync(file)) return null
  return { dir, name: path.basename(dir), json: JSON.parse(fs.readFileSync(file, 'utf8')) }
}

/** Prove the piece folder `dir`, cut from the project at `repo`. */
export async function prove(repo, dir, { words = [], allow = [], keep = false, tokensOf = null, system = null } = {}) {
  const piece = readPiece(dir)
  if (!piece) return { problems: [`${dir}: no piece.json — extract writes the folder this proves`], notes: [] }
  const x = await planExtract(repo, piece.name, { words, allow, tokensOf, system })
  if (!x.S) return { problems: x.problems, notes: [] }
  const { S } = x
  const notes = []
  // A piece written in the pack — a reference shell, a reference screen — is no piece of the
  // source project: there is nothing to compare it with, and the proof below is the whole of it.
  const authored = !x.plan
  if (authored) {
    notes.push('written in the pack: the source project has no piece of this name to compare it with')
    x.problems = []
    x.texts = new Map()
    x.json = piece.json
    x.vocabulary = businessWords(S, { extra: words, allow })
  }
  const problems = [...x.problems]

  // How far the folder has been adjusted from what extract cut: said, never refused. The
  // checks below are what hold an adjusted piece to its own piece.json.
  const unworded = (json) => JSON.stringify({ ...json, roles: (json.roles ?? []).map((r) => r.name) })
  const adjusted = []
  for (const [rel, text] of x.texts) {
    const at = path.join(dir, rel)
    if (rel.endsWith('.md') || !fs.existsSync(at)) continue
    const now = fs.readFileSync(at, 'utf8')
    if (isCode(rel) ? codeOnly(S.ts, rel, now) !== codeOnly(S.ts, rel, text) : now !== text) adjusted.push(rel)
  }
  for (const f of piece.json.files) if (!fs.existsSync(path.join(dir, f))) problems.push(`${f}: piece.json lists it, and it is not in the piece folder`)
  if (problems.length > x.problems.length) return { problems, notes }
  notes.push(`adjusted from the source project: ${adjusted.length} file(s)${adjusted.length ? ` (${adjusted.join(', ')})` : ''}${unworded(piece.json) !== unworded(x.json) ? ', and piece.json' : ''}`)

  // What still reads as the source project's own business: advice, never a refusal.
  const named = []
  let read = 0
  const all = fs.globSync('**/*', { cwd: dir }).map(posix).filter((f) => fs.statSync(path.join(dir, f)).isFile())
  for (const f of all) {
    read++
    for (const h of wordHits(fs.readFileSync(path.join(dir, f), 'utf8'), x.vocabulary, { prose: !isCode(f) })) named.push(`${f}:${h.line}: \`${h.word}\``)
  }
  notes.push(`domain words: ${named.length} place(s) in ${read} file(s) still use a word this project names its own business with — a piece reads best in words any project would use`)

  // Installed with every piece it depends on.
  const pieces = [piece]
  for (let i = 0; i < pieces.length; i++) {
    for (const dep of pieces[i].json.pieces) {
      if (pieces.some((p) => p.name === dep)) continue
      const d = readPiece(path.join(path.dirname(dir), dep))
      if (!d) problems.push(`it depends on the piece \`${dep}\`, which is not extracted beside it (${path.join(path.dirname(dir), dep)}) — extract that first`)
      else pieces.push(d)
    }
  }
  if (pieces.length !== 1 + new Set(pieces.slice(1).map((p) => p.name)).size || problems.some((p) => p.startsWith('it depends on'))) return { problems, notes }

  const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'design-pack-'))
  try {
    const result = await proveInFixture(S, fixture, pieces)
    problems.push(...result.problems)
    notes.push(...result.notes)
  } finally {
    if (keep) notes.push(`the fixture is kept at ${fixture}`)
    else fs.rmSync(fixture, { recursive: true, force: true })
  }
  return { problems, notes }
}

/**
 * How much of what a folder of pieces draws its reference pages show. A reference page is
 * a pack file a user lands on — one headed `// ui-recipe:` — and a component is shown when
 * a page reaches it through its imports. It says which components no page reaches, never
 * which variant or state of a reached one is drawn.
 */
export function coverage(dir) {
  const files = new Map()
  const owner = new Map()
  const named = new Map()
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const at = path.join(dir, e.name, 'piece.json')
    if (!e.isDirectory() || !fs.existsSync(at)) continue
    const json = JSON.parse(fs.readFileSync(at, 'utf8'))
    for (const f of (json.files ?? []).filter(isCode)) {
      if (!fs.existsSync(path.join(dir, e.name, f))) continue
      files.set(f, fs.readFileSync(path.join(dir, e.name, f), 'utf8'))
      owner.set(f, e.name)
    }
    for (const [spec, file] of Object.entries(json.imports ?? {})) named.set(spec, file)
  }
  const target = (from, spec) => {
    if (named.has(spec)) return named.get(spec)
    if (!spec.startsWith('.')) return null
    const base = posix(path.join(path.dirname(from), spec))
    return [`${base}.tsx`, `${base}.ts`, `${base}/index.ts`, base].find((c) => files.has(c)) ?? null
  }
  const pages = [...files].filter(([, text]) => headers(text).recipe).map(([f]) => f)
  const reached = new Set(pages)
  const queue = [...pages]
  while (queue.length) {
    const f = queue.pop()
    for (const m of (files.get(f) ?? '').matchAll(/from\s+['"]([^'"]+)['"]/g)) {
      const t = target(f, m[1])
      if (t && files.has(t) && !reached.has(t)) {
        reached.add(t)
        queue.push(t)
      }
    }
  }
  const components = [...files.keys()].filter((f) => isComponent(f)).sort()
  const unreached = components.filter((f) => !reached.has(f)).map((f) => ({ piece: owner.get(f), file: f }))
  return { pieces: new Set(owner.values()).size, pages: pages.sort(), components: components.length, unreached }
}

/** Where a folder of pieces records each piece's proof: its name and the fingerprint proved. */
export const PROOFS = 'proved.json'

/** The hash of every file in one piece's folder, or 'missing' when the folder holds no piece. */
function ownHash(folder, name, seen) {
  if (seen.has(name)) return seen.get(name)
  const dir = path.join(folder, name)
  let out = 'missing'
  if (fs.existsSync(path.join(dir, 'piece.json'))) {
    const hash = createHash('sha256')
    const files = fs.globSync('**/*', { cwd: dir }).map(posix).filter((f) => fs.statSync(path.join(dir, f)).isFile()).sort()
    for (const f of files) hash.update(`${f}\0`).update(fs.readFileSync(path.join(dir, f))).update('\0')
    out = hash.digest('hex')
  }
  seen.set(name, out)
  return out
}

/**
 * A piece's fingerprint: its own files, and those of every piece it depends on, directly or
 * through another — a piece is proved together with those, so a change to one is a change
 * to it. Pieces that depend on each other each get a stable fingerprint.
 */
export function pieceFingerprint(folder, name, seen = new Map()) {
  const reached = new Set()
  const walk = (n) => {
    if (reached.has(n)) return
    reached.add(n)
    const at = path.join(folder, n, 'piece.json')
    if (fs.existsSync(at)) for (const dep of JSON.parse(fs.readFileSync(at, 'utf8')).pieces ?? []) walk(dep)
  }
  walk(name)
  const hash = createHash('sha256')
  for (const n of [...reached].sort()) hash.update(`${n}=${ownHash(folder, n, seen)}\0`)
  return hash.digest('hex')
}

/** Every piece under a folder, and the ones whose recorded proof is not of what they are now. */
export function provedState(folder) {
  const names = fs.existsSync(folder) ? fs.readdirSync(folder, { withFileTypes: true }).filter((e) => e.isDirectory() && fs.existsSync(path.join(folder, e.name, 'piece.json'))).map((e) => e.name).sort() : []
  const at = path.join(folder, PROOFS)
  const proved = fs.existsSync(at) ? JSON.parse(fs.readFileSync(at, 'utf8')) : {}
  const seen = new Map()
  return { names, stale: names.filter((n) => proved[n] !== pieceFingerprint(folder, n, seen)) }
}

/** Record that the piece proves as it stands, dropping the record of any piece no longer there. */
export function recordProof(folder, name) {
  const at = path.join(folder, PROOFS)
  const proved = fs.existsSync(at) ? JSON.parse(fs.readFileSync(at, 'utf8')) : {}
  proved[name] = pieceFingerprint(folder, name)
  const kept = Object.fromEntries(Object.entries(proved).filter(([n]) => fs.existsSync(path.join(folder, n, 'piece.json'))).sort(([a], [b]) => a.localeCompare(b)))
  fs.writeFileSync(at, `${JSON.stringify(kept, null, 2)}\n`)
}

// ─── the command line ────────────────────────────────────────────────────────

function parseArgs(argv) {
  const out = { _: [], swap: [], app: [] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '--out' || a === '--repo' || a === '--answers' || a === '--from' || a === '--pack') out[a.slice(2)] = argv[++i]
    else if (a === '--swap') out.swap.push(argv[++i] ?? '')
    else if (a === '--app') out.app.push(argv[++i] ?? '')
    else if (a === '--keep') out.keep = true
    else if (a === '--all') out.all = true
    else if (a === '--check') out.check = true
    else if (a === '--apply') out.apply = true
    else out._.push(a)
  }
  return out
}

function fail(problems, notes = []) {
  for (const n of notes) console.log(`  · ${n}`)
  console.error(`\n✗ design pack: ${problems.length} problem(s)\n`)
  for (const p of problems) console.error(`    ${p}`)
  process.exit(1)
}

/** Whether `--from` names a repository's address rather than a folder on this machine. */
export const isRepositoryAddress = (from) => /^[a-z][a-z0-9+.-]*:\/\//i.test(from) || /^[^/\s]+@[^/\s]+:/.test(from)

/**
 * The packs checkout to install from: the folder named, or a fresh clone of the repository
 * named — the published packs when none is.
 */
export function packsCheckout(from) {
  if (from && !isRepositoryAddress(from)) return path.resolve(from)
  const address = from || PACKS_REPOSITORY
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'design-packs-'))
  try {
    execFileSync('git', ['clone', '--quiet', address, dir], { stdio: ['ignore', 'ignore', 'pipe'], encoding: 'utf8' })
  } catch (e) {
    fail([`could not clone the packs repository ${address}: ${String(e.stderr || e.message).trim().split('\n').pop()}`])
  }
  return dir
}

/** `install` and `compare`: the receiving project's side. */
async function receive(repo, mode, target, args) {
  const { applyInstall, approveInstalled, blockers, carriedHere, compare, compliance, installedFiles, planInstall, roleWork } = await import('./install.mjs')
  if (mode === 'approve') {
    const done = approveInstalled(repo)
    if (done.problems.length) fail(done.problems)
    console.log(`✓ design pack: ${done.installed} installed file(s) read; ${done.files.length} still pending are approved, with ${done.lines} inventory line(s)`)
    console.log(`  · the judge's ledger: ${done.cleared} item(s) resting on those files are cleared; ${done.kept} are left — this project's own, and any about a role, which is answered on its own line`)
    return
  }
  if (mode === 'compare') {
    const { files, problems, read } = compare(repo, packsCheckout(args.from), target ?? null)
    const changed = files.filter((f) => f.diff)
    for (const f of changed) console.log(`\n── ${f.file} — ${f.piece}/${f.packFile}, installed at ${f.version}, now ${f.now}\n${f.diff}`)
    console.log(`\n${problems.length ? '✗' : '✓'} design pack: ${read} installed file(s) read, ${files.length} compared with the pack; ${changed.length} changed there since it was installed`)
    if (problems.length) fail(problems)
    return
  }
  if (!target) {
    console.error('usage: design-pack.mjs install <piece or app pack> --app <workspace>… [--from <packs repository or checkout>] [--swap <listed piece>=<other piece>]… [--answers <file>] [--apply]')
    process.exit(2)
  }
  // A piece lands only on finished layers: nothing is planned on a project the checks fault.
  const ready = await compliance(repo)
  if (ready.problems.length) {
    for (const n of ready.notes) console.log(`  · ${n}`)
    console.error(`\n✗ design pack: this project is not ready to take a piece — ${ready.problems.length} place(s) the token check, read with the vendored atoms, or the status check names. Finish them first; nothing was planned or copied.\n`)
    for (const p of ready.problems) console.error(`    ${p}`)
    process.exit(1)
  }
  for (const n of ready.notes) console.log(`  · ready: ${n}`)
  const answersFile = path.resolve(repo, args.answers ?? ANSWERS)
  const config = fs.existsSync(answersFile) ? JSON.parse(fs.readFileSync(answersFile, 'utf8')) : {}
  const swap = Object.fromEntries(args.swap.map((s) => s.split('=')))
  const from = packsCheckout(args.from)
  const plan = planInstall(repo, from, target, { swap, apps: args.app, map: { standIn: config.standIn ?? {}, beside: config.beside ?? {} } })
  if (!plan.pieces?.length) fail(plan.problems)
  // Which lacking roles still show in the installed files, by this project's own build.
  if (plan.project && installedFiles(repo).length) {
    try {
      const { classCompilers } = await import('../../design-system/scripts/compare-ui-values.mjs')
      const tw = await classCompilers(plan.project.repo)
      if (tw.entries.length) roleWork(plan, (file, cls) => tw.declarationsOf(file, cls).size > 0)
    } catch (err) {
      console.log(`  · the roles still to fit could not be read from this project's build: ${String(err.message ?? err).split('\n')[0]}`)
    }
  }
  const lacking = plan.roles.filter((r) => !r.present)
  const libraries = plan.packages.filter((l) => !l.installed)
  console.log(`design pack: ${target} at ${plan.version} — ${plan.pieces.length} piece(s), in the order they install: ${plan.pieces.map((p) => p.name).join(', ')}`)
  console.log(`  · ${plan.files.length} file(s) land pending, and ${plan.references.length} recipe(s) and behaviour rule(s) land approved, governing ${plan.apps.length ? plan.apps.join(', ') : 'NO APP NAMED'}`)
  const already = plan.files.filter((f) => f.installed).length
  for (const f of plan.files) {
    const answer = plan.beside.find((b) => b.file === f.file && b.dest === b.existing)?.answer
    console.log(`      ${f.dest}${f.installed ? `  (installed at ${f.installed}: left as it is)` : f.exists ? (answer === 'replace' ? '  (replaces what is there)' : '  (a file is there: waits on an answer)') : ''}`)
  }
  console.log(`  · ${plan.expected.length} file(s) of this project's own stand in for what the pieces expect`)
  for (const e of plan.expected) {
    console.log(`      ${e.name} (${e.exports.join(', ')}) → ${e.found ?? 'NOT FOUND'}${e.missing.length ? ` — lacks ${e.missing.join(', ')}: fit it, or the files that import it, after the copy` : ''}`)
    if (e.unseen.length) console.log(`          the pieces pass it what its file does not mention: ${e.unseen.join('; ')}`)
  }
  if (plan.themes.missing.length) console.log(`  · THEMES: the pieces are built for ${plan.themes.pack.join(' and ')}, and this project's token files hold no ${plan.themes.missing.join(' or ')} values — it needs that theme, and every role the pieces use needs a value in it, before the pieces are right`)
  console.log(`  · ${plan.roles.length} role(s) used, ${lacking.length} this project does not have by that name`)
  for (const r of lacking) console.log(`      ${r.name} — ${r.purpose || '(no purpose written)'}${r.value ? ` — the pack carries ${r.value}: ${r.why}` : ''}${r.classes.length ? ` [${r.classes.join(' ')}]` : ''}${r.still.length ? ` — still in ${r.still.length} installed file(s): ${r.still.join(', ')}` : ''}`)
  const differs = carriedHere(plan)
  if (differs.length) {
    console.log(`  · ${differs.length} role(s) the pack carries that this project already has at another value — the human decides how each lands; an install never changes this project's value:`)
    for (const d of differs) console.log(`      ${d.name} — the pack ${d.pack}, this project ${d.here}: ${d.why}`)
  }
  const utilities = plan.roles.filter((r) => !r.name.startsWith('--') && !r.name.startsWith('type-')).map((r) => r.name)
  if (utilities.length) console.log(`  · ${utilities.length} named utilit${utilities.length === 1 ? 'y' : 'ies'} used: ${utilities.join(', ')} — one that starts as one of Tailwind's own classes does (border-frame) is registered with this project's class-merge helper, or that helper drops it beside a class of the same start`)
  console.log(`  · ${plan.packages.length} librar${plan.packages.length === 1 ? 'y' : 'ies'} used, ${libraries.length} not installed here`)
  for (const l of libraries) console.log(`      ${l.name}@${l.version} — for ${l.into.join(', ')}`)
  if (plan.unexported.length) {
    console.log(`  · ${plan.unexported.length} landed component(s) no package path reaches — add one to the package's \`exports\` when an app imports it`)
    for (const f of plan.unexported) console.log(`      ${f}`)
  }
  console.log(`  · ${plan.guides.length} guide(s) say what this project writes itself`)
  for (const g of plan.guides) console.log(`      ${g.piece}: ${g.file}`)
  const waiting = blockers(plan)
  if (waiting.length) {
    console.error(`\n✗ design pack: nothing is copied while ${waiting.length} thing(s) wait on an answer\n`)
    for (const w of waiting) console.error(`    ${w}`)
    process.exit(1)
  }
  if (!args.apply) {
    console.log(already === plan.files.length ? `\n✓ design pack: installed — all ${already} file(s) are here; what is listed above is what is left to fit` : `\n✓ design pack: nothing stands in the way — run it again with --apply to copy ${plan.files.length - already} file(s)${already ? `; ${already} already installed are left as they are` : ''}`)
    return
  }
  const { written } = applyInstall(repo, plan)
  console.log(`\n✓ design pack: ${written.length} file(s) written, every piece pending`)
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  // The repository root, from this script's own place: .claude/skills/design-packs/scripts/.
  const repo = path.resolve(args.repo ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..'))
  const [mode, target] = args._
  const opts = {}
  if (mode === 'install' || mode === 'compare' || mode === 'approve') return receive(repo, mode, target, args)
  if (mode === 'roles' && target) {
    // Every role the pieces in a folder read, with the source project's value: what the
    // human reads to say which are part of what the pack is.
    const css = readSystem(repo).R.css
    const values = valuesOf(css)
    const purposes = purposesOf(css)
    const read = new Map()
    const dirs = fs.readdirSync(path.resolve(target), { withFileTypes: true }).filter((e) => e.isDirectory() && fs.existsSync(path.join(path.resolve(target), e.name, 'piece.json')))
    for (const d of dirs) for (const r of JSON.parse(fs.readFileSync(path.join(path.resolve(target), d.name, 'piece.json'), 'utf8')).roles ?? []) read.set(r.name, (read.get(r.name) ?? 0) + 1)
    if (!dirs.length) fail([`${target}: no piece folders — nothing to read roles from`])
    for (const [name, n] of [...read].sort(([a], [b]) => a.localeCompare(b))) console.log(`${name}  ${values.get(name) ?? '(no value found)'}  — ${purposes.get(name) || '(no purpose written)'}  [${n} piece(s)]`)
    console.log(`\n✓ design pack: ${read.size} role(s) read by ${dirs.length} piece(s), each with the source project's value`)
    return
  }
  if (mode === 'prove-all' && target) {
    // Every piece folder under one folder. A piece is proved once: its proof is recorded
    // with the fingerprint of what it was proved as, and it is proved again only when it
    // or a piece it depends on has changed.
    const folder = path.resolve(target)
    const state = provedState(folder)
    if (!state.names.length) fail([`${target}: no piece folders — nothing to prove`])
    const due = args.all ? state.names : state.stale
    if (args.check) {
      console.log(`design pack: ${state.names.length - state.stale.length} of ${state.names.length} piece(s) are proved as they stand`)
      if (state.stale.length) fail([`${state.stale.length} piece(s) changed since their proof, or were never proved: ${state.stale.join(', ')} — prove them (prove-all)`])
      return
    }
    const system = due.length ? readSystem(repo) : null
    const failed = []
    for (const name of due) {
      const { problems } = await prove(repo, path.join(folder, name), { system })
      if (!problems.length) {
        console.log(`✓ ${name}`)
        recordProof(folder, name)
        continue
      }
      failed.push(name)
      console.log(`✗ ${name}`)
      for (const p of problems.slice(0, 6)) console.log(`    ${p}`)
      if (problems.length > 6) console.log(`    … and ${problems.length - 6} more`)
    }
    const kept = state.names.length - due.length
    console.log(`\n${failed.length ? '✗' : '✓'} design pack: ${due.length - failed.length} piece(s) proved now, ${kept} unchanged since their proof, of ${state.names.length}${failed.length ? `; failing: ${failed.join(', ')}` : ''}`)
    if (failed.length) process.exit(1)
    return
  }
  if (mode === 'coverage' && target) {
    const c = coverage(path.resolve(target))
    if (!c.pieces) fail([`${target}: no piece folders — nothing to measure`])
    console.log(`design pack: ${c.pages.length} reference page(s) in ${c.pieces} piece(s): ${c.pages.join(', ') || 'none'}`)
    console.log(`  · ${c.components - c.unreached.length} of ${c.components} component(s) are reached by a reference page`)
    if (c.unreached.length) {
      console.log(`  · ${c.unreached.length} are on no reference page — show each on one, or leave it to the first real screen that uses it:`)
      const by = new Map()
      for (const u of c.unreached) by.set(u.piece, [...(by.get(u.piece) ?? []), path.basename(u.file).replace(/\.tsx$/, '')])
      for (const [piece, list] of [...by].sort(([a], [b]) => a.localeCompare(b))) console.log(`      ${piece}: ${list.join(', ')}`)
    }
    console.log('  · a reached component is not shown in every variant and state: that is read on the page itself')
    return
  }
  if (args.pack) {
    const file = path.resolve(args.pack)
    if (!fs.existsSync(file)) fail([`${args.pack}: no such app pack file`])
    const carries = JSON.parse(fs.readFileSync(file, 'utf8')).carries
    const wrong = carriesProblems(carries)
    if (wrong.length) fail(wrong.map((w) => `${args.pack}: ${w}`))
    opts.carries = carries ?? []
  }
  if (!['extract', 'prove'].includes(mode) || !target) {
    console.error('usage: design-pack.mjs extract <piece> [--out <dir>] [--pack <app pack file>]\n       design-pack.mjs prove <piece folder> [--keep]\n       design-pack.mjs prove-all <folder of pieces> [--all | --check]\n       design-pack.mjs roles <folder of pieces>\n       design-pack.mjs coverage <folder of pieces>')
    process.exit(2)
  }
  const out = path.resolve(repo, mode === 'extract' ? (args.out ?? DEFAULT_OUT) : path.dirname(path.resolve(target)))
  const inside = posix(path.relative(fs.realpathSync(repo), fs.existsSync(out) ? fs.realpathSync(out) : out))
  // A piece is cut from committed work. Proving a folder reads the project and changes
  // nothing, so it runs on the project as it stands.
  const before = mode === 'extract' ? preconditions(repo, { ignore: inside.startsWith('..') ? null : `${inside}/` }) : []
  if (before.length) fail(before)

  if (mode === 'prove') {
    const { problems, notes } = await prove(repo, path.resolve(target), { ...opts, keep: args.keep })
    if (problems.length) fail(problems, notes)
    for (const n of notes) console.log(`  · ${n}`)
    console.log(`\n✓ design pack: ${path.basename(path.resolve(target))} is the source project's code, names no project, and typechecks, builds and passes the token and status checks installed in an empty project`)
    return
  }

  const x = await planExtract(repo, target, opts)
  if (x.problems.length) fail(x.problems)
  const dir = path.join(out, target)
  writePiece(dir, x)
  const j = x.json
  console.log(`✓ design pack: ${target} (${x.plan.kind}) written to ${dir}`)
  console.log(`  · ${j.files.length} file(s) travel: ${j.files.join(', ')}`)
  console.log(`  · depends on ${j.pieces.length} piece(s)${j.pieces.length ? `: ${j.pieces.join(', ')}` : ''}`)
  console.log(`  · expects ${j.atoms.length} file(s) of the project's own${j.atoms.length ? `: ${j.atoms.map((a) => `${a.name} (${a.exports.join(', ')})`).join('; ')}` : ''}`)
  console.log(`  · uses ${j.roles.length} role(s) and ${Object.keys(j.packages).length} librar${Object.keys(j.packages).length === 1 ? 'y' : 'ies'}: ${Object.entries(j.packages).map(([n, v]) => `${n}@${v}`).join(', ')}`)
  console.log(`  · read against ${x.vocabulary.length} word(s) that name this project`)
  const section = (title, lines) => {
    if (!lines.length) return
    console.log(`\n${title} (${lines.length}):`)
    for (const l of lines) console.log(`    ${l}`)
  }
  section('Reword in the piece folder — a comment or prose in the source project\'s own domain words; a piece is found and reused by words any project would use', x.rewrite)
  section('Named for the domain in code — nothing to do here; a generic name in the source project makes the piece easier to recognise', x.named)
  section('Read each — text a person sees; a sample value or a label naming a customer is fixed in the source project', x.strings)
  section('Wiring the source project does with the piece — what the guide tells a receiving project to write', x.wiring)
}

// Not awaited at the top level: install.mjs imports this module back, and a module still
// awaiting its own main would never finish loading for it.
if (import.meta.main) {
  main().catch((err) => {
    console.error(err)
    process.exit(1)
  })
}
