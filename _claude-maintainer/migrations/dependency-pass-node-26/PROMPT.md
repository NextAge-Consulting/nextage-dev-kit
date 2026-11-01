# Migration: dependency updates through the dependency pass, and Node 26

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version whose `stack-manifest.json` names Node major 26 and whose `dependency-policy.md` carries an `alerts` region. It applies to every project with a `package.json`; a project with none still closes its open Dependabot PRs and answers the alerts question, and skips the Node steps.

## Estimate

Kind: asks for decisions — whether this project turns GitHub's vulnerability alerts on
Your time: 2 minutes for the alerts decision; 2 minutes per exception to approve, when the audit finds a vulnerability with no fix

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
echo "open Dependabot PRs: $(gh pr list --author app/dependabot --state open --json number --jq length)"
echo "Node pins on another major than $(jq -r .node.major "$KIT/_claude-project/stack-manifest.json"):"
grep -nE '^FROM .*node:[0-9]+' Dockerfile* apps/*/Dockerfile* 2>/dev/null | grep -vE "node:$(jq -r .node.major "$KIT/_claude-project/stack-manifest.json")\b"
cat .nvmrc 2>/dev/null; jq -r '.engines.node // "no engines.node"' package.json 2>/dev/null
grep -rn 'nodejs: [0-9]' infra/ 2>/dev/null
find . -name 'buildspec*.y*ml' -not -path '*/node_modules/*' | while IFS= read -r f; do
  if ! grep -q 'nodejs:' "$f" && grep -qE '(^|[[:space:];&|(])(npm|npx|node)[[:space:]]' "$f"; then echo "$f: runs Node with no nodejs runtime"; fi
done
npm audit --json 2>/dev/null | jq -r '.metadata.vulnerabilities // "no npm audit"'
```

The PR count is what gets closed; every line in the Node block is a pin that moves; the audit totals size the exceptions conversation. No `package.json`: only the PRs and the alerts question apply.

---

Move this project's dependency updates onto the dependency pass, and the project onto Node 26. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
MAJOR=$(jq -r .node.major "$KIT/_claude-project/stack-manifest.json")
```

## 1. Close the Dependabot PRs

The kit schedules no Dependabot updates — the sync removed `.github/dependabot.yml` — and an update a Dependabot PR proposes lands through the dependency pass. Close each open one with a comment naming that:

```bash
gh pr list --author app/dependabot --state open --json number --jq '.[].number' |
  while read -r n; do gh pr close "$n" --comment "Dependency updates land through the dependency pass (project-documentation/dependency-policy.md)."; done
```

List each closed PR and what it proposed, so the first dependency pass can take what is still wanted.

## 2. Decide the alerts

Read me the "Vulnerability alerts" section of `project-documentation/dependency-policy.md` and ask whether this project turns GitHub's vulnerability alerts on — for a project that must show continuous monitoring, such as an ISO 27001 audit or a client's security review, it is on. Wait for the answer.

- **On**: an admin enables **Dependabot alerts** and leaves **Dependabot security updates** off, under Settings → Code security. Ask me to do it, or run `gh api -X PUT repos/{owner}/{repo}/vulnerability-alerts` when this session's token is an admin's, then confirm with `gh api repos/{owner}/{repo}/vulnerability-alerts` (204).
- Either way, set the policy's `alerts` region to the answer: `Alerts: **on**` or `Alerts: **off**`.

## 3. Bring the policy's project content across

The sync wrote the kit's new text around this project's regions. Read the whole file, then:

- Move anything in `project-notes` that describes acting on Dependabot PRs onto the dependency pass, or delete it where the kit text now says it.
- Run `npm audit --json`. For each high or critical vulnerability with **no** fix, propose a row for the `exceptions` region — the `GHSA-…` id from `via[].url`, the package, why it cannot be fixed now, and a review date inside the policy's window — and ask me who approves it. Write only rows I approve, with the approver I name.
- Add to the `build-graph` region any package this project's build depends on that the kit's list does not name — a CSS pipeline, a second framework.

## 4. Move to Node `$MAJOR`

The kit moves every project to Node's Active LTS at once. In this project:

1. **The exact version** for `.nvmrc`: the newest `$MAJOR.x` release past its cooldown — published at least 3 days ago for a patch release, 7 for a minor:
   ```bash
   curl -s https://nodejs.org/download/release/index.json | jq -r --arg m "v$MAJOR." '.[] | select(.version|startswith($m)) | "\(.version) \(.date)"' | head
   ```
2. Write it to `.nvmrc`, and make the root `engines.node` `">=<that version> <$((MAJOR+1))"`.
3. Every Dockerfile's `node:` image moves to `node:$MAJOR-…`, keeping its variant (`-bookworm-slim` and the like).
4. Every buildspec that names `runtime-versions: nodejs:` moves to `nodejs: $MAJOR`. A buildspec that runs `npm`, `npx` or `node` with no `nodejs:` entry gets `nodejs: $MAJOR` under `phases.install.runtime-versions`.
5. The workflows' `node-version` arrived with the sync; check a project-owned workflow too: `grep -rn 'node-version' .github/workflows`.
6. Install the major on this machine as its own keg, `brew install node@$MAJOR`, and run the steps below with it first on `PATH` (`export PATH="$(brew --prefix node@$MAJOR)/bin:$PATH"`). Never bare `brew install node`. Installing it can upgrade a library the current default Node links against: run `node --version` afterwards, and on a `Library not loaded` error, `brew reinstall node@<the default major>`. Tell me that switching my default Node is mine to do (`brew link --overwrite node@$MAJOR`), and that other projects move when they sync.

## 5. Prove it

- `npm ci` succeeds, and `node scripts/check-stack.mjs` reports Node `$MAJOR` in `.nvmrc`, engines, every Dockerfile, every buildspec and every workflow.
- The full suite passes (`NO_COLOR=1 npm test`), with the integration project running.
- Every Dockerfile builds: `docker build -f <Dockerfile> .`. For the heaviest app, run its image on its native port and complete a real sign-in (`dependency-management.md` §5).

## Report

- each Dependabot PR closed, and what it proposed;
- the alerts decision, and whether alerts are on;
- each exception proposed, approved or not;
- the Node version chosen, each pin moved, and each check's result;
- anything you could not resolve.
