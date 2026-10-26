# Kit sync cheatsheet

For a project's **kit syncer** — the one person on a project who brings dev-kit updates
into it.

## One syncer per project

Pick one person per project to own kit syncs. They set the project up, follow the kit's
releases, and decide when to sync. Two people syncing one project means two people
answering its migrations differently.

## Set up — once per project

Open Claude Code in the project and paste:

```
Set this project up to sync the NextAge dev kit itself.

1. Find my local copy of the nextage-dev-kit repository on this machine. If you
   can't find it, ask me where it is. If I don't have one, clone
   https://github.com/NextAge-Consulting/nextage-dev-kit.git into ~/projects/.
2. Bring that copy up to date with its main branch. If it has local changes or is
   on another branch, stop and tell me instead of changing anything.
3. If ~/.claude/dev-kit-config.json does not exist, create it containing only
   {"devKitPath": "<the full path to that copy>"}.
4. Copy _claude-project/commands/sync-dev-kit.md from the kit into this project's
   .claude/commands/ folder, and _claude-project/scripts/sync-dev-kit.sh into its
   .claude/scripts/ folder, keeping the script executable.
5. Tell me to run /sync-dev-kit next, and stop.
```

Then run `/sync-dev-kit` and commit what it changed. From then on `/sync-dev-kit` is in
the project for everyone, and a sync keeps it current.

## Hear about every release

On the kit's GitHub page, <https://github.com/NextAge-Consulting/nextage-dev-kit>, click
**Watch → Custom → Releases → Apply**. GitHub then tells you about each release and
nothing else.

## Read a release before you sync

- **The title** gives the date and the impact: `2026.10.25 — 2 migrations, 1 asks for
  decisions`, or `— no migrations`.
- **The notes** say what changed, then list each migration: what it changes, whether it
  asks you to decide anything, and how much of your time it takes.

A release with no migrations can be synced any time. Plan a sitting for one that asks for
decisions: they are your project's decisions, and the sync asks you to make them.

## Sync

Run `/sync-dev-kit`. Before it changes anything, it briefs you on this project:

- how many kit files it updates — those land in one pass, with nothing to decide;
- any file that needs you, such as a kit file someone in the project edited;
- any setting to decide;
- each migration: mechanical or asking for decisions, how many minutes of yours it takes,
  and how much of the project it touches.

Say no and nothing has changed. Say go and it works through the rest, asking only what it
listed. Commit afterwards, the same as any change.

## Need something changed in the kit?

File an issue on the kit's repository. The kit itself changes only through its
maintainer; your project takes each change when you sync it.

A defect gets fixed only once the maintainer can reproduce it, so a report needs the
exact command that failed, its full output, the project's kit version, and the steps
that bring it back. Your Claude session is told to gather these when it files one;
check they are there before it posts. A cause your AI guessed at is labelled a
guess, not stated as fact. The repository is public, so leave out hostnames,
credentials and client data.
