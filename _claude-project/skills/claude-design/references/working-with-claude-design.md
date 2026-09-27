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
  and fails on errors, empty renders, overlays that do not open or open detached.
- **Provenance.** Each sync is dated in the config's `timeZone` and records the commit it
  was built from, flagged when the working tree was uncommitted.

**What stays the project's:** the token rules in the design-system skill, and the config:
which components are previewed, what each preview shows, where each one's guidelines come
from.

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

- **Offer one per independent option** whenever a design choice is a judgement between
  options — never one tweak bundling several. When you offer them, tell the person to flip
  them on the canvas with full-screen Play open in a second tab; the Play tab follows.
- **Editors:** `boolean`, `enum` (with `options`), `text`, `int`, `float`, `range`,
  `color`; `section` groups them. `default` seeds the control only — read it with
  `this.props.x ?? <default>` in `renderVals()`.
- **Apply a preview through a class on the page root,** computed in `renderVals()`, with
  every preview rule in ONE block marked `/* PREVIEW — <what> … removed when decided */`.
  An inline `style` beats the class: move an inline value into a class before previewing it.
- **Preview only what the change will reach.** A design-system change is previewed by
  overriding the component's `data-slot` parts, never the page's own wrappers.
- **The person's flips are saves.** Each publishes a new version, and the editor rewrites
  `data-props` double-quoted and HTML-entity encoded. Re-read the page before every publish,
  parse `data-props` in either quoting, and keep the values the person saved as defaults.
- **When the person decides,** make the winner real in the design system, apply it to the
  design, and delete the preview block and the tweak in the same change. A theme tweak
  (System / Light / Dark) stays.
