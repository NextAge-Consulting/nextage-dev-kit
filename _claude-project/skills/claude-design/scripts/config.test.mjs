import { test } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { iconsSpecifier, readDesignSubstitutions, validateConfig, withDefaults } from './config.mjs'
import { classMergeTs, safelistCss, TYPE_ROLE_GROUP } from './generate.mjs'

const minimal = () => ({
  title: 'Acme',
  namespace: 'Acme',
  artifact: '',
  timeZone: 'America/Chicago',
  spacing: { steps: [0, 1] },
  css: { build: 'npm run build:css', file: 'dist/feed.css' },
  components: [{ name: 'Button', group: 'Actions', height: 80, doc: { inventory: 'Button' }, render: "h(U.Button, null, 'Save')" }],
})

test('a minimal config is valid', () => {
  assert.deepEqual(validateConfig(minimal()), [])
})

test('an unknown key fails by name, at any depth, and a moved key says where it lives', () => {
  const c = { ...minimal(), colour: 'x', css: { ...minimal().css, darkSelector: '.dark' }, feed: 'src/index.ts' }
  const problems = validateConfig(c)
  assert.equal(problems.length, 3)
  assert.match(problems.join('\n'), /^colour: not a config key/m)
  assert.match(problems.join('\n'), /^css\.darkSelector: not a config key/m)
  assert.match(problems.join('\n'), /^feed: .*DESIGN_FEED_BARREL/m)
})

test('a missing required key fails by name, a component key too', () => {
  const c = minimal()
  delete c.timeZone
  delete c.components[0].render
  c.components[0].cardMode = 'drawer'
  const problems = validateConfig(c)
  assert.deepEqual(problems, [
    'timeZone: required, and missing',
    'components[Button].render: required, and missing',
    "components[Button].cardMode: the only mode is 'overlay'",
  ])
})

test('defaults fill the boilerplate; the substitutions fill the paths', () => {
  const c = withDefaults(minimal(), {
    DESIGN_UI_PACKAGE: 'packages/ui',
    DESIGN_FEED_BARREL: 'src/index.ts',
    DESIGN_TOKEN_FILES: ['src/tokens.css'],
    DESIGN_TYPE_FILE: 'src/type.css',
    DESIGN_STYLES_FILE: '',
  })
  assert.equal(c.package, 'packages/ui')
  assert.deepEqual(c.typeRoles, { file: 'src/type.css', utilityPrefix: 'type-' })
  assert.equal(c.styles, undefined)
  assert.deepEqual(c.typeFamilies, { sans: 'font-sans', mono: 'font-mono' })
  assert.equal(c.spacing.base, 4)
  assert.equal(c.css.darkClass, '.dark')
  assert.deepEqual(c.types, { build: 'npx tsc -p design-system/tsconfig.types.json', dir: 'dist/design-system-types/src' })
  assert.equal(c.out, 'dist/design-system')
  assert.equal(c.readme.source, 'design.md')
  assert.equal(c.generated.classMerge, 'src/lib/design-tokens.generated.ts')
})

test('substitutions: a missing key and an empty required key fail by name; an empty optional one is off', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'design-subs-'))
  fs.mkdirSync(path.join(dir, '.claude'))
  fs.writeFileSync(path.join(dir, '.claude/sync-substitutions.json'), JSON.stringify({ DESIGN_UI_PACKAGE: 'packages/ui', DESIGN_FEED_BARREL: '', DESIGN_TOKEN_FILES: 'a.css b.css', DESIGN_STYLES_FILE: '' }))
  const { values, problems } = readDesignSubstitutions(dir)
  assert.deepEqual(problems, [
    'DESIGN_FEED_BARREL: empty in .claude/sync-substitutions.json, and the engine needs it',
    'DESIGN_TYPE_FILE: not set in .claude/sync-substitutions.json',
  ])
  assert.deepEqual(values.DESIGN_TOKEN_FILES, ['a.css', 'b.css'])
})

test('icons: a package name stays, a relative path resolves against the config folder', () => {
  assert.equal(iconsSpecifier('lucide-react', '/repo/ui/design-system'), 'lucide-react')
  assert.equal(iconsSpecifier('./icons.ts', '/repo/ui/design-system'), path.resolve('/repo/ui/design-system/icons.ts'))
  assert.equal(iconsSpecifier(undefined, '/x'), null)
})

const model = {
  families: { radius: /^radius-/, shadow: /^shadow-/ },
  colorTokens: [{ name: 'primary' }, { name: 'border' }],
  radius: [{ name: 'radius-panel' }],
  shadow: [],
  spacingAliases: ['control'],
  weights: ['body', 'strong'],
  groups: [{ styles: [{ name: 'body' }, { name: 'row-title' }] }],
  typePrefix: 'type-',
}

test('the safelist lists every promised family, a lone item without braces', () => {
  const css = safelistCss(model, { spacing: { steps: [0, 0.5, 1] } })
  const lines = css.split('\n').filter((l) => l.startsWith('@source'))
  assert.deepEqual(lines, [
    '@source inline("{p,px,py,pt,pr,pb,pl,m,mx,my,mt,mr,mb,ml,gap,gap-x,gap-y}-{0,0.5,1}");',
    '@source inline("{bg,text,border}-{primary,border}");',
    '@source inline("rounded-panel");',
    '@source inline("type-{body,row-title}");',
  ])
  assert.match(css, /do not edit/)
})

test('the class-merge registration names each role per group and skips an empty family', () => {
  const ts = classMergeTs(model)
  assert.match(ts, /const RADII = \["panel"\]/)
  assert.match(ts, /"rounded-tl": \[\{ "rounded-tl": RADII \}\]/)
  assert.match(ts, /'font-weight': \[\{ font: WEIGHTS \}\]/)
  assert.match(ts, /"size": \[\{ "size": SPACING \}\]/)
  assert.match(ts, new RegExp(`"${TYPE_ROLE_GROUP}": \\[\\{ "type": TYPE_ROLES \\}\\]`))
  assert.doesNotMatch(ts, /shadow: \[/)
  assert.match(ts, /export type DesignClassGroupId = "design-type-role"/)
})

test('references/config-example.mjs is a valid config', async () => {
  const example = (await import('../references/config-example.mjs')).default
  assert.deepEqual(validateConfig(example), [])
})

test('a families pattern given as a string fails by name; a RegExp literal passes', () => {
  assert.deepEqual(validateConfig({ ...minimal(), families: { skip: /^step-/ } }), [])
  assert.deepEqual(validateConfig({ ...minimal(), families: { skip: '^step-' } }), ['families.skip: must be a RegExp literal such as /^radius-/, not a string: "^step-"'])
})
