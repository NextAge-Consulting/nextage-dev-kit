# Memory Discipline

**Auto-memory is off** — `autoMemoryEnabled: false` in the kit's `settings.json`. Never write to it, and never cite an old memory file from a file in the repo: nobody else can open it.

## Nothing becomes permanent on your judgment

A rule, a project rule or a doc written because a session thought something mattered is the same bloat as a memory file, moved somewhere everyone loads it. Most of what a session learns matters only to that session. Let it end with the session.

**The human decides what is kept.** Write a rule or a doc only when they direct it — "make that a rule", "remember this", "write that down".

**Propose one only when you can name a future task, different from this one, where a session would do the wrong thing without it** — a behaviour to adopt or stop, or an existing rule that is wrong. A decision made, a fact observed, a thing that happened is a diary entry: the code, the commit and the conversation already hold it, and it ends there. Name the task in the proposal, in one line with what and where, and drop it if they do not say yes.

## Where a directed change goes

- **Every project** → the dev kit. Unless this machine is the kit maintainer's, that is a GitHub issue on the kit's repo (`kitRepo` in `.claude/.kit-sync.json`), never an edit to a synced file.
- **How work is done in this project** → `.claude/rules/project/**`.
- **A fact about this system** → `project-documentation/`.

**File a kit issue only for a defect, a blocker, or a change a new feature or dependency forces** — never for "this could read better".

**A kit issue and every comment on one is world-readable: the kit's repository is public, and editing or deleting text there does not unpublish it.** Name the project, the people and what happened as fully as the problem needs. Leave out anything that is or looks like a credential, all infrastructure identity — account ids, hostnames, domains, IPs, ports, ARNs, endpoint, bucket and database names, connection strings — and any business detail the client would treat as confidential: their data, schema drawn from their model, row counts, volumes. When unsure whether a detail qualifies, leave it out. A project whose client asked not to be named says so in `rules/project/`, and its kit issues call it "a consumer project".

**When a kit-owned file stands in the way of the work, follow the script in `block-kit-edit.sh`'s deny message:** put the reason to the human, and change the file only as the temporary patch it describes, after their yes.
