# GitHub Project Board — Setup

One Projects v2 board per **org** (multiple repos feed it via per-repo views). gitflow drives the Status field:

| Status | Set by |
|---|---|
| In Progress | `/work <N>` |
| Staged (code complete, waiting for deployment) | `/commit` or `/ship-main` for each issue you answer code complete; `/open-pr` for every linked issue |
| the deploy status | `/deploy`, for every issue named by `Closes #N` in the commits since the last tag |

The deploy status is whichever column the project picks — `Done`, or a separate `Deployed` when QA happens after deployment (§1). `/merge` moves nothing.

gitflow always writes `Closes #N` — it is the history, and it is how `/deploy` finds what shipped. gitflow never closes an issue. Whether one closes is GitHub configuration (§3).

Board + Status field are scriptable via CLI. **Views are UI-only** — GitHub's API can't create or configure them.

## 1. Create the board + Status field (CLI)

```bash
ORG=<github-org>; REPO=<repo>

# Board
OWNER_ID=$(gh api graphql -f query='{ organization(login:"'"$ORG"'"){ id } }' --jq '.data.organization.id')
PID=$(gh api graphql -f query='mutation($o:ID!){ createProjectV2(input:{ownerId:$o,title:"Projects"}){ projectV2{ id } } }' \
  -f o="$OWNER_ID" --jq '.data.createProjectV2.projectV2.id')

# The board ships a default Status field (Todo/In Progress/Done). Get its id, then
# UPDATE it to add "Staged" (don't create a second Status field — name collision).
# Want QA after deployment? Add a "Deployed" option between Staged and Done (see below).
FID=$(gh api graphql -f query='query($id:ID!){ node(id:$id){ ... on ProjectV2 { field(name:"Status"){ ... on ProjectV2SingleSelectField { id } } } } }' \
  -f id="$PID" --jq '.data.node.field.id')

gh api graphql -f query='
mutation($fid: ID!) {
  updateProjectV2Field(input: {
    fieldId: $fid
    singleSelectOptions: [
      { name: "Todo",        color: GREEN,  description: "This item hasn'"'"'t been started" }
      { name: "In Progress", color: YELLOW, description: "This is actively being worked on" }
      { name: "Staged",      color: RED,    description: "Completed Waiting for Deployment" }
      { name: "Done",        color: PURPLE, description: "This has been completed" }
    ]
  }) { projectV2Field { ... on ProjectV2SingleSelectField { id options { id name } } } }
}' -f fid="$FID" --jq '.data.updateProjectV2Field.projectV2Field.options'

# Link the repo to the board
gh project link 1 --owner "$ORG" --repo "$REPO"
```

> Note: `updateProjectV2Field` with options that have no `id` **regenerates all option ids** — fine on a fresh board. Capture the printed `{id,name}` for the next step. On a board projects are already wired to, pass each existing option's `id` (`{ id: "…", name: "Staged", … }`) and leave it off only the new one: the existing ids, and every card's status, are kept.

**The deploy column.** `/deploy` moves shipped issues to one column. With no QA step that column is `Done`. When a person checks the work in production before it counts as finished, add a separate option after Staged and point gitflow at it instead:

```
      { name: "Deployed",    color: BLUE,   description: "Shipped, waiting for QA" }
```

## 2. Wire gitflow

Put the ids into the project's `.claude/sync-substitutions.json`, then re-apply the conf:
- `GITFLOW_PROJECT_ID` = the board id (`PVT_…`)
- `GITFLOW_STATUS_FIELD_ID` = the Status field id (`PVTSSF_…`)
- `GITFLOW_STATUS_IN_PROGRESS_ID` / `_STAGED_ID` = the matching option ids
- `GITFLOW_STATUS_DEPLOYED_ID` = the deploy column's option id (`Done`, or `Deployed`)
- remove those keys from `_intentionally_empty`

With `GITFLOW_PROJECT_ID` set, all four other keys are required: an empty one fails the command that needs it, loudly — it never skips. Empty `GITFLOW_PROJECT_ID` means no board; issue links, the code-complete question and the `Closes #N` lines all still work.
```bash
~/.claude/scripts/sync-dev-kit.sh --apply-file _claude-project/gitflow-project.conf
```
Verify: `jq -r '.GITFLOW_PROJECT_ID, .GITFLOW_STATUS_FIELD_ID, .GITFLOW_STATUS_IN_PROGRESS_ID, .GITFLOW_STATUS_STAGED_ID, .GITFLOW_STATUS_DEPLOYED_ID' .claude/sync-substitutions.json` returns all five IDs, and `.claude/gitflow-project.conf` carries the same values.

## 3. Decide who closes issues (UI)

Two settings decide whether an issue closes. Both are UI-only — neither REST nor GraphQL exposes them.

1. **Repository auto-close.** Repository → **Settings** → **General** → **Issues** → **Auto-close issues with merged linked pull requests**. On by default. Turning it off stops closing from both a merged PR's `Closes #N` and a `Closes #N` in a commit pushed straight to the default branch (`/ship-main`).
2. **Board auto-close.** Board → **⋯** → **Workflows** → **Auto-close issue** → *When the status is updated* → **Status: `<column>`** → *Close the issue*. Works on the free plan, on any column you choose, and fires when gitflow sets the status through the API.

Pick one way of working per repository:

| Way of working | Repository auto-close | Board "Auto-close issue" |
|---|---|---|
| No board | on (default) | — |
| Board with QA — a person closes the issue by moving it to Done | off | on → Done |
| Board without QA | off | on → the deploy status |

With QA, the deploy status is the separate `Deployed` column, so an issue waits there until a person moves it to Done. Without QA, the deploy status is usually `Done` itself.

**Turn off the board's "Pull request linked to issue" workflow.** It moves an issue's card when a PR links to it — the moment `/open-pr` writes `Closes #N` and sets Staged — so the two race and the card lands wherever the last one put it. Gitflow already sets Staged, earlier: when the issue is answered code complete. Board → **⋯** → **Workflows** → **Pull request linked to issue** → off. GitHub requires a status value before it saves the workflow even while it is off: set **Staged** — the status gitflow sets at that moment — so the card lands in the same place if the workflow is ever switched back on.

## 4. Create views (UI — one per repo, plus shared Staged, Deployed and Done)

Board: `github.com/orgs/<org>/projects/<N>`

All view config is under the **View** button (gear icon, top-right) — NOT the tab's ▾ arrow. Every view uses the same settings, and differs only in its fields and filter:

- **View** gear → layout **Table**, **Group by** none, **Show hierarchy** on (sub-issues nest under their parent and collapse, in one list), **Show agent sessions** on.
- Finish each view with **View** gear → **Save changes**.

**Per-repo view** — the work queue for one repository:

1. Double-click a tab name → rename to the repo/product.
2. **Fields:** Title, Assignees, Status, Linked pull requests. Leave Parent issue off; the hierarchy already shows it.
3. **Filter:** `-status:Done,Staged,Deployed repo:<org>/<repo> -is:draft,closed`

**Shared views** — one each per board, across every repo. **+ New view**, rename it, then:

| View | Filter |
|---|---|
| Staged | `status:Staged -is:draft,closed` |
| Deployed | `status:Deployed -is:draft,closed` |
| Done | `status:Done OR is:closed` |

**Fields** for all three: Title, Assignees, Status, Labels, Linked pull requests, Repository.

The Deployed view is the QA queue: shipped, waiting for someone to check it in production. A repository with no deploy step never puts anything there.

Add a repo later = a new per-repo tab with its repo name in the filter (e.g. a legacy app being converted gets its own tab). The board, the Status field and the shared views are one-time.
