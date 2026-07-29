# Gemini Code Assist on GitHub — Setup

Sets up the Gemini Code Assist PR-review bot (`gemini-code-assist[bot]`) on a repo.

**Do the steps in order on a fresh project and this works first try.** Verified 2026-07-17 on
a brand-new project: billing linked + the three APIs enabled → the **Code Assist for Source
Code Management** card renders immediately. Nothing else is needed to reach the setup UI.

Two things — and ONLY these two — have ever broken this. Both are invisible to `gcloud`:

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
- You are a **GitHub Owner** of the org (required to install the App).
- `gcloud` and `gh` authenticated as you.

## Steps

```bash
PROJECT=<gcp-project-id>; ORG=<github-org>; REPO=<repo>; CONN=<connection-name>; REGION=us-east1
gcloud config set project "$PROJECT"
```

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

**2. Create the connection + install the App** — in the Console:

`console.cloud.google.com/gemini-code-assist/agents-tools?project=$PROJECT`
→ **Code Assist for Source Code Management** card → **Enable**
→ **Select a connection** → **Create new connection**
→ Provider **GitHub** → Name = `$CONN` → **Continue** → **I understand and continue**
→ pick `$ORG` → select the repo (or all) → **Install** → finish GitHub auth
→ **Link repositories** → select repos → **Link**
→ back in **Select a connection**, choose `$CONN` → **Done**.

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
| **Comment Severity** | **Low** | Match `.gemini/config.yaml`'s `comment_severity_threshold: LOW`. The Console defaults to Medium; when the two disagree, findings can be dropped without any signal. Setting both to Low removes the ambiguity. |
| **Improve response quality** (Preview) | **OFF** unless you decide otherwise | Stores inferred rules/facts from PR conversations in Google-managed storage. Review behavior is otherwise fully version-controlled in `.gemini/config.yaml`. |
| **Style Guide** tab | leave empty | The style guide lives in-repo at `.gemini/styleguide.md`, version-controlled and kit-synced. |

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
