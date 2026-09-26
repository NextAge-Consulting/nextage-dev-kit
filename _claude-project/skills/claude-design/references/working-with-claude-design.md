# Working with Claude Design

How a kit project moves its design system into Claude Design and its designs back into
code.

## Why Claude Design does the designing, not Claude Code

Given the same brief, Claude Design and Claude Code both get the UX right, but Claude
Design's versions carry far more polish — micro-interactions, layering, shadows, small
touches — while Claude Code's come out flat, even with the whole repository as context.
The working theory: Claude Design spends its whole effort on the design; Claude Code,
asked for a mockup, still spends a third of it on real functionality. **The polish
carries into the real build only if the design had it**: given a polished design, Claude
Code spends its effort on function and implements the look; given a flat one, it ships
flat.

So Claude Design is the tool for imagination — redesigns, new features, greenfield UI —
and any process that lets Claude Code do the designing loses the point of it.

**The proven loop:** Claude Code writes the design brief from the repository → Claude
Design produces a few distinct variations → the team reviews and chooses → the design is
refined in Claude Design → "Send to Claude Code" → Claude Code builds it for real.

## What a design is: an interactive prototype

**A design is one interactive prototype that stakeholders can click through — not
mockups laid side by side on a canvas.** Each screen is its own page in the design
(the canvas's Page dropdown), opened and edited on its own; in Play the pages link
together like the real application. Screens can be added all at once or one at a time
from chat ("here is a screenshot of the next page — add it").

Each page is one fluid, responsive web page, never a frame per device size. The Design
type's own guide defaults to fixed-size artboards side by side on one canvas, so a design
built without the skill's "Building a design" rules comes out that way even when the brief
asks for pages.

## Where Claude Design lives

Claude Design is an Artifact type: a design is a "Design" artifact, a design system a
"Design System" artifact, both made from any claude.ai chat, Cowork or Claude Code. Drive
a design through its chat: driven that way and asked for an interactive prototype, it
produces a polished, working prototype and makes targeted revisions well.
Everything in this skill works in artifacts alone.

A design is shared from its Share menu: by link, or by email invite with view, comment or
edit access, people outside your organization included. A viewer with the link can click
through the prototype without signing in; anything the prototype saves needs a signed-in
viewer. Every invitee needs a Claude account, on any plan including free.

## Driving a design from either side

A design is driven from a Claude Code session or from claude.ai, whichever the person
prefers, and each side sees the other's changes. Nothing is handed over between them:
each reads the design as it stands and builds on it.

- **From Claude Code.** The session that creates a design is attached to it. Any later
  session picks the design up by its link — named in the prompt, or attached with
  `/artifacts` — and publishes to it. A change it publishes shows on an open canvas at
  once.
- **From claude.ai.** The design's Chat button opens a Cowork chat that reads the canvas
  and revises it. Once the creating session has ended, that chat starts without its
  history.
- **The Cowork chat has no design-system picker, and needs none.** The design's pages
  mount its installed copy of the system, and a revision asked there uses that system's
  components.
- **A Claude Code session is never told of a change made elsewhere.** A new version
  starts no turn and sends no notification, so read the design before every edit.

## The design system: code is the source, the tool a published view

The design system is edited in one place — the project's UI package — and published to
Claude Design with `/ui-design publish-system`. It is never edited in the tool: a change made only
on the canvas is lost at the next publish, and a change made only in code is invisible to
the next design. A new pattern a design invents moves into the UI package first, then
reaches the tool on the next publish.

**A design carries its own copy of the system.** Attaching a system installs its tokens
and components into the design, so a design shared with someone brings the system with
it.

**What the engine handles, so a project does not have to:**

- **Token translation.** The design format reads literals and references only. The engine
  resolves `color-mix()` (exactly, as the browser does), `transparent`, numeric knobs and
  theme blocks, and fails the build on anything it cannot translate — the format itself
  would drop it silently, and a colour missing from the dark theme inherits the light one.
- **React 18.** Design pages and canvases run React 18 whatever the app runs. The bundle
  passes `ref` to function components as React 19 does, carries React 18.3.1 itself
  (hash-checked) so previews run live, and hands a canvas's list-shaped children over as
  JSX would, so Radix `asChild` triggers work.
- **The canvas editor's host element.** Every mounted component sits in a
  `display: contents` wrapper; the bundle gives it a box under a trigger, so overlays
  anchor to their trigger instead of the corner.
- **Verification.** The render check mounts every preview in light, dark and canvas mode
  and fails on errors, empty renders, overlays that do not open or open detached.

**What stays the project's:** the token rules in the design-system skill (every token
resolvable and commented), and the config: which components are previewed, what each
preview shows, where each one's guidelines come from.

**Components in the design system stay inside what React 18 and 19 share.** `use()`,
`<Context>` as a provider, `useActionState`, `useOptimistic`, `useFormStatus`, form actions
and ref cleanup functions break inside a design. An app's own composites never enter the
design system and may use anything.

**Tool facts that shape publishing:**

- The system page writes its "Consuming this system" section, component cards and
  `tokens.css` only when a person edits something on the page. A design agent installs a
  system's bundle only when that section says it has one — so a newly published system
  gets one edit on its page before designs use it.
- A canvas holds its own copy of a system and never updates it by itself. `/ui-design
  refresh-design` brings a canvas onto the current version, and every `/ui-design` action
  that opens a design warns when its copy is behind.
- Setting a design system as the default makes every new design use it — wrong when one
  account serves several projects. Attach per design.

## Process 1 — review rounds with people who do not design

For a client or colleague who reviews rather than designs. The design lives as a shared
Design artifact; they comment ("wrong colour", "use a spinner here", "can this default?").
The owner runs `/ui-design feedback`: pull the comments down, shape them into items,
settle each one together, then revise the design, republish and report what changed. Repeat until everyone signs off. Invitees need a Claude
account (a free one is enough).

A comment is never deleted, only resolved, and a thread stays on the design through every
later version. Resolving is what ends it: each round reads only open threads. The command
resolves only a thread a writer has sent to Claude; every other thread a round dealt with
is resolved by a person in the design view, or the next round reads it again.

## Process 2 — two people who both design

A designer and a developer both drive the design agent: the designer makes the ambitious
version, the developer grounds it in the codebase, live and reactively — "we already have
that icon", "that trigger can't exist", "drop these two concepts". A reaction relayed
through another person becomes several round trips, so each person drives their own turn.

**Share the design with edit access.** The collaborator drives it from their own
account, and the design's copy of the system comes with it, so one design passes back and
forth with nothing exported.

**A collaborator in another organization drives it from Claude Code, by its link.** Their
browser chat treats the design as read-only despite edit access, and makes a copy in
their own account instead. Nothing shared from another organization appears in their
lists either — Shared with you, `/artifacts`, the design-system picker, a `list` from
Claude Code — so they name the design's link in the prompt, and the design system's link
when starting a design of their own. Neither side's session is told of the other's
changes, so each reads the design before every edit.
