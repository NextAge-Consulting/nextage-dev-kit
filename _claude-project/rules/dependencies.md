# Dependency & Node Version Discipline (Zero Tolerance)

Applies to any project with a `package.json`. Both rules below protect the same thing: a lockfile that still matches what everyone else has.

## I. Install from the lockfile

**Use `npm ci` for every routine install.** It installs strictly from `package-lock.json`, errors out when `package.json` and the lockfile disagree, and never rewrites the lockfile.

Run `npm install <pkg>` or `npm install -D <pkg>` only when deliberately adding a dependency, and commit the `package.json` and `package-lock.json` delta as its own reviewable change.

**Bare `npm install` belongs only to the first install of a brand-new project that has no lockfile yet** — that is how the lockfile gets created, and `npm ci` cannot do it. In an established repo, bare `npm install` is free to re-serialize `package-lock.json`, and on a machine with a different node or npm version it will, breaking everyone else's install.

`hooks/npm-guard.sh` blocks bare `npm install` when a lockfile exists and allows it when there is none. `SKIP_NPM_GUARD=1` is the emergency override, user-authorized only.

Other package managers follow the same principle — install from the committed lockfile:

| Manager | Routine install |
|---------|-----------------|
| pnpm | `pnpm install --frozen-lockfile` |
| yarn (berry) | `yarn install --immutable` |
| yarn (classic) | `yarn install --frozen-lockfile` |
| bun | `bun install --frozen-lockfile` |

## II. Pin the node version

Every `package.json` project pins its node version, so every machine and CI runner resolves the same dependency tree. Version drift is what makes a bare install churn the lockfile in the first place. Add either file when it is missing rather than only reporting its absence.

- **`.nvmrc`** at the project root naming the version (e.g. `24.18.0`), which `nvm use` reads.
- **`engines.node`** in `package.json` as the machine-readable floor, so a wrong-version install warns — or fails, under `engine-strict`.

Keep the two in agreement and bump them together.

**The major is the kit's: `node.major` in `.claude/stack-manifest.json`.** `scripts/check-stack.mjs` fails when `.nvmrc`, the floor of `engines.node`, a Dockerfile's `node:` image or a workflow's `node-version` names another. Choose the exact version within that major, and install that line explicitly — `brew install node@<major>`, never bare `brew install node`, which tracks the newest release whatever its major.

## III. Install scripts are a decision to surface

npm lists packages whose install scripts are not covered by `allowScripts` at the end of every install. That list is a decision for the human, not a failure — today it is advisory and the scripts still run.

**Report it plainly**: "esbuild wants to run a setup script when it installs — approve or deny?" Treating the advisory as a broken build sends the human chasing a problem that does not exist.

Never bypass it with `--dangerously-allow-all-scripts`, and never approve silently: `allowScripts` is a security allowlist that ships in `package.json` to the whole team, so the human approves.

Approve pinned (`pkg@1.2.3: true`, the default) so a version bump re-surfaces the package for review — that re-prompt is the feature. Fold the approval into the `dependency-triage` skill's pass, which is where dependency bumps get reviewed anyway.

Run `npm approve-scripts --allow-scripts-pending` when an install surfaces the advisory, or during that triage pass, to see what is unreviewed without writing anything.

A future npm major blocks unapproved scripts outright, at which point an unpopulated `allowScripts` becomes a failed build.
