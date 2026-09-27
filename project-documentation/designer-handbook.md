# Designer

The guide for whoever works out what screens look like in a kit-enabled project: where
the design system lives, and how Claude Design fits in, from the first sketch of a screen
to the built code. `overview.md` shows where this fits. The commands are in
`ui-design-cheatsheet.md`; the mechanics belong to the `claude-design` skill, and you
never need to read it.

## The design system lives in code

The project's look is defined once, in code, and everything else reads from it:

- **`design.md`** at the repo root is the spec: colours, type, spacing, radii, and how each
  basic component looks. It follows a published format and is checked by a linter.
- **The token stylesheet** holds the same values in the form the browser uses. If the two
  disagree, the stylesheet wins, and `design.md` gets corrected.
- **The components** in the project's UI package are the building blocks every screen is
  made of. The UI inventory lists them, and Claude reads it before building any screen.

Claude won't style a screen in a project that has no `design.md`. That refusal is what
stops a design from drifting one screen at a time.

## Claude Design

### What it is

**Claude Design is a prototyping tool for working out a screen visually before it is
built.** You reach it from Claude Code or from claude.ai, and it is connected to your
project through the design system.

That connection is the point. A design mounts the same components and tokens the app
ships, so what you see in the prototype is made of what the build will use. When the
design is settled, Claude Code builds the real screens from it with those same components.
**A design is prework for the build, not a throwaway picture.**

A design is an interactive prototype, not a board of mockups. Each screen is its own
page, the pages link together, and Play clicks through them like the real application.
Each page is fluid and reflows the way the app will, rather than being drawn once per
device size.

### When to reach for it

When a screen is worth seeing before anyone builds it: a redesign, a new feature with a
layout still in question, an interaction to settle with stakeholders who react better to
something they can click than to a description.

It is optional, screen by screen. A screen whose shape is obvious goes straight to code.

### The loop

Every design follows the same path, one `/ui-design` action per step. Plain words work
too: "let's redesign this screen", "build the design", "work the comments".

1. **Start.** Hand over screenshots of what you're replacing and talk the screen through:
   what it keeps, who uses it, and roughly how it's laid out. Nothing is built yet. This
   step opens the design's folder in the repo.
2. **Create the design.** The conversation becomes a brief, and the brief becomes the
   design in Claude Design. This happens once.
3. **Work on it.** Reopen the design at any time and keep changing it in conversation.
   Every change you agree on is published to the design and noted in the brief.
4. **Take feedback.** Share the design, let reviewers comment on it, then work through
   their comments one at a time. Each one is discussed, then changed, skipped, or marked
   as something the design system itself should gain.
5. **Implement.** The design is exported, and for every piece that was drawn by hand you
   decide what it becomes: an existing component, a new component, a UI pattern, or
   something local to that one page. Then the real screens are built, and the folder is
   removed.

Two further actions look after the design system rather than any one design:
**publish-system** publishes the system from code, and **apply-system** brings existing
designs up to the current version.

### The design folder

While a design is in progress it has a folder in the repo,
`project-documentation/temporary/design-<name>/`:

- `README.md` holds the design's link and its status, so nobody has to paste the link
  around.
- `brief.md` holds the agreed shape and a log of every decision made since.
- The screenshots you started from are copied in beside them.

The folder is temporary on purpose. When the screens are built, the decisions worth
keeping move into the feature's permanent documentation and the folder is removed, taking
the rest of the log with it.

### The design system in Claude Design

The design system is edited only in code and then published to Claude Design. Anything
changed directly on its page in Claude Design is lost at the next publish.

A design keeps its own copy of the system from the moment it is created, which is why it
can be shared without anything else going with it. That copy does not update by itself.
When the system changes, `apply-system` brings a design up to date, and every action that
opens a design warns you when its copy is out of date.

### The rule that keeps a design buildable

**A design is assembled from the system's components; it does not redraw them.** The page
decides what goes where: which components appear, in what order, and in which columns. It
never sets the spacing inside a component, and it never redefines what a recurring piece
looks like. A card's padding comes from the card, not from the page wrapped around it.

When the design needs something the system doesn't have, that piece is marked as a
design-system candidate rather than drawn from scratch, and implement decides what it
becomes. This rule was learned the hard way: a design that hand-draws its pieces looks
right in the prototype and has to be taken apart to be built.

### Tweaks: flip a switch to judge a change

**Whenever you're choosing between options, ask for tweaks:** "give me a tweak for each
option". A tweak is a switch on the design, in the canvas's Tweaks panel. Flip it, and the
whole screen changes at once.

That instant on/off is the best way to judge how big a change really is. A before and an
after side by side hides it; one screen flipping in place shows it. Keep side-by-side
pages for other comparisons.

- **One switch per option.** Ask for a separate tweak for each independent choice, never
  one that bundles several, so each can be judged on its own.
- **Judge them full screen with two tabs.** Open the design twice: the canvas in one tab,
  full-screen Play in the other. Flip a tweak on the canvas and the Play tab changes at
  once, so you see the change at full size with instant on/off. Play itself has no Tweaks
  panel; for themes alone, you can also leave Theme on System and switch your device
  between light and dark.
- **Say which option won.** Claude makes the winner real in the design system, applies it
  to the design and deletes the tweak. The Theme tweak is the one that stays.

How Claude builds tweaks is in the `claude-design` skill's
`references/working-with-claude-design.md`, for Claude rather than for you.

### Working with other people

**Reviewers who don't design** get the design from its Share menu, either by link or by
invite with view, comment or edit access. Every invitee needs a Claude account, and a free
one is enough. They leave comments on the design, and a feedback round works through them.
A comment is never deleted, only resolved, and only open comments come up in the next
round, so resolve each one the round dealt with.

**Two people who both design**, such as a designer and a developer, share the design with
edit access and each drive their own turns. The designer pushes for the ambitious
version; the developer keeps it grounded in the codebase ("we already have that icon",
"that control can't exist"). A reaction relayed through a third person costs several
round trips, so each person talks to the design directly.

How you drive a design depends on where it came from:

- **You created it:** use Claude Code, or the design's own chat in claude.ai.
- **It was shared with you from another organization:** use Claude Code, naming the
  design's link. Your browser chat treats that design as read-only and edits a copy in
  your own account instead.
- **Anything shared from another organization is missing from your lists:** `/artifacts`,
  Shared with you, and the design-system picker won't show it. The link always works.

Neither Claude Code nor the chat is told when the other side changes the design, which is
why every `/ui-design` action reads the design fresh before touching it.

### What to expect

- A new design system needs one small edit on its page in Claude Design before designs
  can use its components. After that, publishing is routine.
- The prototype is close to the build but not the build. Implement uses it as the
  reference for layout and behaviour; it never copies the design's markup into the app.
- Old comments that keep coming back were never resolved. Resolve them in the design view.
