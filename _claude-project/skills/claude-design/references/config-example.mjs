/* A project's Claude Design system config — every key the engine reads, with its
 * default. Copy it to <UI package>/design-system/design-system.config.mjs, fill in
 * the content, delete what you leave at the default, and replace this header with
 * one line pointing here:
 *
 *   // The design system's content for the claude-design engine — every key: .claude/skills/claude-design/references/config-example.mjs
 *
 * The engine (scripts/config.mjs) fails by name on a key it does not read and on
 * a required key left out. The project's PATHS are not here: the UI package is the
 * folder this file sits in, and the feed barrel, token, type and styles files are
 * DESIGN_FEED_BARREL, DESIGN_TOKEN_FILES, DESIGN_TYPE_FILE and DESIGN_STYLES_FILE in
 * .claude/sync-substitutions.json.
 *
 * Paths below: `cover`, `assets` and a relative `icons` are from this file's folder;
 * `tsconfig`, `css.file`, `types.dir`, `out`, `generated.*` and
 * `docSources.sourceRoot` are from the UI package; `readme.source` and
 * `docSources.inventory` / `design` are from the repository root.
 *
 * Each component's guidelines come from ONE source, never restated here:
 *   { inventory: "Name" } → the `| \`Name\` | … |` row of the UI inventory
 *   { design: "Heading" } → that `###` section of the design doc
 *   { source: "path" }    → the doc comment above the component in <sourceRoot>/<path>,
 *                            else that file's leading doc comment
 *
 * `render` is the body of a preview script, returning one element. It is given:
 *   U            window.<namespace> — the bundle
 *   h            React.createElement
 *   icon(name)   the icon set's glyph by name, for an `icon` prop
 *   noop         a function that does nothing, for a required handler
 *   stateful(initial, (value, set) => element)
 *                a component holding one piece of state, for a control a person
 *                types into or picks from (the Select below)
 * A preview whose point is an open overlay sets `cardMode: 'overlay'`, so the
 * render check verifies the overlay opens and sits beside its trigger (the
 * Popover below). */

const components = [
  {
    name: 'Button',
    group: 'Actions', // required: the card group on the system's page
    height: 96, // required: the card's height in px
    doc: { design: 'Buttons' }, // required: where its guidelines come from
    render: `h('div', { className: 'flex gap-2' }, h(U.Button, { onClick: noop }, 'Save'), h(U.Button, { variant: 'outline' }, 'Cancel'))`,
  },
  {
    name: 'Select',
    group: 'Fields',
    height: 120,
    doc: { inventory: 'Select' },
    render: `stateful('open', function (value, set) {
      return h(U.Select, { value: value, onValueChange: set, options: [{ value: 'open', label: 'Open' }, { value: 'closed', label: 'Closed' }] })
    })`,
  },
  {
    name: 'Popover',
    group: 'Overlays',
    height: 220,
    cardMode: 'overlay', // optional: the preview shows an open overlay
    doc: { inventory: 'Popover' },
    render: `h(U.Popover, { defaultOpen: true },
      h(U.PopoverTrigger, { asChild: true }, h(U.Button, { variant: 'outline' }, 'Filters')),
      h(U.PopoverContent, null, 'Status, owner and date.'))`,
  },
  {
    name: 'DataTable',
    group: 'Content',
    height: 320,
    width: 900, // optional: the card's width in px, for a component wider than the default card
    doc: { source: 'components/data-table.tsx' },
    render: `h(U.DataTable, { rowKey: 'id', rows: [{ id: 1, name: 'First' }], columns: [{ key: 'name', label: 'Name' }] })`,
  },
]

export default {
  // ─── required ───
  title: 'Acme', // the system's name in Claude Design
  namespace: 'Acme', // the bundle's global: window.Acme
  artifact: '', // the Design System's claude.ai address; /ui-design publish-system fills it on first publish
  timeZone: 'America/New_York', // the project's IANA zone; the build dates each release in it
  spacing: { steps: [0, 1, 2, 3, 4, 6, 8, 12, 16], base: 4 }, // the spacing steps the system promises; base defaults to 4 (px per step)
  css: {
    build: 'npm run build:css', // builds the feed stylesheet, run in the UI package
    file: 'dist/feed.css', // what that build writes
    darkClass: '.dark', // default: the class that forces the dark theme
    lightClass: '.light', // default: the class that forces the light theme
  },
  components,

  // ─── optional ───
  tagline: 'One sentence in the system’s own voice.',
  icons: 'lucide-react', // a package exporting `icons`, or a local module beside this file ('./icons.ts'); omit for none
  previewStyle: 'body{margin:0;padding:16px;background:var(--background);color:var(--foreground)}', // default: body{margin:0;padding:16px}
  requiredProps: { DataTable: ['rowKey'] }, // props a design must give a component on every use — check-design --config fails a page without one
  notPreviewed: { AppShell: 'the whole application frame; a design composes its own screen inside it' }, // in the bundle with no card, and why
  cover: 'cover.html', // the system's cover, a preview document; it shows the release where it says <!-- ds-stamp -->
  assets: 'assets', // asset-group READMEs (images are uploaded at publish)
  readme: {
    source: 'design.md', // default
    sections: ['Overview', 'Colors', 'Typography'], // the design doc's `##` sections the system's README carries
    vocabularyIntro: 'Output that uses these classes drops into the app with no restyling.',
    vocabulary: [
      ['A colour token', '`bg-<token>`, `text-<token>`, `border-<token>`'],
      ['A component', '`window.Acme.<Name>` — the real component the app ships'],
    ],
  },

  // ─── defaults: set one only to change it ───
  // typeRoles: { utilityPrefix: 'type-' }, // the prefix of the `@utility` blocks in DESIGN_TYPE_FILE
  // typeFamilies: { sans: 'font-sans', mono: 'font-mono' }, // family → the token holding its stack
  // families: { radius: /^radius-/, shadow: /^shadow-/, skip: /^$/ }, // RegExp literals matching token names; `skip` names the tokens the type roles and spacing aliases consume
  // themeSelectors: { light: [':root'], dark: ['.dark'] }, // only when the token files use neither the common forms nor `@variant dark`
  // types: { build: 'npx tsc -p design-system/tsconfig.types.json', dir: 'dist/design-system-types/<feed folder>' }, // the type emit; the kit ships that tsconfig
  // tsconfig: 'tsconfig.json', // what esbuild reads for the bundle
  // docSources: { inventory: '.claude/rules/project/ui-inventory.md', design: 'design.md', sourceRoot: 'src' },
  // generated: { safelist: 'design-system/safelist.generated.css', classMerge: 'src/lib/design-tokens.generated.ts' }, // what generate.mjs writes
  // out: 'dist/design-system', // where the build writes the system
}
