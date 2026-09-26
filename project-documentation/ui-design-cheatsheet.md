# UI Design Cheat Sheet

One-page reference for designing screens in Claude Design from a kit-enabled project. For
the subsystem's architecture, see `handbook.md` §12a.8; for why it works this way, the
`claude-design` skill's `references/working-with-claude-design.md`.

**The code is the source of the design system. Claude Design does the designing.** The
system moves from code into Claude Design; designs come back out into code.

---

## The commands

```
/ui-design start order-history      # open the design's folder and talk the screen through
/ui-design prototype                # write the brief, build the design in Claude Design
/ui-design feedback [name or url]   # pull reviewers' comments down, settle them one at a time
/ui-design implement [name or url]  # export the design, build the real screens, remove the folder
/ui-design publish-system           # build the design system from code and publish it
/ui-design refresh-design [url]     # bring designs onto the current design system
```

Plain words route there too: "let's redesign this screen", "build the design", "work the
comments", "implement the design", "publish the design system".

A name matches the design's folder; a url matches the link in its `README.md`. With
neither, and exactly one design folder open, that one is used.

---

## A design's life

```
start ──► prototype ──► feedback ⟲ ──► implement
 folder     brief.md      comments       export/, screens,
 README.md  the design    settled        permanent doc,
 screenshots              Decisions      folder removed
```

1. **start** — creates `project-documentation/temporary/design-<name>/` with its
   `README.md` (status `shaping`). Hand over screenshots of the screen being replaced;
   they are copied in. Talk through what the screen keeps, who uses it and its shape.
   Nothing is written to Claude Design yet.
2. **prototype** — writes `brief.md` from the conversation, builds the design with the
   project's design system installed, records the link in `README.md` (status
   `prototyped`). Run again on a folder that already has a link and it revises that
   design rather than making another.
3. **feedback** — share the design, reviewers comment, then run it. Comments are shaped
   into items, discussed one at a time with a cost and a recommendation each, settled
   (change it, skip it, or a design-system candidate), made in one publish, and appended
   to `brief.md` under `## Decisions` (status `in feedback`). Repeat per round.
4. **implement** — exports the design into the folder's `export/`, records the version
   built from (status `implementing`), builds the screens under the project's UI rules,
   writes the design's link and the decisions worth keeping into the feature's permanent
   doc, then removes the folder.

**The design folder:**

| File | Holds |
|---|---|
| `README.md` | The pointer: feature, lead, status, the design's link, the version built from |
| `brief.md` | The agreed shape; under `## Decisions`, what each feedback round settled |
| screenshots | The source material, copied in |
| `export/` | The design's pages and assets — written by `implement` only |

---

## What a design is

**One interactive prototype, one page per screen, each screen a fluid page.** Screens
link together in Play like the application. Each board and its preview open at
1440×900, the browser-testing viewport; Play fills the window. A fixed-width preview is
added only when a review asks for one.

A design is driven from Claude Code or from its chat in claude.ai, whichever you prefer.
Neither side is told of the other's changes, so every `/ui-design` action reads the
design before editing it.

---

## The design system

```
npm run build:design-system    # from the UI package: writes dist/design-system/
npm run check:design-system    # renders every component in light, dark and canvas mounting
/ui-design publish-system      # both of the above, then publish, then refresh designs
```

- **One design system per repo.** Its address is the `artifact:` line in the UI
  package's `design-system/design-system.config.mjs`, committed. Anyone who can edit it
  publishes to that one address.
- **Change it in code, never on its page.** A token, a component, a usage note — edit the
  UI package and publish again.
- **The config needs `timeZone`,** the project's IANA zone. Each sync is dated in it.
- **A design keeps its own copy of the system** and never updates by itself.
  `refresh-design` brings it onto the current version, and every action that opens a
  design warns when its copy is behind and asks whether to refresh first.
- **A newly published system needs one small edit on its page** (a token's usage note)
  before designs can mount its components — the page writes its consuming section only
  then.
- **Never set a design system as the account default** when the account serves several
  projects. Attach it per design.

---

## Reviews and comments

- **Share from the design's Share menu:** by link, or by invite with view, comment or
  edit access. Every invitee needs a Claude account; a free one is enough. A signed-out
  viewer can click through, but anything the prototype saves needs a signed-in viewer.
- **A comment is never deleted, only resolved,** and a thread stays on the design
  through every later version.
- **A feedback round reads open threads only.** Resolving is what takes a thread out of
  the next round.
- **`feedback` resolves only threads a writer has sent to Claude.** Every other thread
  the round dealt with is listed as still open — resolve those in the design view, or the
  next round reads them again.

---

## Two people designing

Share the design with **edit** access; each person drives their own turns.

| Collaborator is | Drives the design from | Takes the design system |
|---|---|---|
| In your organization | Claude Code or the design's chat | From the design system picker, or by link |
| In another organization | **Claude Code, naming the design's link in the prompt** | By naming the system's link in the prompt |

From another organization, the browser chat treats a shared design as read-only despite
edit access and edits a copy instead, and nothing shared appears in their lists — Shared
with you, `/artifacts`, the picker, or `refresh-design`. By link, everything works.

---

## What NOT to do

- **Don't edit the design system in Claude Design.** The next publish overwrites it.
- **Don't use `/design-sync` for this.** It writes a different store that the Design
  type does not install from.
- **Don't build a design as fixed-size device frames** side by side — one fluid page per
  screen.
- **Don't copy a design's markup into the app.** `export/` is the reference for layout
  and behaviour; the screens are built from the project's real components.
- **Don't publish from a working tree carrying test edits** — the published system
  records the commit it came from, flagged when uncommitted.

---

## Troubleshooting quickies

| Symptom | Cause and fix |
|---|---|
| Build fails naming tokens | A token has no usage comment, or uses a colour construct the engine can't translate. Fix the token in code — never drop it. |
| Build fails asking for `timeZone` | Add the project's IANA zone to the config. |
| A design shows the system's colours but no components | The system has never been edited on its page. Make one small edit there, then refresh the design. |
| Publish refused because someone saved meanwhile | The action re-reads and redoes the edit once; a second refusal stops and says so. |
| A collaborator's change landed in a copy, not your design | Their browser chat can't write to a design shared from another organization. They drive it from Claude Code, by link. |
| The design system isn't in someone's picker | It was shared from another organization. Name its link in the prompt. |
| Old comments come back every feedback round | They were never resolved. Resolve each thread a round dealt with, in the design view. |
