# Overview

How work moves through a kit-enabled project, from an idea to production, and which guide
is yours. Read this once; after that, read only your own guide.

## The loop

```
  design (optional)      build                      ship
 ┌──────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
 │ /ui-design   │──►│ /work → /commit      │──►│ /merge ──► /deploy   │
 │ a prototype  │   │ → /open-pr → /triage │   │ squash     bump, tag,│
 │ built from   │   │ CI + AI review on    │   │ to main    migrate,  │
 │ real parts   │   │ every PR             │   │            release   │
 └──────────────┘   └──────────────────────┘   └──────────────────────┘
     designer              developer                   devops
```

1. **Design, when a screen is worth seeing first.** A prototype in Claude Design, built
   from the project's own components, so it is prework for the build rather than a
   picture.
2. **Build.** Every session starts with `/work`. Work lands on a branch through `/commit`,
   goes up for review with `/open-pr`, and CI plus an AI reviewer check every PR.
3. **Merge.** `/merge` squashes the PR onto `main` once CI is green. Merging does not ship
   anything.
4. **Release.** `/deploy` is the one step that ships: it bumps the version, writes the
   changelog, tags, runs any database migration, and starts the deploy. Several merges
   usually ride one release. A project with a separate Prod releases to Test this way,
   and `/deploy promote <version>` then puts a tested release onto Prod.

You say what you want in plain words ("commit this", "open a PR", "ship it"), and Claude
runs the matching command. Every git operation goes through these commands; raw git is
blocked.

## Which guide is yours

| You… | Read |
|---|---|
| Write the code | `developer-handbook.md` |
| Work out what screens look like | `designer-handbook.md` |
| Own the pipeline, the servers and the release | `devops-handbook.md` |

Most people wear more than one of these hats. Each guide is short so that wearing one
never means wearing the others.

Every guide points to a deeper reference when you need one. Those references are written
to be handed to Claude: "walk me through `new-project-setup.md`" is the normal way to use
one.

## What the kit is

The rules, skills, commands and hooks in the project's `.claude/` folder come from a
shared kit, and they arrive in the project as ordinary commits. You don't install or run
the kit; you work in the project, and the kit's conventions come with it.
