# Dependency & Node Version Discipline (Zero Tolerance)

Applies to any project with a `package.json`. Two failures cause the same
damage — a lockfile that no longer matches what everyone else has — so both
are treated as critical errors.

## I. Install from the lockfile, never rewrite it by accident

**Default install command is `npm ci`.** It installs strictly from
`package-lock.json` and errors out if `package.json` and the lockfile
disagree. It NEVER silently rewrites the lockfile.

**`npm install` (with no package named) is forbidden in an established repo.**
Bare `npm install` is free to *rewrite* `package-lock.json`, and on a machine
with a different node/npm version it will — churning the committed lockfile and
breaking everyone else's install. That is exactly how a two-person shop ends up
with three different dependency trees.

| Command | When |
|---------|------|
| `npm ci` | Every routine install. Reads the lockfile, never edits it. |
| `npm install <pkg>` / `npm install -D <pkg>` | ONLY when deliberately adding a dependency. Commit the `package.json` + `package-lock.json` delta on purpose, as its own reviewable change. |
| bare `npm install` | ONLY the first install of a brand-new project that has no lockfile yet — this is how the lockfile gets created. `npm ci` can't do this (it requires an existing lockfile). |

**Enforced by `hooks/npm-guard.sh`** (PreToolUse). It blocks a bare
`npm install` when a `package-lock.json` already exists, and allows it when
there is none (the legitimate first install). Emergency override, user-authorized
only: prefix the command with `SKIP_NPM_GUARD=1`.

**Other package managers, same principle** — install from the committed
lockfile, don't let a routine install rewrite it:

| Manager | Routine install (lockfile-respecting) |
|---------|----------------------------------------|
| pnpm | `pnpm install --frozen-lockfile` |
| yarn (berry) | `yarn install --immutable` |
| yarn (classic) | `yarn install --frozen-lockfile` |
| bun | `bun install --frozen-lockfile` |

## II. Pin the node version

**Every `package.json` project MUST pin its node version** so everyone — and
every CI runner — resolves the same dependency tree. Version drift between
machines is what makes a bare `npm install` churn the lockfile in the first
place.

- **`.nvmrc`** at the project root naming the node version (e.g. `22.11.0`).
  `nvm use` reads it; contributors land on the same node.
- **`engines.node`** in `package.json` as the machine-readable floor, so a
  wrong-version install warns (or fails, with `engine-strict`).

Keep the two in agreement. Bump them together when you move node versions.

**Pick the version from Node's release schedule, not from what a package manager
hands you.** Homebrew's unversioned `node` formula (and most "install node"
defaults) tracks the *latest* release, which is a pre-LTS "Current" for six
months after each April cut. Pin to the **Active LTS** major and take the LTS
line explicitly (`brew install node@24`). The authority is
`https://raw.githubusercontent.com/nodejs/Release/main/schedule.json` — a major
is Active LTS when `lts <= today <= maintenance`.

## III. Install scripts are a decision to surface, not an error to fix

npm lists packages whose install scripts aren't covered by `allowScripts` at the
end of every install. That list is a **decision for the human**, not a failure.
Today it is advisory — the scripts still run, nothing is broken.

- **Report it plainly.** "esbuild wants to run a setup script when it installs —
  approve or deny?" Treating the advisory as a broken build sends the human
  chasing a problem that does not exist.
- **Never bypass it.** `--dangerously-allow-all-scripts` defeats the check
  entirely. Not yours to choose.
- **Never approve silently.** `allowScripts` is a security allowlist that ships
  in `package.json` to the whole team. The human approves.
- **Approve pinned** (`pkg@1.2.3: true` — the default). A version bump
  re-surfaces the package for review; that re-prompt IS the feature. Fold it
  into the Dependabot triage pass.

Run `npm approve-scripts --allow-scripts-pending` to see what's unreviewed
without writing anything.

A future npm major blocks unapproved scripts outright — an unpopulated
`allowScripts` stops being a warning and becomes a failed build.

## Why this rule exists

A bare `npm install` run on a machine with a different npm version
re-serializes `package-lock.json`, corrupting the committed lockfile and
causing downstream install failures across every other machine. The defense is
structural: `npm ci` by default (never rewrites the lockfile), a hook that
blocks the dangerous command, and a pinned node version so the trees match to
begin with.
