# Using Design Packs

For a developer or designer whose project takes a Design Pack, or cuts one of its own. How
packs are built and released is the kit maintainer's, in `uxes-design-packs.md`.

## What a pack is

A Design Pack carries work one project already got right into yours: how a list filters,
sorts and pages, how a form saves, how a record page is laid out. It arrives as finished
code and written rules, and from then on your project owns every file.

**Your project keeps its own look.** Colours, fonts and brand come from your own design
tokens. A pack carries a value only where that value is part of what the pack is, and it
says why: a back office is compact, so its pack carries its spacing and sizes.

Nothing syncs afterwards. A pack never changes your project again unless you ask to see
what it has changed.

## Finding a pack

Packs live in one public repository, `uxes-design-packs`, in the kit's organisation.

- **`packs/<name>.json` is an app pack:** a named list of pieces that make up a whole kind
  of app, with the values it carries and its reason. Start here.
- **`pieces/<piece>/` is one piece:** a recipe, a behaviour rule or a block, with the code
  that implements it. A piece with wiring to do has a `GUIDE.md` that says what.
- **A piece named `<pack>-reference` holds the reference pages:** realistic screens built
  from the pack's pieces, with cards showing each variant and state. Looking at these is
  the fastest way to see what a pack gives you.

## Before you install

**An install refuses until your project's design system is complete.** Every colour,
size and spacing in your UI is a token, every component in your inventory has a status,
and nothing is waiting on a decision. The install checks this first and names what is
missing. Finishing that is your project's own work.

You also need to know which app the pack is for. A project with several apps installs a
pack into one of them; the others keep their own rules.

## Installing

In your project's Claude session:

```
/design-pack install <app pack or piece> --app <your app's workspace>
```

Claude does the work. You are asked for three things, in this order:

1. **Decisions where a pack file meets one of yours.** When the pack brings a component
   your project already has, you see both side by side and choose: use yours, replace it,
   or keep both with a reason. A library your project lacks is put to you as any new
   dependency.
2. **One review of the roles.** One page showing each role the pack needs that your
   project lacks, and each value the pack carries that differs from yours, with the pack's
   reason. You decide each once.
3. **One look over the reference pages.** Claude mounts them in your app. You look each
   over, in each theme, for anything plainly wrong.

Then you say it is approved, and everything the pack installed is approved in one step.
No piece is reviewed one at a time. A fault you find later is ordinary refinement of your
own code, and a fault in the pack itself is reported so the pack is fixed.

The reference pages stay in your app until you say to remove them.

## Seeing what a pack has changed

```
/design-pack compare
```

Each installed file records the pack version it came from. Compare shows what the pack
has changed in that file since, and you take each change or leave it.

## Cutting a piece from your project

```
/design-pack extract <recipe, behaviour rule or block>
```

It needs everything committed and nothing pending. Claude works out the files, takes your
business's words and data out of them, and proves the piece builds on its own in an empty
project. The result is a folder per piece. You
say what the pack carries and why.

## Packs from another repository

A team can keep its own packs repository, private or public, in the same shape: `pieces/`
and `packs/`. It is theirs alone: how it is committed, versioned and released is up to
them.

- **Extract into it:** add `--out <a checkout of it>/pieces`.
- **Install from it:** add `--from <its address>`. Claude's session clones it with your own
  git access, so a private repository works when you can clone it yourself. A checkout's
  folder works in place of the address.
- **Compare against it:** add the same `--from`.

```
/design-pack install <app pack or piece> --app <workspace> --from https://example.com/team/packs.git
```

An installed file records the piece and the version, never which repository it came from.
A project that takes pieces from more than one repository compares each file against the
repository it came from.
