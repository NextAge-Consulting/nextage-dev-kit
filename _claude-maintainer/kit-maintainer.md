# Kit Maintainer

You are the maintainer of the nextage-dev-kit on this machine. The
`block-kit-edit.sh` hook that guards kit files runs on every machine — but on
yours it finds `~/.claude/kitmaster` and short-circuits to inert, so your edits
pass straight through. (On a consumer machine there's no marker, so it blocks.)
So you may edit kit files, from the kit repo or from inside any consumer
project, and propagate them out.

## THE KIT IS PUBLIC — sanitize everything that goes into it

`NextAge-Consulting/nextage-dev-kit` is a **public, open-source repository**.
Anything written there is world-readable, permanently, including via forks and
the commit history. A secret committed and reverted is still leaked.

So every kit edit is also a publication decision. Before writing anything to the
kit, strip:

- **Client and project names** — no consumer project name, no customer or end-client
  name, no branding. Write "a consumer project", "the tenant database".
- **People** — no names, emails, usernames, or handles. Not in examples, not in
  sample data, not in commit messages.
- **Infrastructure identity** — hostnames, domains, database and endpoint names,
  bucket names, account ids, ARNs, IPs, connection strings, ports that reveal a
  deployment.
- **Anything resembling a credential** — keys, tokens, hashes, salts. Including
  fake-looking ones: no reader can tell.
- **Business specifics** — schema drawn from a real client's model, row counts,
  volumes, or measurements that identify a system.

Examples must be **invented and generic**: `example.com`, `alice@example.com`,
`app_user`, `mytable.mycolumn`. When a real case motivated the rule, describe the
*shape* of the problem, never the instance.

The consumer projects are private; the kit is not. A fact that is fine in a
project's `project-documentation/` may be a leak in the kit's. When in doubt it
stays in the project.

**Two independent mechanisms — don't conflate them.** The `~/.claude/kitmaster`
marker gates the HOOK (present → `block-kit-edit.sh` inert). What gates THIS
RULE loading is the `@kit-maintainer.md` import line in `~/.claude/CLAUDE.md`,
which is hand-maintained per machine and is not shipped by the kit. Without that
import the file is inert text. Both must be in place for the maintainer posture
to be real: the import makes the rule load, the marker makes the hook yield.
A machine with one and not the other is misconfigured — rule without marker
means you are told you may edit kit files while the hook blocks you; marker
without import means the hook yields but nothing tells you the routing rules.

## Setting up a maintainer machine

`/install-kit` has two tiers, and the default is NOT yours:

| Command | Installs into `~/.claude/` | For |
|---|---|---|
| `/install-kit` | `_claude-global/` → `commands/work.md` | every dev |
| `/install-kit --maintainer` | the above **plus** `_claude-maintainer/` → `scripts/sync-dev-kit.sh`, `commands/sync-dev-kit.md`, `kit-maintainer.md` | you, only |

**Run `--maintainer`.** Plain `/install-kit` leaves you without
`/sync-dev-kit` — it will not exist, silently. The split is deliberate: a
consumer machine never receives the sync machinery, so it cannot sync and clobber
projects you sync ahead of them. Defence by absence, not by a guard someone can
bypass.

Then, one-time — both per-machine, both deliberately unshipped:

```bash
echo '@kit-maintainer.md' >> ~/.claude/CLAUDE.md   # makes this rule load
touch ~/.claude/kitmaster                          # makes block-kit-edit.sh inert
```

`--maintainer` warns when either is missing but never creates them; a consumer
machine must not be able to self-promote.

**`~/.claude/` is a COPY, and you propagate to it the same way you propagate to a
consumer project — by editing both to byte-identical, not by re-running the
installer.** A change to `_claude-maintainer/` or `_claude-global/` lands in the
kit source AND in `~/.claude/` in the same pass, proven with `diff`. `/install-kit`
is the BOOTSTRAP for a new machine, not the propagation step — the same
distinction as `/sync-dev-kit`, which is how consumer machines pull, never how
you push.

Never symlink `~/.claude/` at the kit — global tooling would then follow whatever
branch or half-finished edit the kit working tree happens to be sitting on.

## What the kit is, and where

- The kit is the single source of truth for all cross-project rules, skills,
  hooks, commands, and workflow templates. Consumer projects receive copies via
  `/sync-dev-kit`.
- Its path is `devKitPath` in `~/.claude/dev-kit-config.json`.
- Deep mechanics are authoritative in the kit repo's own docs — read them there
  before non-trivial kit work: `.claude/rules/project/dev-kit-workflow.md`
  (source surfaces, dogfood manifest, propagation),
  `.claude/rules/project/sync-design-pre-read.md` (read before touching
  substitution/template behavior), `project-documentation/HANDBOOK.md`.

## The routing decision — make it before editing any `.claude/**` file

Is this change project-specific, or kit-shared?

| The change is… | Home |
|---|---|
| Project-specific (this repo's schema rules, a custom command/skill only this project uses, local permissions) | The project-local zones: `.claude/rules/project/**`, a project-named skill/command, `settings.local.json`. Edit in place. |
| Kit-shared (a fix to a synced rule/hook/skill/command/template; anything every project should get) | The KIT. Edit the kit source, then `/sync-dev-kit` pulls it back into consumers. |

Which files are kit-managed is authoritative in each project's committed
`.claude/.kit-sync.json` (the keys of `.files`).

## Editing kit-shared behavior from a consumer session

This is the normal path — you do not switch to the kit repo first. When you spot
a kit-template problem while working in a project:

**FIRST — before editing any file — read `dev-kit-workflow.md`'s source-surfaces
section.** A kit-managed file exists as THREE copies and you must know which is which
before you touch one: the kit **source** (`_claude-project/…`, the template synced
out), the kit's own **dogfood** (`.claude/…` in the kit repo), and each **consumer's**
synced copy (`<project>/.claude/…`). Editing before you've oriented on this is exactly
how you grab the wrong copy. This read is a hard gate, not optional.

**Then propagate by editing every copy DIRECTLY to byte-identical — do NOT run
`/sync-dev-kit`.** This is the maintainer backdoor and it is your DEFAULT: the
`block-kit-edit.sh` hook is inert on this machine, so you can write a consumer's kit
file in place. `/sync-dev-kit` is the mechanism CONSUMER machines use to pull
updates (where the hook blocks direct kit edits) — it is NOT your propagation step.
Reaching for the sync command is the slow lane you keep defaulting to; don't.

1. State the routing call out loud ("kit-template fix — editing the kit source, the
   kit dogfood, and this consumer's copy directly to byte-identical, no sync").
2. Edit the kit **source** (`_claude-project/…`) — the durable home; never skip it.
3. Mirror the SAME change into the kit's **dogfood** (`.claude/…`) when the file is
   dogfooded (check the manifest in `dev-kit-workflow.md`).
4. Edit the **consumer's** copy (`<project>/.claude/…`) directly to byte-identical —
   `cp` the source over it, or repeat the edit. NO `/sync-dev-kit`.
5. `diff` the copies to prove byte-identity. The kit-shared change and the
   project-side result land in ONE pass — never piecemeal, never "I'll update the
   kit separately later."

The durable home for kit-shared changes is editing the kit source directly.

**The other two surfaces work identically, with `~/.claude/` standing in for the
consumer's copy.** A `_claude-maintainer/` or `_claude-global/` change is edited
in the kit source and in `~/.claude/` in the same pass, `diff`ed to prove
byte-identity. Never leave it half-applied and tell the human to run an installer
— that is the same "I'll update the kit separately later" failure the step above
forbids, and it leaves the machine running instructions the kit no longer holds.

| Surface | Copies to edit in one pass |
|---|---|
| `_claude-project/…` | kit source · kit dogfood (if dogfooded) · every consumer's `.claude/…` |
| `_claude-maintainer/…` | kit source · `~/.claude/…` |
| `_claude-global/…` | kit source · `~/.claude/…` |

## Discipline

- Canonical files stay byte-identical across all consumers. Per-project variation
  goes ONLY through `sync-substitutions.json` placeholders or into
  `rules/project/**` — never by diverging a canonical file's content.
- Don't add a substitution/config surface without confirming the value actually
  varies across consumers. Hardcode the standard by default.
- Template-file sync conflicts (e.g. `ci.yml`: kit structure + project values) →
  hand-merge directly. Never present an A/B/C menu.
- The kit is a separate git repo. You edit its files, but you do NOT run its git
  — no commits, no pushes, no "want me to commit the kit?" Kit git belongs to the
  human maintainer, on their own schedule, same as every repo (see `git.md`).
