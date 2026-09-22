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

> Note: `updateProjectV2Field` with options that have no `id` **regenerates all option ids** — fine on a fresh board. Capture the printed `{id,name}` for the next step.

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

**Turn off the board's "Pull request linked to issue" workflow.** It moves an issue's card when a PR links to it — the moment `/open-pr` writes `Closes #N` and sets Staged — so the two race and the card lands wherever the last one put it. Gitflow already sets Staged, earlier: when the issue is answered code complete. Board → **⋯** → **Workflows** → **Pull request linked to issue** → off.

## 4. Create views (UI — one per repo + a shared Staged)

Board: `github.com/orgs/<org>/projects/1`

All view config (layout, group, save) is under the **View** button (gear icon, top-right) — NOT the tab's ▾ arrow.

**Per-repo view:**
1. Double-click a tab name → rename to the repo/product.
2. Filter bar (top) → `-status:Done,Staged repo:<org>/<repo> -is:draft`. The work queue excludes Staged and the deploy status, and Done when it is a separate column — with a `Deployed` column that is `-status:Done,Staged,Deployed …`.
3. **View** (gear, top-right) → layout **Table**; **Group by** → **Parent issue**.
4. **View** (gear) → **Save changes**.

**Shared Staged view (once per board):**
1. **+ New view** → double-click → rename **Staged**.
2. Filter bar → `status:Staged -is:draft`; **View** gear → Table, Group by none.
3. **View** gear → **Save changes**.

**Deploy-status view (optional, once per board):** same steps with `status:<deploy column> -is:draft` — with QA, this is the list waiting for someone to check it in production.

Add a repo later = new tab, same per-repo filter with its repo name (e.g. a legacy app being converted gets its own tab). Only the per-repo view is repeated; the board, field, and Staged view are one-time.
