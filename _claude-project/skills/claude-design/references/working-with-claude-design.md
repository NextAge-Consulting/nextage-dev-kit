# Working with Claude Design

What a design is, how it is driven and shared, what the engine does with the design
system, and how review rounds and co-design run. The human's view of the same ground is
the kit's `project-documentation/designer-handbook.md`.

## What a design is: an interactive prototype

**A design is one interactive prototype, not mockups laid side by side on a canvas.**
Each screen is its own page (the canvas's Page dropdown); in Play the pages link together
like the application. Add screens all at once or one at a time.

Each page is one fluid, responsive web page, never a frame per device size. The Design
type's own guide defaults to fixed-size artboards side by side on one canvas, so a design
built without the skill's "Building a design" rules comes out that way even when the brief
asks for pages.

## Where Claude Design lives

Claude Design is an Artifact type: a design is a "Design" artifact, a design system a
"Design System" artifact. Everything in this skill works in artifacts alone; nothing uses
the standalone claude.ai/design app or its design-system store.

A design is shared from its Share menu: by link, or by email invite with view, comment or
edit access, people outside your organization included. A viewer with the link can click
through the prototype without signing in; anything the prototype saves needs a signed-in
viewer. Every invitee needs a Claude account, on any plan including free.

**Viewers open a design in Chrome.** In Firefox the design's shell loads — page list,
frame titles, Play — but every frame renders blank white. Say so whenever a design's link
is handed to someone to share, and name it first when a viewer reports blank frames.

## Driving a design

A design is driven from Claude Code or from its chat in claude.ai. Each side sees the
other's changes; nothing is handed over between them — each reads the design as it stands
and builds on it.

- **From Claude Code — anyone with edit access.** The session that creates a design is
  attached to it. A later session picks the design up with `/ui-design work`, which
  reads its link from the design's folder and watches it (`ArtifactComments`
  `action: "watch"`), attaching the session to it. `/artifacts`
  does not list a design shared from another organization; the link always works. A change it publishes
  shows on an open canvas at once.
- **From claude.ai.** The design's Chat button opens a chat that reads the canvas and
  revises it, using the system the design has installed; there is no design-system
  picker there and none is needed. Once the creating session has ended, that chat starts
  without its history.
- **An editor in another organization drives it from Claude Code.** Their browser chat
  treats a design shared from another organization as read-only despite edit access, and
  makes a copy in their own account instead.
- **Nothing shared from another organization appears in its recipient's lists** —
  Shared with you, `/artifacts`, the design-system picker, a `list` from Claude Code. They
  name the design's link in the prompt, and the design system's link when starting a
  design of their own.
- **A Claude Code session is never told of a change made elsewhere.** A new version
  starts no turn and sends no notification, so read the design before every edit — every
  `/ui-design` action does.

## The design system: code is the source, the tool a published view

The design system is edited in one place — the project's UI package — and published to
Claude Design with `/ui-design publish-system`. It is never edited in the tool: a change
made only on the canvas is lost at the next publish, and a change made only in code is
invisible to the next design. A new pattern a design invents moves into the UI package
first, then reaches the tool on the next publish. One Design System artifact per repo,
its address the committed `artifact` field of the config.

**A design carries its own copy of the system.** Attaching a system installs its tokens
and components into the design, so a design shared with someone brings the system with
it. The copy never updates by itself: `/ui-design apply-system` brings a design onto the
current version, and every `/ui-design` action that opens a design warns when its copy is
behind.

**What the engine handles, so a project does not have to:**

- **Token translation.** The format reads literals and references only, each family as a
  list of `{name, value, usage}`. The engine resolves `color-mix()` (exactly, as the
  browser does), `transparent`, numeric knobs and theme blocks, and fails the build on
  anything it cannot translate — the format itself would drop it silently, and a colour
  missing from the dark theme inherits the light one.
- **Usage notes.** A token's usage is the comment directly above its declaration, or
  trailing it on the same line; a blank line between comment and token breaks the link,
  and a comment containing `─` (`/* ─── name ─── */`) is a group header belonging to no
  token.
- **The bundle.** The feed barrel and the icon set, built into one script that assigns
  `window.<namespace>`; `<namespace>.Icon` draws any icon by name. The stylesheet is the
  package's CSS with the dark class rewritten to `[data-theme="dark"]`.
- **Images.** A design cannot load a picture by path, so an image a component imports
  is inlined in the bundle and the component renders in a design as it does in the app.
- **Dark mode.** The stylesheet keeps the system's `prefers-color-scheme` rule, so a
  design is dark on a dark device, overlays included; `data-theme="dark"` or `"light"` on
  the root forces one.
- **React 18.** Design pages and canvases run React 18 whatever the app runs. The bundle
  passes `ref` to function components as React 19 does, carries React 18.3.1 itself
  (hash-checked) so previews run live, and hands a canvas's list-shaped children over as
  JSX would, so Radix `asChild` triggers work. What a component must avoid is the
  design-system skill's rule.
- **The canvas editor's host element.** Every mounted component sits in a
  `display: contents` wrapper; the bundle gives it a box under a trigger, so overlays
  anchor to their trigger instead of the corner.
- **Verification.** The render check mounts every preview in light, dark and canvas mode
  and fails on errors, empty renders, overlays that do not open or open detached, and a
  preview whose canvas render differs from its plain render by a single pixel — a
  component whose look leans on its neighbours or its position, which a design's
  wrappers take away. Animations are frozen for the comparison. A popup trigger a preview
  shows closed is clicked open with a real pointer, and fails when nothing opens.
- **Provenance.** Each publish is numbered — the system's README, its cover and its index
  show "Release 12 · built 2026-10-01 from 3f2a1c9", dated in the config's `timeZone`,
  the commit flagged when the working tree was uncommitted — and each design's README
  records the release it uses in the same form. Claude Design's own version ids are
  opaque; the release number is the one a person can compare.
- **The tooling's view of the roles.** The build generates the feed stylesheet's
  safelist and the class-merge registration from the token files, and the token check
  fails while either is stale.

**What stays the project's:** the token rules in the design-system skill, its design keys
in `.claude/sync-substitutions.json` (where the package, tokens and source are), and the
config: which components are previewed, what each preview shows, where each one's
guidelines come from.

**The system page writes its "Consuming this system" section, component cards and
`tokens.css` only when a person edits something on the page.** A design installs a
system's components only when that section exists — so a newly published system gets one
edit on its page before designs use it.

## Review rounds

Reviewers comment on the shared design; `/ui-design feedback` pulls the comments down,
shapes them into items, settles each with the owner, revises, republishes and reports
what changed.

A comment is never deleted, only resolved, and a thread stays on the design through every
later version. Resolving is what ends it: each round reads only open threads. The command
resolves only a thread a writer has sent to Claude; every other thread a round dealt with
is resolved by a person in the design view, or the next round reads it again.

## Co-design

Two people who both design share the design with edit access and each drive their own
turns; the design's copy of the system travels with it, so nothing is exported. A
collaborator in another organization drives it from Claude Code by its link ("Driving a
design", above).

## Tweaks

A tweak is a `data-props` entry on an artboard's `<script data-dc-script>`, shown as a
control in the canvas's Tweaks panel and read as `this.props.<name>`.

- **Every gap in the design system is a tweak, under one master switch.** A design with
  any open gap carries a `Design system` section holding a `boolean` `systemOnly`, and one
  `enum` per gap. One class per chosen option goes on the document root
  (`document.documentElement`, set in `componentDidMount` and `componentDidUpdate`, as the
  Theme tweak sets `data-theme`) — none at all while Design system only is on — and each
  gap's rules in the PREVIEW block are keyed `html.<class> …`. The document root, not the
  page's own, because overlays such as a select's list render outside the page. So one
  flip shows the system exactly as it stands, every override off, and nothing about a gap
  renders without its tweak.
- **A gap's options carry their state, because the person's choice is also their
  approval.** For each option X: `Undecided — X` (shown, not yet approved) and
  `Approved — X` (shown, approved); then `System as is` (rejected — the person does not
  want the addition). Undecided and Approved render the same; only the approval differs.
  The default is `Undecided — <the option you recommend>`. `check-design.mjs` reads the
  states from the saved defaults and reports them; an option without one of these
  prefixes fails it.
- **Tell the person the moment you create a gap** — in the same reply as the change that
  needed it: what you added, what the design system lacks, and the tweak's key. "I added
  the account switcher's options with the address beneath; the system's select option
  has no second line, so there is a new tweak, `acctList`." A person cannot find a gap
  from its key alone, and a gap nobody was told about is never decided. They decide it
  whenever they choose; the only deadline is `implement`. **When the review of a part of
  the page is wrapping up, push for a decision on its gaps** — name each one still
  undecided there and ask. That is when the person has just looked at it closely.
- **Keys are ten characters or fewer** (`menu`, `tabBar`, `histTable`). The panel shows
  the key as the label in a fixed-width column that does not grow with the panel, and
  there is no separate label field.
- **Exploring is a mockup; choosing is a tweak.** While the options are still being
  invented — "what could this badge be?" — build a throwaway HTML page instead: the
  candidates side by side, in the project's real tokens, with a light/dark switch. Write
  it into the design's folder (`design-<name>/mockups/`) and open it locally — never an
  artifact, which is for sharing and leaves something on claude.ai to clean up. The
  folder is transient, so the mockup goes with it. No design publish, nobody waits.
  Tweaks are for the end of that: two or three settled options, judged in place on the
  real screen. **"Let me see it" means before anything is built or published** — show
  the change as a mockup (or the render check's screenshot of a local build) and wait;
  landing it first and showing the result afterwards spends a design-system publish on
  something the person may not want.
  **That is for working interactively. In an autonomous run, build the options as real
  design pages** — nobody is waiting to look at a local mockup, and a page with full
  visuals is what the person reviews when they come back. Give each option its own page,
  named so it reads as an option ("Order history — A: one list"), and link them into
  Play. Where a big choice cannot be settled from the brief and the plan, add a page that
  compares the options, named for what it compares. Anything those pages need that the
  system lacks is still a gap tweak, listed in the run's final report.
- **Offer one per independent option** whenever a design choice is a judgement between
  options — never one tweak bundling several. When you offer them, tell the person to flip
  them on the canvas with full-screen Play open in a second tab; the Play tab follows.
- **Editors:** `boolean`, `enum` (with `options`), `text`, `int`, `float`, `range`,
  `color`; `section` groups them. `default` seeds the control only — read it with
  `this.props.x ?? <default>` in `renderVals()`.
- **Apply a preview through a class on the page root,** computed in `renderVals()`, with
  every preview rule in ONE block marked `/* PREVIEW — <what> … removed when decided */`
  and closed by `/* END PREVIEW */`. `check-design.mjs` lists what is inside as open
  decisions and fails anything drawn outside it.
  An inline `style` beats the class: move an inline value into a class before previewing it.
- **Preview only what the change will reach.** A design-system change is previewed by
  overriding the component's `data-slot` parts, never the page's own wrappers.
- **The person's flips are saves.** Each publishes a new version, and the editor rewrites
  `data-props` double-quoted and HTML-entity encoded. Re-read the page before every publish,
  parse `data-props` in either quoting, and keep the values the person saved as defaults.
- **Land what the person approves; remove what they reject.** Read their states from the
  design — each flip is a save — rather than asking. An approved gap is decided with them
  into what it becomes (an existing component it should have used, a new component, a UI
  pattern), built in the UI package, published with `publish-system` and applied to the
  design; then its tweak, preview rules and candidate mark come out in the same change. A
  rejected gap's tweak, preview and candidate markup come out. The Theme tweak stays, and
  `systemOnly` stays while any gap is open.
- **Implement waits for every gap.** `check-design.mjs --implement` fails while any gap is
  undecided, approved but not landed, or rejected but not removed.
