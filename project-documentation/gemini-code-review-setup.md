# Gemini Code Assist on GitHub — Setup

Sets up the Gemini Code Assist PR-review bot (`gemini-code-assist[bot]`) on a repo.

**Do the steps in order on a fresh project and this works first try.** Verified 2026-07-17 on
a brand-new project: billing linked + the three APIs enabled → the **Code Assist for Source
Code Management** card renders immediately. Nothing else is needed to reach the setup UI.

Three things — and ONLY these three — have ever broken this. All are invisible to `gcloud`:

**1. The bare Console URL.** Always paste
`agents-tools?project=$PROJECT`. Never the bare URL, never "select the project in the
picker" — the picker does not drive that page, and the resulting Marketplace redirect is
sticky and masquerades as a paywall. This has cost two multi-hour sessions. Full detail below;
read it before you touch the Console.

**2. The Enable Code Review agent toggle** (step 3), per connection. With it off, `gcloud`
reports `installationState: COMPLETE`, repos linked, and `fetchLinkableGitRepositories`
returning live results — while Gemini silently ignores every `/gemini review`. The toggle has
no `gcloud`, no REST, no Terraform surface, and **leaves no audit-log entry**. There is no way
to read its state except looking at the page.

**3. The `LINK` button below the fold.** In *Link Git repositories*, picking repos and
clicking **OK** only dismisses the multiselect — the **LINK** that submits sits at the bottom of
the side panel, off-screen on a short browser window. Nothing gets linked, and the
**Connections** tab shows a *Link repository* action either way, so it cannot tell you. Verify
on the **Repositories** tab. Full detail in step 2.

**The only trustworthy check is the 👀 reaction** (see Verify). If a trigger gets no eyeball,
stop testing config and go look at the toggle. Do not debug the connection — it is not the
connection.

## The two products — do not confuse them

| | Reached via | What it is |
|---|---|---|
| **Gemini Code Assist on GitHub** (what you want) | `console.cloud.google.com/gemini-code-assist/agents-tools?project=$PROJECT` | The PR-review bot. Preview. Needs billing + IAM. No seat purchase. |
| **Gemini Code Assist Enterprise** (not this) | Marketplace / Gemini admin pages | Per-seat licensed IDE product. Presents a paid upsell. |

Google's docs state these are "separate and distinct" products. Any Marketplace or
Gemini-admin URL lands on the seat-license product and dead-ends at an upsell that is
irrelevant to the review bot — buying nothing there changes nothing here.

### THE TRAP: never use the bare URL. Always paste `?project=`

This one thing has cost two multi-hour sessions across two projects. It is the whole problem.

| Do this | Never this |
|---|---|
| `console.cloud.google.com/gemini-code-assist/agents-tools?project=$PROJECT` | `console.cloud.google.com/gemini-code-assist/agents-tools` + pick the project |

**The project picker does not drive this page. The URL parameter does.** Open the bare URL and
the Console resolves it against a sticky session context. If that context is any project
without Gemini Code Assist provisioned, you are redirected to:

```
console.cloud.google.com/marketplace/product/google/cloudaicompanion.googleapis.com?project=...
```

— a "Gemini for Google Cloud" pricing page, no Code Assist card, no way forward. **It is not a
paywall.** There is nothing to buy. The upsell is for a different product entirely (see the
table above).

**The redirect is sticky, and this is what makes it eat hours:** once you land on it, switching
the project picker to the correct project does *not* recover. The bare URL keeps serving
Marketplace. It looks exactly like an entitlement wall on the correct project, so you go
hunting for a license, a billing fix, an API, an org policy — none of which are the problem.

**Escape:** paste the URL with `?project=$PROJECT` explicitly. The card renders immediately.
After that the bare URL also works, because the context is finally correct — which is the
"it magically started working" that ends every one of these sessions and teaches nothing.

Reproduced deliberately, 2026-07-17 (`<project>-codereview`, fully provisioned, card known
to render):

```
picker = unrelated project   → bare URL   → Marketplace
picker = <project>           → (no reload)→ Marketplace   ← picker does not fix it
picker = <project>           → bare URL   → Marketplace   ← still broken
                               ?project=  → CARD          ← the escape
                               bare URL   → CARD          ← now it "works"
```

**Corollary — do not trust a bare-URL success either.** It only worked because the context
happened to be right. Always pin the project; never tell anyone to "select the project."

## Prerequisites

- GCP project with a **billing account linked**.
- On that project: **Service Usage Admin** + **`roles/geminicodeassistmanagement.scmConnectionAdmin`**
  (or **Owner**). `scmConnectionAdmin` is **CLI-grant-only** — it is not offered in the Console UI:
  ```bash
  gcloud projects add-iam-policy-binding "$PROJECT" --member="user:$EMAIL" --role="roles/serviceusage.serviceUsageAdmin"
  gcloud projects add-iam-policy-binding "$PROJECT" --member="user:$EMAIL" --role="roles/geminicodeassistmanagement.scmConnectionAdmin"
  ```
  **A fresh IAM grant takes several minutes to propagate.** Until it lands, Developer Connect
  returns `permission_denied` on a role that is already correct. `roles/owner` does carry the
  Developer Connect permissions — verify with `gcloud iam roles describe roles/owner` rather
  than assuming the role is wrong. Wait and retry; do not start adding roles.
- You are a **GitHub Owner** of the org (required to install the App).
- `gcloud` and `gh` authenticated as you.

## Steps

### Naming — fixed, not a preference

Every value below is constrained. Deviating from any of them fails somewhere
non-obvious, usually several steps later.

| Value | Rule | Example |
|---|---|---|
| `PROJECT` id | **Name it for the CLIENT, never for the tool.** One per GitHub ORG, never per repo — a connection serves every repo in its org, so a second project buys nothing and splits the agent toggle across two places. | `acme-codereview` |
| `PROJECT` display name | The client, spelled out. | `Acme Code Review` |
| `CONN` | **Lowercase, digits and hyphens ONLY.** `^[a-z][a-z0-9-]*$` | `acme-code-review` |
| `REGION` | `us-east1` | `us-east1` |
| repo-link id | `$ORG-$REPO`, verbatim | `Acme-Inc-web-app` |

**Never name the project after the product** — `gemini-codereview`,
`gemi-code-review`, `code-review` and friends. You will run this setup once per
client, so those names collide in the project picker and in `gcloud projects
list`, where the only thing distinguishing them is the client you cannot see.
Identifying an unlabelled one afterwards means a billing-account lookup, and if
it belongs to a client you will not have permission to read that either.

**A project ID is permanent.** `gcloud projects update <ID> --name=<NAME>` changes
only the display name; there is no way to change the ID short of deleting the
project and starting over. Get it right at creation.

**Name the project for the client even when it is your own** — the point is that
every one of these projects is legible next to the others, and yours will be in
the same list.

**The connection name MUST be lowercase, and this is the trap that eats a whole
session.** Developer Connect **accepts** an uppercase name and drives it to
`installationState: COMPLETE`. Creation is not where this fails.

It fails at **step 3**, in *Enable Code Assist for Source Code Management* →
**Select a connection** → **Done**, which rejects the connection by name:

```
Failed to create the connection
The request was invalid: invalid SCMConnection resource name
```

**Read that message carefully, because it lies.** Nothing is being created — you
are binding the agent to an existing connection. The wording sends you off to
re-create a connection that was never the problem, and every retry produces
another duplicate. The only defect is uppercase in the name.

There is no rename. Delete the connection and create a lowercase one.

```bash
PROJECT=<gcp-project-id>; ORG=<github-org>; REPO=<repo>; REGION=us-east1
CONN=<lowercase-connection-name>   # ^[a-z][a-z0-9-]*$ — see the table above
gcloud config set project "$PROJECT"
```

### Exactly one connection per org. Never two.

Because the step-3 error blames creation, the reflex is to create another
connection. Do not. **List what exists before creating anything:**

```bash
gcloud developer-connect connections list --location="$REGION" --project="$PROJECT" \
  --format='value(name,installationState.stage)'
```

A second connection is not harmless. Both can reach `COMPLETE`, both can link the
same repos, and only one carries the agent toggle — so every CLI check reads green
while reviews never arrive. If you find more than one, delete all but the
lowercase one and re-link its repos.

**A duplicate can sit in another region, where the list command above will not find it.**
`--location` scopes the query, so a connection left behind in a different region by an earlier
attempt stays invisible while still breaking things. The Console's **Connections** tab lists
every region at once — use it, or repeat the list for each region an earlier attempt touched.

**Delete the repo links before the connection.** A connection with `gitRepositoryLink`
children cannot be deleted, and the Console greys the action out without saying why. Remove
each linked repo on **Git repositories → Repositories** first.

**Deleting a duplicate flips the agent toggle back to off.** The toggle binds to exactly one
connection; if it was bound to the one you just removed, Code Assist reads *not enabled* again.
That looks like the deletion broke something, when it only exposed that the toggle had been on
the wrong connection the whole time — which is also why reviews never arrived. **Always re-do
step 3 after removing a duplicate**, and expect the toggle to be off.

Connections in the same project also **share one OAuth secret**, named after
whichever connection was created first. Deleting that connection can take the
secret with it. Do not untangle this: tear the whole project down and rebuild.
Re-doing the OAuth takes two minutes and is the cheapest step in this document.

**1. Enable the three APIs:**
```bash
gcloud services enable \
  developerconnect.googleapis.com \
  cloudaicompanion.googleapis.com \
  geminicodeassistmanagement.googleapis.com --project="$PROJECT"
```

**1a. Confirm the card renders before going further** — this is the checkpoint that catches a
bad project early, while starting over is still cheap:

```
console.cloud.google.com/gemini-code-assist/agents-tools?project=$PROJECT
```

Expect the **Code Assist for Source Code Management** card with an **Enable** button.

If you get a Marketplace product page instead: you almost certainly used the bare URL — paste
the `?project=` one. If you genuinely used the pinned URL and still get Marketplace, step 1 has
not taken effect yet; wait a minute for API enablement to propagate and reload. Do not proceed
past this checkpoint, and do not start changing IAM, billing, or secrets to make the page
render — none of those have ever been the cause.

### Create the connection in the CONSOLE, not the CLI

`gcloud developer-connect connections create` works and is tempting — it puts the
name beyond typo range. **Do not use it.** A CLI-created connection is missing
state the Console sets, and the enable step in step 3 then fails with:

```
The request was invalid: failed to check developer_connect_connection existence:
generic::permission_denied: Permission 'developerconnect.connections.get' denied
on resource '//developerconnect.googleapis.com/projects/…/connections/…'
(or it may not exist)
```

**Retry the Enable once before concluding anything.** This same error also appears
transiently against a Console-created connection that is entirely correct —
`gitProxyConfig.enabled` set, `installationState: COMPLETE`, repos linked — and clears on a
retry minutes later with nothing changed. Observed 2026-08-24. The remedy below is to delete
the whole project, so spend two minutes on a retry first.

The resource exists and your IAM is fine — the message is misleading in the same
way step 3's other error is. The observable difference against a working
connection is `gitProxyConfig.enabled`, which the Console sets and the CLI leaves
unset unless you pass `--git-proxy-config-enabled`. Diff any suspect connection
against a known-good one:

```bash
gcloud developer-connect connections describe "$CONN" --location="$REGION" --project="$PROJECT" --format=yaml
```

Two service agents must also hold their roles on the project. They are created on
first use, so on a fresh project they can be absent when you need them — a
Console-driven setup grants them silently, a CLI-driven one does not:

| Service agent | Role |
|---|---|
| `service-<PROJECT_NUMBER>@gcp-sa-devconnect.iam.gserviceaccount.com` | `roles/developerconnect.serviceAgent` **and** `roles/secretmanager.admin` |
| `service-<PROJECT_NUMBER>@gcp-sa-geminicodeassistmp.iam.gserviceaccount.com` | `roles/geminicodeassistmanagement.serviceAgent` |

Without the Secret Manager grant, connection creation fails outright with
`SECRET_CREATE_PERMISSION_MISSING` — Developer Connect cannot store the OAuth
token. Check with:

```bash
gcloud projects get-iam-policy "$PROJECT" --flatten='bindings[].members' \
  --format='value(bindings.members,bindings.role)' | grep gcp-sa
```

**2. Create the connection + install the App** — in the Console:

`console.cloud.google.com/gemini-code-assist/agents-tools?project=$PROJECT`
→ **Code Assist for Source Code Management** card → **Enable**
→ **Select a connection** → **Create new connection**
→ Provider **GitHub** → Name = `$CONN` → **Continue** → **I understand and continue**
→ pick `$ORG` → select the repo (or all) → **Install** → finish GitHub auth
→ **Link repositories** → select repos → **Link**
→ back in **Select a connection**, choose `$CONN` → **Done**.

> **The `LINK` button is below the fold — maximize the window first.** In *Link Git
> repositories*, the repo multiselect's **OK** only closes the dropdown. The **LINK** that
> actually submits is at the bottom of the side panel, and on a short window it is off-screen
> with no scroll cue. The symptom is selecting every repo, clicking **OK**, and finding nothing
> linked — repeatedly. Maximize or zoom the browser out to 67% before you start.
>
> **Confirm on Git repositories → Repositories**, which lists the links themselves. The
> **Connections** tab carries a permanent *Link repository* action whether or not anything is
> linked, so it never distinguishes the two states.

> **If the flow stalls** (a sunsetting card appears, or the pane dead-ends): the OAuth token
> and App install are already saved and the connection sits at `PENDING_INSTALL_APP`. Finish
> it with steps 2a–2c, then **return to step 3 — it is not optional.**

**2a. Get the App installation id:**
```bash
gh api orgs/$ORG/installations --jq '.installations[] | select(.app_slug=="gemini-code-assist") | .id'
```

**2b. Attach it → moves the connection to `COMPLETE`:**
```bash
gcloud developer-connect connections update "$CONN" --location="$REGION" --project="$PROJECT" \
  --github-config-app-installation-id=<INSTALLATION_ID>
gcloud developer-connect connections describe "$CONN" --location="$REGION" --project="$PROJECT" \
  --format='value(installationState.stage)'   # expect: COMPLETE
```

**2c. Link the repo** (flag is `--clone-uri`, not `--remote-uri`):
```bash
gcloud developer-connect connections git-repository-links create "$REPO" \
  --connection="$CONN" --location="$REGION" --project="$PROJECT" \
  --clone-uri=https://github.com/$ORG/$REPO.git
```

**3. Enable the Code Review agent — the step that makes the bot respond:**

`console.cloud.google.com/gemini-code-assist/agents-tools?project=$PROJECT`
→ open `$CONN` → **Settings** tab:

| Control | Set to | Why |
|---|---|---|
| **Enable Code Review agent** | **ON** | Off = total silence on every trigger, with all CLI checks green. |
| **Comment Severity** | **Low** | Match `.gemini/config.yaml`'s `comment_severity_threshold: LOW`. **The Console defaults to Medium** — it will be wrong every time unless you change it. When the two disagree, findings are dropped with no signal. |
| **Improve response quality** (Preview) | **OFF** unless you decide otherwise | Stores inferred rules/facts from PR conversations in Google-managed storage. Review behavior is otherwise fully version-controlled in `.gemini/config.yaml`. |
| **Style Guide** tab | leave empty | The style guide lives in-repo at `.gemini/styleguide.md`, version-controlled and kit-synced. |

## Tear down and start clean

The path to a working install is narrow, and a part-built one is worse than
nothing: every CLI check reads green while the bot stays silent, so you debug
config that is already correct. **When anything is uncertain — a half-finished
attempt, an uppercase connection, two connections, an install from a previous
session — delete the whole GCP project and start at step 1.** Do not repair.

Deleting the project takes the connections, repo links and OAuth secrets with it
in one action, which is the only way to be sure no half-state survives:

```bash
gcloud projects delete "$PROJECT" --quiet     # recoverable for 30 days
```

Then **uninstall the GitHub App**, which the project deletion does NOT remove.
This is UI-only — the REST delete requires app-level auth and returns 404 for a
user token:

```bash
gh api /orgs/$ORG/installations --jq '.installations[] | select(.app_slug=="gemini-code-assist") | .id'
# then, in a browser:
open "https://github.com/organizations/$ORG/settings/installations/<ID>"   # -> Uninstall
```

Leaving the App installed while rebuilding is a known way to end up with a
connection bound to a stale installation.

## Verify

Comment **`/gemini review`** on a PR in the linked repo.

- **Within ~1 min**: `gemini-code-assist[bot]` adds an 👀 reaction **to your comment**. This
  is the only proof the trigger was received. No eyeball → the agent is not enabled for this
  connection; go back to step 3. Nothing else in the stack produces this symptom.
- **Within ~5 min**: a review summary + severity-tagged inline comments.

Check the ack without leaving the terminal:
```bash
gh api repos/$ORG/$REPO/issues/comments/<COMMENT_ID>/reactions --jq '.[] | "\(.content) by \(.user.login)"'
```

## Add another repo later

Re-run **step 2c** with the new `$REPO` against the same `$CONN`. The agent toggle is
per-connection, so it carries over — steps 1–3 do not repeat.

## Reference

- Setup: https://developers.google.com/gemini-code-assist/docs/set-up-code-assist-github
- Usage: https://developers.google.com/gemini-code-assist/docs/use-code-assist-github
- Per-repo review config: https://developers.google.com/gemini-code-assist/docs/customize-repo-review
