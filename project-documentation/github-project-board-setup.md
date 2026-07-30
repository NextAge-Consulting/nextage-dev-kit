# GitHub Project Board — Setup

One Projects v2 board per **org** (multiple repos feed it via per-repo views). gitflow drives the Status field: `/work`→In Progress, `/open-pr`→Staged, `/deploy`→Done.

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

## 2. Wire gitflow

Put the ids into the project's `.claude/sync-substitutions.json`, then re-apply the conf:
- `GITFLOW_PROJECT_ID` = the board id (`PVT_…`)
- `GITFLOW_STATUS_FIELD_ID` = the Status field id (`PVTSSF_…`)
- `GITFLOW_STATUS_IN_PROGRESS_ID` / `_STAGED_ID` / `_DONE_ID` = the matching option ids
- remove those keys from `_intentionally_empty`
```bash
~/.claude/scripts/sync-dev-kit.sh --apply-file _claude-project/gitflow-project.conf
```
Verify: `jq -r '.GITFLOW_PROJECT_ID, .GITFLOW_STATUS_FIELD_ID, .GITFLOW_STATUS_IN_PROGRESS_ID' .claude/sync-substitutions.json` returns all three IDs, and `.claude/gitflow-project.conf` carries the same values.

## 3. Create views (UI — one per repo + a shared Staged)

Board: `github.com/orgs/<org>/projects/1`

All view config (layout, group, save) is under the **View** button (gear icon, top-right) — NOT the tab's ▾ arrow.

**Per-repo view:**
1. Double-click a tab name → rename to the repo/product.
2. Filter bar (top) → `-status:Done,Staged repo:<org>/<repo> -is:draft`
3. **View** (gear, top-right) → layout **Table**; **Group by** → **Parent issue**.
4. **View** (gear) → **Save changes**.

**Shared Staged view (once per board):**
1. **+ New view** → double-click → rename **Staged**.
2. Filter bar → `status:Staged -is:draft`; **View** gear → Table, Group by none.
3. **View** gear → **Save changes**.

Add a repo later = new tab, same per-repo filter with its repo name (e.g. a legacy app being converted gets its own tab). Only the per-repo view is repeated; the board, field, and Staged view are one-time.
