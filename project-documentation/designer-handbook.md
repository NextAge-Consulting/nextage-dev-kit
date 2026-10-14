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
  made of. Each is one of a standard list of block types — a review dialog, a record
  header, a browse toolbar — and an app has one per type, built the first time a screen
  needs it. The UI inventory lists them with their type, and Claude reads it before
  building any screen.

Claude won't style a screen in a project that has no `design.md`. That refusal is what
stops a design from drifting one screen at a time.

The design system has two themes, light and dark. Settings a user changes in the running
app — an accent colour, a colour-blind mode, a text size — are covered in
`custom-themes.md`; Claude Design shows light and dark only.

Text stays readable by rule: the token check measures every text colour against the
background it sits on, in light and in dark, and fails below WCAG's 4.5:1. It knows which
colours go together from the components in `design.md` and from names like `card` and
`card-foreground`. A colour you keep on purpose below the bar is marked accepted, with its
ratio and the reason, on the token's line.

### Nothing new ships until you approve it

Claude builds screens from what the system already has. When a screen needs something
the system lacks (a component, a variant, a token, a pattern), Claude builds it and keeps
going, marking it **pending** rather than stopping to ask. You review everything pending
together, at the end of the work: each piece is approved, swapped for an existing part, or
changed until you approve it.

- `/work` lists what is pending at the start of each session, and `/handoff` tells you how
  many are left when you finish.
- `/deploy` refuses while anything is pending, so pending UI can sit on `main` for days
  but never reaches production.
- A change you ask for in conversation ("make Save wider") is made to the part, with a
  warning of what else it changes. Your yes is its approval.

## Starting and growing a design system

### A new project: start from a tweakcn theme

1. **Pick a theme at [tweakcn](https://tweakcn.com) and make it yours** — colours for light
   and dark, fonts, the corner radius, shadows. This is the one place you choose a look by
   eye; everything else follows from it.
2. **Hand Claude the theme's code** (the Tailwind v4 version). Claude puts it in the
   project's token stylesheet and writes `design.md` from it.
3. **Run `/design-audit system`.** Your theme covers colour, type and radius; it says
   nothing about spacing roles, focus, motion, badges and the rest. The audit lists each
   place the kit has an opinion your system lacks, and you adopt them one by one.
4. **Start building.** Anything still missing is filled in the first time a screen needs
   it (below).

### An existing app: extract, then merge

1. **Claude extracts the design system the app already has** — the colours, type sizes,
   spacing and corners it actually uses — into a token stylesheet and `design.md`. When a
   thing is drawn several ways, each one comes to you as a choice, not a guess.
2. **Optionally, merge a tweakcn theme as the path forward.** Pick one the way a new
   project does; Claude merges it over what was extracted, and every conflict between the
   two is your call.
3. **Run `/design-audit system`**, as for a new project.
4. **Leave the old screens alone until you have time for them.** The checks at every commit
   judge only the lines that change, so existing screens never block your work, and nothing
   new can break the system. When you can spend time on an area, audit it
   (`/design-audit project <path>`) and bring it into line.

### Where a value comes from after that

Everything the system doesn't yet cover is filled in as the work reaches it, always in the
same order:

1. **Your design system.** If it answers, that's the answer.
2. **The kit's design opinions** (`design-opinion.md` in the design-system skill). The kit
   is opinionated about the small building blocks — spacing, type, colour, radius,
   elevation, motion, icons, controls, focus, dark mode, badges. An opinion found there is
   built into your system, in your own names, so your system answers from then on.
3. **You.** When neither has an answer, Claude puts the decision to you; once you decide,
   it is built into the system and stays decided.

Some opinions are guidance any designer would agree with: one consistent approach to
shadows, quiet purposeful motion. Others are sides the kit has picked: no toasts, icon-only
standard actions, a soft focus ring. Your project can differ from any of them; the reason
is written where your system holds the value. The kit never chooses your colours.

### The design audit

**It runs only when you ask.** It is never part of CI and never blocks a commit.

| Run | When |
|---|---|
| `/design-audit system` | After you set up or merge a design system; after a kit update adds opinions; whenever the system feels like it has drifted |
| `/design-audit project` | When you have time to bring the whole app into line with the system |
| `/design-audit project <path>` | When you have time for one area of it — an app, a folder, a set of screens |
| `/design-audit design <name or url>` | Before implementing a Claude Design design, to check it uses the system as it stands |

The system audit checks three things only: whether your system is complete, whether it
breaks one of the kit's picked sides or a floor such as contrast, and whether it
contradicts itself. Where the kit only offers guidance and your system differs, the audit
asks "are you sure?" separately from its findings. Keeping your own value needs no
reason: it's marked as your choice, and no later audit asks again.

**What to expect:**

- **A fresh reviewer.** Each pass runs in a new agent that sees only the files it is
  auditing — not the conversation — and tells you how many it read.
- **The system first.** A code or design audit starts with the system pass. If the system
  itself has open findings, those come first: screens are judged against a system that is
  right.
- **One finding at a time**, each with what fixing it costs, what it risks, and Claude's
  recommendation. You answer each one:
  - **Fix the work** — the screen or design is brought into line with the system.
  - **Add to the system** — the system was missing something; it gains it, and every
    screen can use it.
  - **Accept it** — the line keeps its value with your reason beside it
    (`design-accepted — <reason>`), and no later audit raises it again.
- **Nothing changes without your answer.** You can stop part-way; what you have settled
  stays settled, and the next run picks up the rest.

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

**Two ways to see a screen at phone size, and neither is preferred.** A phone preview
puts a phone-sized frame beside each screen on the canvas, so desktop and phone sit side
by side while you work. Or open the design in Play in your browser and switch on the
browser's device mode, which shows the same fluid page at any size you pick. When a new
design starts on a screen used on both, Claude asks whether you want phone previews, and
you can ask for them later too.

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
   step opens the design's folder in the repo. A screen the app already has is designed
   with its real records and labels; only a brand-new screen gets invented sample data.
   The brief records which.
2. **Create the design.** The conversation becomes a brief, and the brief becomes the
   design in Claude Design. This happens once.
3. **Work on it.** Reopen the design at any time and keep changing it in conversation.
   Every change you agree on is published to the design and noted in the brief.
4. **Take feedback.** Share the design, let reviewers comment on it, then work through
   their comments one at a time. Each one is discussed, then changed, skipped, or marked
   as something the design system itself should gain.
5. **Implement.** It starts only once every design-system gap is approved and landed, or
   rejected. The design is exported, the real screens are built from it, and the folder is
   removed.

Two further actions look after the design system rather than any one design:
**publish-system** publishes the system from code, and **apply-system** brings existing
designs up to the current version.

**Every publish is a numbered release.** The design system's cover in Claude Design
shows a line like `Release 12 · built 2026-10-01 from 3f2a1c9`: the release number, the
day it was built, and the commit it came from. Each design's folder records the release
the design uses. When a design's release is lower than the system's, the design is
looking at an older system than the code ships — its components may look or behave
differently from what implement will build — and apply-system brings it up to date.

### The design folder

While a design is in progress it has a folder in the repo,
`project-documentation/temporary/design-<name>/`:

- `README.md` holds the design's link, its status and the design-system release it uses,
  so nobody has to paste the link around.
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

**When the design needs something the system doesn't have, Claude shows you the gap
instead of quietly drawing it.** A design that hand-draws its pieces looks right in the
prototype, has to be taken apart to be built, and leaves you with a design system that no
longer describes what you see. A check runs before every publish, so a hand-drawn piece
stops the publish rather than slipping through. How you decide a gap is the next section.

### Design-system gaps: how you approve them

A gap is anything the design needs that the design system doesn't have yet: a menu row, a
tab bar, spacing inside a card that the card doesn't give. Every gap is on the canvas as a
tweak, so you judge it by looking, never from a description of pixels.

**Where to find them.** Each gap's tweak is on the page you judge it on: open that page
and its Tweaks panel. The **Design system** section holds one setting per gap, under a
short name (`menu`, `tabBar`, `contact`) — the name you use when you talk about it. The
panel cuts labels short and can't be widened, which is why the names are short. A gap
that also appears on other pages shows there as designed, with no tweak, until you
decide it.

**Claude tells you the moment it creates one.** In the same reply as the change, it says
what it added, what the design system lacks, the tweak's name and the page it is on: "I
added the account switcher's options with the address beneath; the system's select has
no second line, so there's a new tweak, `acctList`, on the account page." Nothing appears
in the panel without that. Before building it, Claude has a fresh agent — one that sees only
a description, never the screen — say which existing part it extends or what generic name a
new part takes, so a tweak is named for what it is (`fieldRow`), never for the screen that
first needed it.

**Review with three windows side by side.** The design folder's `tweaks-to-approve.md`,
open in your editor, defines every option: what it adds, what it is for, where it is on
every page, the exact values it changes against the design system as it is, anything the
page draws outside the tweak that approving it approves too, and the part it extends.
The canvas's Tweaks panel is where you flip it; a second tab in Play shows the result. Ask
Claude when something needs discussing.

**Decide them whenever you like.** Now, or when you review that part of the page — the
only deadline is implement. As a part of the page wraps up, Claude asks for a decision on
that part's gaps, since that's when you've just looked at it closely. The design's `brief.md` records which parts you've reviewed.

**What the options mean.** Each gap's options say where your decision stands, and the
letter is defined in `tweaks-to-approve.md` — the panel cuts off anything longer:

- **Undecided — A:** shown on the page, not approved. Every gap starts here.
- **Approved — A:** shown the same way, and approved. With more than one option, B and C
  each have their own Approved entry.
- **System as is:** you don't want the addition. The page shows what the design system
  gives today.

**A tweak you can only see on a phone is on the phone frame.** It is marked **Phone only**
in `tweaks-to-approve.md`, and its control is in that page's phone frame's Tweaks panel —
a tweak on the full page never reaches the frame. Skip these on a desktop pass.

**Flipping the setting is the decision.** Each flip saves the design, and Claude reads your
choice from it, so there's nothing to repeat in chat.

**Design system only** (`systemOnly`) is the master switch at the top of the section. Turn
it on and every gap's override disappears at once: you see the page exactly as the design
system builds it today. Turn it off to see the proposals again. It's the quickest way to
see how much of a screen is still proposal.

**What happens after you decide.**

- **Approved:** Claude works out with you what it becomes (a new component, a variant of
  an existing one, or a pattern), builds it into the design system, publishes the system
  and applies it to the design. The tweak then disappears, because it's no longer a gap.
  Every approval lands in the next batch, together with the others, so the system is
  published once rather than for every decision — and nothing approved waits for a later one.
- **System as is:** the addition comes out of the design, and the tweak goes with it.

**Implement waits for every gap.** `/ui-design implement` won't start while any gap is
undecided, approved but not yet in the design system, or rejected but still in the
design. It lists the ones in the way.

### Tweaks: flip a switch to judge a change

**Still working out what the options even are? Ask for a mockup, not tweaks.** Claude
builds a quick throwaway page with the ideas side by side, in the design system's real
colours and a light/dark switch, and opens it on your machine — no waiting on a design
publish, and nothing left on claude.ai to tidy. Saying "let me see it" gets you the same
before anything is built. Tweaks come once
you've narrowed it to a few real candidates.

**Handing Claude a run to finish while you're away? The options come back as real pages.**
In an autonomous run nobody is there to look at a quick mockup, so Claude builds each
option into the design as its own page with full visuals, named as an option ("Order
history — A: one list"), and adds a page comparing them where a big choice is still open.
You review them on the canvas when you're back, and every gap they raised is in the run's
report.

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
- **Say which option won** — or, for a design-system gap, flip it to Approved. Claude makes
  the winner real, applies it to the design and deletes the tweak. The Theme tweak is the
  one that stays, and Design system only stays while any gap is open.

How Claude builds tweaks is in the `claude-design` skill's
`references/working-with-claude-design.md`, for Claude rather than for you.

### Working with other people

**Reviewers who don't design** get the design from its Share menu, either by link or by
invite with view, comment or edit access. Every invitee needs a Claude account, and a free
one is enough. Tell them to open it in Chrome: in Firefox the design loads but every frame
stays blank. They leave comments on the design, and a feedback round works through them.
Only open comments come up in the next round, so resolve or delete each one the round
dealt with.

**Two people who both design**, such as a designer and a developer, share the design with
edit access and each drive their own turns. The designer pushes for the ambitious
version; the developer keeps it grounded in the codebase ("we already have that icon",
"that control can't exist"). A reaction relayed through a third person costs several
round trips, so each person talks to the design directly.

Anyone with edit access drives a design from Claude Code or from the design's own chat in
claude.ai, whoever created it.

Neither Claude Code nor the chat is told when the other side changes the design, which is
why every `/ui-design` action reads the design fresh before touching it.

### What to expect

- A new design system needs one small edit on its page in Claude Design before designs
  can use its components. After that, publishing is routine.
- The prototype is close to the build but not the build. Implement uses it as the
  reference for layout and behaviour; it never copies the design's markup into the app.
- Old comments that keep coming back were never resolved. Resolve them in the design view.
