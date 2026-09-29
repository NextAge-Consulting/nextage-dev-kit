# UI Design Cheat Sheet

One-page reference for designing screens in Claude Design from a kit-enabled project. New
to it? Start with `designer-handbook.md` — what it is, the loop, and working with
someone else.

**Claude Design is a prototyping tool you reach for from Claude Code or claude.ai,
whenever a screen is worth working out visually first.** It is wired in through the
design system: the code is the system's source, a design is built from the project's own
components, and `implement` turns it into the real screens — prework, never throwaway.

---

## The commands

```
/ui-design start order-history      # open the design's folder and talk the screen through
/ui-design create-design            # write the brief, build the design in Claude Design (once)
/ui-design work [name or url]       # pick the design back up and keep changing it in conversation
/ui-design feedback [name or url]   # work, with reviewers' comments pulled in as the agenda
/ui-design implement [name or url]  # export the design, build the real screens, remove the folder
/ui-design publish-system           # build the design system from code and publish it
/ui-design apply-system [url]     # bring designs onto the current design system
```

Plain words route there too: "let's redesign this screen", "build the design", "let's
work on the order-history design", "work the comments", "implement the design", "publish
the design system".

A name matches the design's folder; a url matches the link in its `README.md`. With
neither, and exactly one design folder open, that one is used; otherwise you pick from the
list. Nobody pastes a design's link — it comes from the folder.

---

## A design's life

```
start ──► create-design ──► work / feedback ⟲ ──► implement
 folder     brief.md          changes settled,       export/, screens,
 README.md  the design        published, added       permanent doc,
 screenshots                  to Decisions           folder removed
```

1. **start** — creates `project-documentation/temporary/design-<name>/` with its
   `README.md` (status `shaping`). Hand over screenshots of the screen being replaced;
   they are copied in. Talk through what the screen keeps, who uses it and its shape.
   Nothing is written to Claude Design yet.
2. **create-design** — writes `brief.md` from the conversation, builds the design with the
   project's design system installed, records the link in `README.md` (status
   `prototyped`). It runs once; on a folder that already has a design it runs `work`.
3. **work** — opens the design from its folder's link and watches it, warns if its design system is out
   of date, reads it and says where it stands, then holds the conversation: each change
   agreed is published to the design and added to `brief.md` under `## Decisions`. A
   missing design-system piece becomes a gap tweak, and Claude tells you when it creates
   one; you flip it to Approved or System as is whenever you choose, and approvals land in
   the design system together. All are decided before implement.
4. **feedback** — `work` with the reviewers' comments as the agenda. Share the design,
   reviewers comment, then run it. Comments are shaped into items, discussed one at a time
   with a cost and a recommendation each, settled (change it, skip it, or a design-system
   candidate), published, and recorded like any `work` change (status `in feedback`).
5. **implement** — refuses while any design-system gap is undecided or not yet landed;
   then exports the design into the folder's `export/`, records the version built from
   (status `implementing`), builds the screens under the project's UI rules,
   writes the design's link and the decisions worth keeping into the feature's permanent
   doc, then removes the folder.

**The design folder:**

| File | Holds |
|---|---|
| `README.md` | The pointer: feature, lead, status, the design's link, the version built from |
| `brief.md` | The agreed shape; under `## Decisions`, every change settled since — the design's history, gone with the folder |
| screenshots | The source material, copied in |
| `export/` | The design's pages and assets — written by `implement` only |

---

## What a design is

**One interactive prototype, one page per screen, each screen a fluid page.** Screens
link together in Play like the application. Each board and its preview open at
1440×900, the browser-testing viewport; Play fills the window. A fixed-width preview is
added only when a review asks for one.

A design is driven from Claude Code by anyone with edit access, or from its chat in
claude.ai by the person who created it. Neither side is told of the other's changes, so
every `/ui-design` action reads the design before editing it.

---

## The design system

```
npm run build:design-system    # from the UI package: writes dist/design-system/
npm run check:design-system    # renders every component in light, dark and canvas mounting
/ui-design publish-system      # both of the above, then publish, then apply it to designs
```

- **One design system per repo.** Its address is the `artifact:` line in the UI
  package's `design-system/design-system.config.mjs`, committed. Anyone who can edit it
  publishes to that one address.
- **Change it in code, never on its page.** A token, a component, a usage note — edit the
  UI package and publish again.
- **The config needs `timeZone`,** the project's IANA zone. Each sync is dated in it.
- **A design keeps its own copy of the system** and never updates by itself.
  `apply-system` brings it onto the current version, and every action that opens a
  design warns when its copy is behind and asks whether to apply the current system first.
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

- **The creator** drives it from Claude Code or the design's chat.
- **An editor in another organization drives it from Claude Code, naming the design's
  link in the prompt.** Their browser chat treats the design as read-only despite edit
  access and edits a copy instead.
- **Shared from another organization, nothing appears in their lists** — Shared with you,
  `/artifacts`, the design-system picker, `apply-system`. They name the design's link,
  and the system's link when starting a design of their own. By link, everything works.

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
| A design shows the system's colours but no components | The system has never been edited on its page. Make one small edit there, then run `apply-system` on the design. |
| Publish refused because someone saved meanwhile | The action re-reads and redoes the edit once; a second refusal stops and says so. |
| A collaborator's change landed in a copy, not your design | Their browser chat can't write to a design shared from another organization. They drive it from Claude Code, by link. |
| The design system isn't in someone's picker | It was shared from another organization. Name its link in the prompt. |
| Old comments come back every feedback round | They were never resolved. Resolve each thread a round dealt with, in the design view. |
