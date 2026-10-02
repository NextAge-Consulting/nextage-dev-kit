#!/usr/bin/env node
/* Builds a Claude Design "Design System" artifact's files from a project's UI
 * package — the code is the source, the artifact a published view of it.
 *
 *   node .claude/skills/claude-design/scripts/build.mjs <path/to/design-system.config.mjs> [--release <n>]
 *
 * The project's paths come from .claude/sync-substitutions.json, its content from
 * the config (references/config-example.mjs) — config.mjs reads both. `--release`
 * is the number /ui-design publish-system gives this publish; the system's README,
 * its cover and its index carry "Release <n> · built <date> from <sha>".
 *
 * Writes the generated safelist and class-merge files into the UI package
 * (generate.mjs), then <package>/<out>/project/ — tokens.json, README.md, the
 * cover, fonts, asset-group READMEs, and the components: bundle.js
 * (window.<namespace> on the design page's React 18), bundle.css, index.d.ts,
 * React 18 in components/lib, and a preview and README per component — plus
 * <out>/index-fields.json, the keys of the artifact's index this build owns.
 * Publishing is a separate, interactive step (/ui-design publish-system):
 * headless runs have no Artifact tool.
 *
 * Fails with a non-zero exit, naming each offender, when a piece of the UI stack
 * is missing, no colour token is read, a token has no usage comment, a value
 * cannot be translated, a token fits no family, a promised class is not shipped,
 * or a component has no guidelines — never a silent drop. */

import { execSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import { checkPrerequisites, iconsSpecifier, loadConfig, packageRequire } from './config.mjs'
import { writeGenerated } from './generate.mjs'
import { buildModel, promisedClasses, readText } from './model.mjs'

const args = process.argv.slice(2)
const releaseAt = args.indexOf('--release')
const RELEASE = releaseAt >= 0 ? Number(args[releaseAt + 1]) : null
if (releaseAt >= 0 && !(Number.isInteger(RELEASE) && RELEASE > 0)) {
  console.error('usage: build.mjs <path/to/design-system.config.mjs> [--release <n>]')
  process.exit(2)
}
const ctx = await loadConfig(args.find((a, i) => releaseAt < 0 || (i !== releaseAt && i !== releaseAt + 1)), { tool: 'build.mjs' })
const { CONFIG, CONFIG_DIR, REPO, PKG } = ctx
const OUT = path.join(PKG, CONFIG.out)
const PROJECT = path.join(OUT, 'project')
const NS = CONFIG.namespace

const missing = checkPrerequisites(ctx)
if (missing.length) {
  console.error(`design-system build: the UI stack is incomplete — nothing written.\n`)
  for (const p of missing) console.error(`  ✗ ${p}`)
  process.exit(1)
}
const esbuild = await import(pathToFileURL(packageRequire(PKG).resolve('esbuild')).href)

// The sync is dated in the project's own zone: UTC would date an evening sync
// in the Americas as tomorrow. Required — there is no safe default zone.
let SYNC_DATE
try {
  SYNC_DATE = new Intl.DateTimeFormat('en-CA', { timeZone: CONFIG.timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
} catch {
  SYNC_DATE = null
}
if (!SYNC_DATE) {
  console.error(`design-system build: \`timeZone\` must be the project's IANA zone (e.g. 'America/Chicago') — got ${JSON.stringify(CONFIG.timeZone)}`)
  process.exit(2)
}

// React 18 for the design page's previews, carried as files the way the Design
// System type's own worked example does. Pinned, and checked against the hashes
// of the type's copies, so a changed CDN file fails the build instead of shipping.
const PAGE_REACT_VERSION = '18.3.1'
const PAGE_REACT = [
  {
    name: 'react',
    global: 'React',
    file: 'components/lib/react.production.min.js',
    url: `https://cdn.jsdelivr.net/npm/react@${PAGE_REACT_VERSION}/umd/react.production.min.js`,
    sha256: 'd949f1c3687aedadcedac85261865f29b17cd273997e7f6b2bfc53b2f9d4c4dd',
  },
  {
    name: 'react-dom',
    global: 'ReactDOM',
    file: 'components/lib/react-dom.production.min.js',
    url: `https://cdn.jsdelivr.net/npm/react-dom@${PAGE_REACT_VERSION}/umd/react-dom.production.min.js`,
    sha256: '35f4f974f4b2bcd44da73963347f8952e341f83909e4498227d4e26b98f66f0d',
  },
]

/* Components written for React 19 receive `ref` as an ordinary prop. Design
 * pages and canvases run React 18, which strips it — so a Radix trigger rendered
 * through a component (`asChild`) loses its anchor and the overlay never opens.
 * REF_AS_PROP restores React 19's behaviour on 18, for this bundle only: a plain
 * function component is rendered through a cached forwardRef wrapper that hands
 * any ref back in as a prop. Used by the JSX runtime shim (the
 * bundle's own JSX) and by the footer (components the page mounts by name). */
const REF_AS_PROP = `function refAsProp(R, cache, t) {
  var w = cache.get(t);
  if (!w) {
    w = R.forwardRef(function (props, ref) { return t(Object.assign({}, props, { ref: ref })); });
    w.displayName = t.displayName || t.name;
    cache.set(t, w);
  }
  return w;
}
function isPlainComponent(t) {
  return typeof t === 'function' && !(t.prototype && t.prototype.isReactComponent) && t.$$typeof === undefined;
}
function soleChild(R, props) {
  var c = props && props.children;
  if (Array.isArray(c) && c.length === 1) { c = c[0]; props = Object.assign({}, props, { children: c }); }
  // In the canvas editor every x-import sits in a display:contents host div, which
  // has no box: a trigger slotted onto it measures 0,0 and the overlay lands in the
  // corner. Give that host a box the size of what it wraps.
  if (props && props.asChild && R.isValidElement(c) && c.type === 'div' && /(^|\\s)sc-host-x(\\s|$)/.test(c.props.className || '')) {
    props = Object.assign({}, props, { children: R.cloneElement(c, { style: Object.assign({}, c.props.style, { display: 'inline-flex' }) }) });
  }
  return props;
}`

// ─── the system, read from the UI package's CSS ─────────────────────────────
const model = buildModel(ctx)
const { problems, notCarried, colorTokens, radius, shadow, spacing, groups, fonts } = model

// ─── components: guidelines, from their single source ──────────────────────
const docSources = CONFIG.docSources
const inventory = docSources.inventory ? readRepo(docSources.inventory) : ''
const designDoc = docSources.design ? readRepo(docSources.design) : ''
const COMPONENTS = CONFIG.components
if (!COMPONENTS.length) problems.push('components: none listed — a design system with no component previews has nothing for a design to mount')
const componentDocs = new Map()
for (const c of COMPONENTS) {
  const text = componentDoc(c)
  if (!text) problems.push(`${c.name}: no guidelines found for doc ${JSON.stringify(c.doc)}`)
  componentDocs.set(c.name, text)
}

if (problems.length) {
  console.error(`design-system build: ${problems.length} problem(s) — nothing written.\n`)
  for (const p of problems) console.error(`  ✗ ${p}`)
  process.exit(1)
}

// ─── write ─────────────────────────────────────────────────────────────────
const ref = gitRef()
// What the system's page shows of where it came from: the release the publish
// step numbers (`--release`), the day it was built and the commit it was built
// from. Each design's README records the same line for the system it uses.
const STAMP = `${RELEASE ? `Release ${RELEASE} · built` : 'Built'} ${SYNC_DATE} from ${ref}`
const generated = writeGenerated(ctx, model)
const tokens = {
  name: CONFIG.title,
  version: 1,
  meta: {
    source: 'repo',
    package: CONFIG.package,
    ref,
    paths: {
      tokens: [...CONFIG.tokens, ...(CONFIG.typeRoles ? [CONFIG.typeRoles.file] : [])].map((r) => path.posix.join(CONFIG.package, r)),
      docs: CONFIG.readme.source ? [CONFIG.readme.source] : [],
    },
    synced: SYNC_DATE,
  },
  color: {
    themes: [
      { id: 'light', name: 'Light' },
      { id: 'dark', name: 'Dark' },
    ],
    tokens: colorTokens,
  },
  type: {
    fonts: fonts.map((f) => f.entry),
    families: Object.fromEntries(Object.entries(CONFIG.typeFamilies).map(([k, token]) => [k, model.lightEnv.get(token)])),
    groups,
  },
  spacing: { tokens: spacing },
  radius: { tokens: radius },
  shadow: { tokens: shadow },
}

fs.rmSync(OUT, { recursive: true, force: true })
fs.mkdirSync(path.join(PROJECT, 'fonts'), { recursive: true })
fs.writeFileSync(path.join(PROJECT, 'tokens.json'), `${JSON.stringify(tokens, null, 2)}\n`)
for (const f of fonts) fs.copyFileSync(f.src, path.join(PROJECT, f.entry.file))
if (CONFIG.cover) {
  // The cover carries the stamp where it marks `<!-- ds-stamp -->`; a cover without
  // the mark would show no version, so it fails.
  const cover = readText(path.join(CONFIG_DIR, CONFIG.cover))
  if (!cover.includes('<!-- ds-stamp -->')) {
    console.error(`design-system build: ${CONFIG.cover} has no <!-- ds-stamp --> mark — put it where the cover shows the system's release and build`)
    process.exit(1)
  }
  fs.mkdirSync(path.join(PROJECT, 'components/Cover'), { recursive: true })
  fs.writeFileSync(path.join(PROJECT, 'components/Cover/preview.html'), cover.replaceAll('<!-- ds-stamp -->', STAMP))
}
// Asset-group READMEs are text files; the images they describe are uploads the
// publish step names in the index.
if (CONFIG.assets) fs.cpSync(path.join(CONFIG_DIR, CONFIG.assets), path.join(PROJECT, 'assets'), { recursive: true })
fs.writeFileSync(path.join(PROJECT, 'README.md'), readme())
await buildComponents()

fs.writeFileSync(
  path.join(OUT, 'index-fields.json'),
  `${JSON.stringify(
    {
      title: CONFIG.title,
      namespace: NS,
      libraries: PAGE_REACT.map(({ name, global, file }) => ({ name, version: PAGE_REACT_VERSION, global, file })),
      lastChange: { by: 'Claude', via: `Claude Code · ${CONFIG.package}@${ref}`, note: `${STAMP}.` },
    },
    null,
    2,
  )}\n`,
)

const styleCount = groups.reduce((n, g) => n + g.styles.length, 0)
console.log(
  `design-system build: ${colorTokens.length} colours, ${styleCount} type roles, ${spacing.length} spacing, ${radius.length} radii, ${shadow.length} shadow, ${fonts.length} font, ${COMPONENTS.length} components → ${path.relative(REPO, OUT)} · ${STAMP}`,
)
if (generated.length) console.log(`design-system build: rewrote ${generated.map((g) => `${CONFIG.package}/${g}`).join(', ')} — commit them with the token change`)

// ─── helpers ───────────────────────────────────────────────────────────────
async function buildComponents() {
  const dir = path.join(PROJECT, 'components')

  // components/lib: the page's React, fetched and hash-checked.
  fs.mkdirSync(path.join(dir, 'lib'), { recursive: true })
  for (const lib of PAGE_REACT) {
    const res = await fetch(lib.url)
    if (!res.ok) throw new Error(`could not fetch ${lib.url}: HTTP ${res.status}`)
    const bytes = Buffer.from(await res.arrayBuffer())
    const got = createHash('sha256').update(bytes).digest('hex')
    if (got !== lib.sha256) throw new Error(`${lib.url} changed: sha256 ${got}, expected ${lib.sha256}`)
    fs.writeFileSync(path.join(PROJECT, lib.file), bytes)
  }

  // bundle.css: the package's own CSS build, with the theme classes moved to the
  // page's attribute and @font-face removed (fonts come from tokens.json). A
  // prefers-color-scheme rule passes through, so a design follows the OS unless
  // it sets data-theme.
  run(CONFIG.css.build, 'css.build')
  let css = readText(path.join(PKG, CONFIG.css.file))
  css = css.replace(/@font-face\s*\{[^}]*\}/g, '')
  for (const [theme, cls] of [['dark', CONFIG.css.darkClass], ['light', CONFIG.css.lightClass]]) {
    const escaped = cls.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    css = css.replace(new RegExp(`(^|[\\s,{}(])${escaped}(?=[\\s,{:)])`, 'g'), `$1[data-theme="${theme}"]`)
  }
  if (/<\/style/i.test(css)) throw new Error('bundle.css contains "</style" — it would end the inline element')

  // The README promises designs this class vocabulary. The package's CSS build
  // only emits classes its own source uses, and a class a design uses that the
  // stylesheet lacks styles nothing and reports nothing — so a promised class
  // that is not shipped fails the build, naming each one.
  const promised = promisedClasses(model, CONFIG)
  // A class's selector escapes the dot in a half step (`.p-0\\.5`); a match must
  // end where the selector does, so `gap-2` is not found inside `gap-20`.
  const shipped = (cls) => {
    const sel = `.${cls.replace(/\./g, '\\.')}`
    for (let i = css.indexOf(sel); i !== -1; i = css.indexOf(sel, i + 1)) {
      const next = css[i + sel.length]
      if (next === undefined || /[\s{:,.>[)]/.test(next)) return true
    }
    return false
  }
  const unshipped = promised.filter((cls) => !shipped(cls))
  if (unshipped.length) {
    console.error(`design-system build: ${unshipped.length} class(es) the README promises are not in ${CONFIG.css.file} — the feed stylesheet imports ${CONFIG.generated.safelist}, which lists every one:\n  ${unshipped.join(' ')}`)
    process.exit(1)
  }
  fs.writeFileSync(path.join(dir, 'bundle.css'), css)

  // bundle.js: one classic script assigning window.<namespace>, reading React
  // from the page. The entry is generated: the feed barrel, plus the icon set.
  const entry = path.join(OUT, 'entry.mjs')
  const icons = iconsSpecifier(CONFIG.icons, CONFIG_DIR)
  fs.writeFileSync(
    entry,
    `export * from ${JSON.stringify(path.join(PKG, CONFIG.feed))}\n${
      icons
        ? `import * as React from 'react'\nimport { icons } from ${JSON.stringify(icons)}\nexport { icons }\nexport function Icon({ name, ...props }) {\n  const Glyph = icons[name]\n  if (!Glyph) throw new Error('Unknown icon "' + name + '"')\n  return React.createElement(Glyph, props)\n}\n`
        : ''
    }`,
  )
  const result = await esbuild.build({
    entryPoints: [entry],
    bundle: true,
    format: 'iife',
    globalName: NS,
    platform: 'browser',
    target: 'es2020',
    minify: true,
    write: false,
    jsx: 'automatic',
    tsconfig: path.join(PKG, CONFIG.tsconfig),
    define: { 'process.env.NODE_ENV': '"production"' },
    // An image a component imports travels inside the bundle: a design copies the
    // system's files but cannot load a picture by path, so a component pointing at
    // the app's public folder would render a broken image there.
    loader: { '.png': 'dataurl', '.jpg': 'dataurl', '.jpeg': 'dataurl', '.gif': 'dataurl', '.webp': 'dataurl', '.svg': 'dataurl' },
    plugins: [pageReact()],
    logLevel: 'silent',
    // Components the page mounts by name (a preview, a canvas x-import, Radix
    // cloning a trigger) get the same ref-as-prop wrapper as the bundle's own
    // JSX, and JSX's children semantics: a canvas passes an x-import's children
    // as an array even when there is one, and a Radix `asChild` trigger refuses
    // an array — so a one-element array is handed over as the element itself.
    footer: {
      js: `${REF_AS_PROP}
${NS} = (function (ns) {
  var R = window.React, out = {};
  for (var k in ns) {
    var v = ns[k];
    if (!/^[A-Z]/.test(k)) { out[k] = v; continue; }
    if (isPlainComponent(v)) {
      out[k] = (function (inner) {
        var w = R.forwardRef(function (props, ref) { return inner(Object.assign({}, soleChild(R, props), { ref: ref })); });
        w.displayName = inner.displayName || inner.name;
        return w;
      })(v);
    } else if (v && v.$$typeof) {
      out[k] = (function (inner) {
        var w = R.forwardRef(function (props, ref) { return R.createElement(inner, Object.assign({}, soleChild(R, props), { ref: ref })); });
        w.displayName = inner.displayName;
        return w;
      })(v);
    } else out[k] = v;
  }
  return out;
})(${NS});`,
    },
  })
  fs.rmSync(entry)
  const header = `/* @ds-bundle: ${JSON.stringify({ format: 4, namespace: NS, components: COMPONENTS.map((c) => ({ name: c.name })) })} */`
  const js = result.outputFiles[0].text
  if (/<\/script|<!--/i.test(js)) throw new Error('bundle.js contains "</script" or "<!--" — the page inlines it')
  fs.writeFileSync(path.join(dir, 'bundle.js'), `${header}\n${js}`)

  // index.d.ts: the package's own declarations, concatenated — documentation only.
  if (CONFIG.types) {
    run(CONFIG.types.build, 'types.build')
    const decls = []
    const feedDir = path.dirname(CONFIG.feed)
    const srcRoot = path.join(PKG, feedDir)
    for (const mod of readText(path.join(PKG, CONFIG.feed)).matchAll(/from ["']\.\/([\w/.-]+)["']/g)) {
      const rel = mod[1].replace(/\.(tsx?|jsx?)$/, '')
      const file = path.join(PKG, CONFIG.types.dir, path.relative(srcRoot, path.join(srcRoot, rel)) + '.d.ts')
      if (!fs.existsSync(file)) throw new Error(`no declarations emitted for ${rel}`)
      decls.push(`// ─── ${rel} ───\n${readText(file).replace(/^import .*$/gm, '').trim()}`)
    }
    if (icons) {
      decls.push(`// ─── icons ───\n/** Any icon from ${path.isAbsolute(icons) ? path.relative(REPO, icons).split(path.sep).join('/') : icons} by name: <Icon name="Search" />. */\nexport declare function Icon(props: { name: string; className?: string }): JSX.Element;\n/** The whole icon set, for an \`icon\` prop: icon={${NS}.icons.Search}. */\nexport declare const icons: Record<string, unknown>;`)
    }
    fs.writeFileSync(path.join(dir, 'index.d.ts'), `${decls.join('\n\n')}\n`)
  }

  // one preview and one README per component
  for (const c of COMPONENTS) {
    const cdir = path.join(dir, c.name)
    fs.mkdirSync(cdir, { recursive: true })
    const width = c.width ? ` width=${c.width}` : ''
    // The script is the preview code the project's own config declares for this
    // component — written by the repository's authors, never outside input.
    fs.writeFileSync(
      path.join(cdir, 'preview.html'), // nosemgrep: javascript.lang.security.audit.unknown-value-with-script-tag.unknown-value-with-script-tag
      `<!-- @dsCard group="${c.group}" height=${c.height}${width} -->
<!doctype html>
<html>
<head><meta charset="utf-8"><title>${c.name} — preview</title>
<style>${CONFIG.previewStyle ?? 'body{margin:0;padding:16px}'}</style>
</head>
<body>
<div id="root"></div>
<script>
  var U = window.${NS}, h = React.createElement;
  function icon(name) { return U.icons[name]; }
  var noop = function () {};
  function stateful(initial, render) {
    return h(function Preview() { var s = React.useState(initial); return render(s[0], s[1]); });
  }
  ReactDOM.createRoot(document.getElementById('root')).render(${c.render.replace(/\n\s*/g, ' ')});
</script>
</body>
</html>
`,
    )
    fs.writeFileSync(path.join(cdir, 'README.md'), `# ${c.name}\n\n${componentDocs.get(c.name)}\n`)
  }
}

/** Resolve react, react-dom and the JSX runtime to the page's globals. */
function pageReact() {
  const shims = {
    react: 'module.exports = window.React',
    'react-dom': 'module.exports = window.ReactDOM',
    'react-dom/client': 'module.exports = window.ReactDOM',
    'react/jsx-runtime': `var R = window.React, cache = new WeakMap(); ${REF_AS_PROP}
function j(t, p, k) {
  // Every plain component, not only one created with a ref: Radix's \`asChild\` adds the
  // ref later, by cloning the element, and a clone of a plain component drops it on 18.
  if (isPlainComponent(t)) t = refAsProp(R, cache, t);
  return R.createElement(t, k === undefined ? p : Object.assign({}, p, { key: k }));
}
module.exports = { jsx: j, jsxs: j, Fragment: R.Fragment };`,
  }
  return {
    name: 'page-react',
    setup(b) {
      b.onResolve({ filter: /^(react|react-dom|react-dom\/client|react\/jsx-runtime)$/ }, (a) => ({ path: a.path, namespace: 'page-react' }))
      b.onLoad({ filter: /.*/, namespace: 'page-react' }, (a) => ({ contents: shims[a.path], loader: 'js' }))
    },
  }
}

/** A component's guidelines from its one source; empty when that source has none.
 *   { inventory: "Name" } → that `| \`Name\` |` row of the UI inventory
 *   { design: "Heading" } → that `###` section of the design doc
 *   { source: "path" }    → the doc comment above the component in <package>/<sourceRoot>/<path>,
 *                            else that file's leading doc comment */
function componentDoc(c) {
  if (c.doc?.inventory) {
    const row = inventory
      .split('\n')
      .find((l) => l.startsWith(`| \`${c.doc.inventory}\``) || l.startsWith(`| \`${c.doc.inventory}\` /`))
    return row ? row.split('|')[2].trim() : ''
  }
  if (c.doc?.design) {
    const start = designDoc.indexOf(`\n### ${c.doc.design}\n`)
    if (start < 0) return ''
    const next = designDoc.slice(start + 1).search(/\n#{2,3} /)
    return designDoc.slice(start + 1, next < 0 ? undefined : start + 1 + next).replace(/^### .*\n/, '').trim()
  }
  if (c.doc?.source) {
    const src = readText(path.join(PKG, docSources.sourceRoot ?? 'src', c.doc.source))
    const at = functionAt(src, c.name)
    const m =
      (at >= 0 ? /\/\*\*((?:(?!\*\/)[\s\S])*)\*\/\s*(?:export\s+)?$/.exec(src.slice(0, at)) : null) ??
      /^(?:import[^\n]*\n|\s*\n)*\/\*\*((?:(?!\*\/)[\s\S])*)\*\//.exec(src)
    return m ? m[1].replace(/^\s*\* ?/gm, '').trim() : ''
  }
  return ''
}

/** Where `function <name>` is declared in a source file, by plain string search;
 * -1 when it is not. */
function functionAt(src, name) {
  const needle = `function ${name}`
  for (let i = src.indexOf(needle); i >= 0; i = src.indexOf(needle, i + 1)) {
    if (!/[\w$]/.test(src[i + needle.length] ?? '')) return i
  }
  return -1
}

/** Run one of the config's build commands in the UI package; on failure, stop
 * with the command's own output. */
function run(cmd, key) {
  try {
    execSync(cmd, { cwd: PKG, stdio: 'pipe' })
  } catch (e) {
    const out = `${e.stdout ?? ''}${e.stderr ?? ''}`.trim().split('\n').slice(-30).join('\n    ')
    console.error(`design-system build: ${key} failed — ${cmd} (in ${CONFIG.package})\n    ${out}`)
    process.exit(1)
  }
}

function readRepo(rel) {
  return readText(path.join(REPO, rel))
}

function gitRef() {
  let sha
  try {
    sha = execSync('git rev-parse --short HEAD', { cwd: REPO, stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()
  } catch {
    return 'no commit yet'
  }
  const watched = [CONFIG.package, ...(CONFIG.readme.source ? [CONFIG.readme.source] : [])].join(' ')
  const dirty = execSync(`git status --porcelain -- ${watched}`, { cwd: REPO }).toString().trim()
  return dirty ? `${sha}+uncommitted` : sha
}

function readme() {
  const cfg = CONFIG.readme
  let sections = []
  if (cfg.source) {
    const doc = readRepo(cfg.source)
    const body = doc.slice(Math.max(0, doc.indexOf('\n# ')))
    sections = (cfg.sections ?? []).map((title) => {
      const start = body.indexOf(`\n## ${title}\n`)
      if (start < 0) throw new Error(`${cfg.source} has no "## ${title}" section`)
      const next = body.indexOf('\n## ', start + 1)
      return body.slice(start + 1, next < 0 ? undefined : next).trim()
    })
  }
  const vocab = cfg.vocabulary?.length
    ? ['## Writing it in code', '', ...(cfg.vocabularyIntro ? [cfg.vocabularyIntro, ''] : []), '| What | Class |', '|---|---|', ...cfg.vocabulary.map(([what, cls]) => `| ${what} | ${cls} |`)].join('\n')
    : ''
  const notPreviewed = Object.entries(CONFIG.notPreviewed ?? {}).map(([n, why]) => `\`${n}\` is in the bundle but has no preview: ${why}.`)
  const all = [...notCarried, ...notPreviewed]
  const notes = all.length ? `\n\n## Not carried by the format\n\n${all.map((n) => `- ${n}`).join('\n')}` : ''
  return `# ${CONFIG.title}\n\n${CONFIG.tagline ?? ''}\n\n${STAMP}, from the repository's UI package (\`${CONFIG.package}\`). The code is the source: change a token there and re-sync, never here.\n\n${vocab}${vocab ? '\n\n' : ''}${sections.join('\n\n')}${notes}\n`
}
