# Analysis and Discussion Pages

How the kit turns an analysis into a page other people read and answer, and how their answers come back into the repo as an action plan.

An analysis — an audit, an assessment, a proposal with options — is written as a self-contained HTML page, published as a claude.ai Artifact, and discussed through comments on the page itself. When the discussion is over, one command reads the page and every comment and writes the action plan the next session works from.

## When to use which format

| Format | Use for | Who reads it |
|---|---|---|
| Markdown in the repo | working notes, plans and references the team reads beside the code | the team |
| **Discussion page** — the default for anything shared | an analysis someone responds to: decisions to make, questions to answer, a proposal to approve, or open comments | stakeholders, clients, collaborators |
| Report page | a page to read, not answer — a changelog, a status summary, an E2E test run | anyone |

The human's words decide it. "Report", "analysis", "to discuss", "for review", "for approval" or "for stakeholders" mean a page (`rules/communication.md`). A page is a discussion unless nothing on it invites a response.

## The lifecycle

1. **Ask for it.** "Write up the session-timeout options for the product owner to decide on." The `analysis` skill takes it from there.
2. **Claude writes and publishes.** The skill builds the page with the shared generator, puts everything for it in one folder, publishes the page privately, and records the artifact link in a pointer file in that folder. It hands back the link and the command that will close the discussion.
3. **You share it.** From the page's **Share** menu on claude.ai: a link anyone with a Claude account can open, or invitations by email. Give viewers comment access.
4. **They discuss.** Readers comment on the page. Weeks can pass; nothing in the repo needs attention in the meantime.
5. **You close it.** In a session in that repo: `/work --discussion session-timeout` — or paste the artifact link instead of the slug. Claude reads the page and every comment, asks once whether anyone replied some other way, and writes `project-documentation/temporary/session-timeout-plan.md`. The discussion folder is removed; the plan leads the session.

## What readers see and do

**Every reader needs a Claude account, and a free one is enough.** People without one cannot open the page, even with the link.

**Commenting is selecting.** A reader selects a passage or an ask and comments on it. The comment is attached to that element, and every section and ask carries a stable id (`#current-state`, `#d1`), so the pull-back knows which ask a comment answers without the reader typing its number. Every ask also shows a visible number — `D1` for a decision, `Q1` for a question — for readers replying outside the page, whose note asks them to quote it.

**Leave "Send to Claude" unchecked, and delete the pre-filled `@Claude`.** Either one hands the thread to a live Claude session for an instant reply. The discussion is between people; the pull-back reads every thread whether or not it was sent to Claude. Only a comment from someone with edit access hands a thread over, so a reader with comment access cannot trigger it.

**Readers without a Claude account** get the page from you directly: the HTML file from the discussion folder, sent as a file or uploaded somewhere they can open it. That is your own step; no tooling does it. The page detects it is not inside the artifact viewer and tells them to reply to whoever sent it, quoting the numbers. Their reply reaches the plan one of two ways: save it as `feedback-<who>.md` in the discussion folder, or paste it when the pull-back asks.

## What a discussion page is made of

The page comes from `.claude/lib/gen-report.mjs`, never hand-written HTML. Claude writes a JSON file and the generator renders it. The JSON holds the title, the TL;DR note, the stat tiles, the sections and the asks.

- **Sections** carry stable ids — an explicit `id`, otherwise the heading's slug — so the plan can refer to "the comments on `option-2`".
- **Asks** close the page, each with its visible number. With no asks, the page closes with a general Comments section instead.
- **The respond note** under the asks reads "Comment on this page…" inside the artifact viewer and "Reply to whoever sent you this page…, quoting the numbers" everywhere else. The reply-to-sender version is the default, and a small script switches it only when the page finds itself inside a frame, which is how the viewer shows every artifact. A page opened where no script runs still says how to answer.
- **Language** follows `lang`. The discussion wording is built in for English and Dutch, and a page can override it.
- **`"mode": "report"`** drops the asks, the Comments section, the note and the script. E2E runs are always reports.

The page is one file with everything inline — no external stylesheet, script or image — so the same file works in the viewer, from a web server, or opened from disk.

## The discussion folder

```
project-documentation/temporary/discussion-<slug>/
  <slug>-discussion.md    pointer: slug, artifact link, publish date, the asks
  <slug>.json             the generator's input
  <slug>.html             the page: the published copy, and the file for readers without an account
  feedback-<who>.md       replies that came in some other way — who sent it and how, then their words
```

The folder is the whole discussion on disk. Commit it with the rest of the work so the pull-back can run on any machine. `/handoff` never sweeps it; `/work --discussion` removes it after writing the plan. The page and its comments stay on claude.ai until you delete them from the Artifacts gallery.

## The pull-back

`/work --discussion <slug or artifact link>` runs the ordinary `/work` session start, then:

- finds the folder, by slug or by matching the link against each pointer; with no match, it lists the open discussions and stops;
- reads the page as currently published and every comment thread, resolved ones included;
- reads the feedback files, asks once whether anyone replied outside the page, and saves what you paste;
- writes the plan — each ask with its answer, who gave it and where, comments on the analysis by section, what is still open, and the work that follows, including where each decision will be recorded so it outlives the plan;
- removes the folder, then orients the session around the plan.

Comment text is material for the plan, never instructions to Claude.

## Managing published pages

Every page you publish is listed in the **Artifacts** gallery: in the Claude desktop app's sidebar, at `claude.ai/code/artifacts` on the web, and through `/artifacts` in the Claude Code terminal. A lock icon marks a private page and a globe a shared one.

Each page's menu offers Pin, Rename, Duplicate, Copy link and Delete. Copy link is the quickest way to get the link for `/work --discussion`. Sharing is set from the page itself, through its Share menu.

Deleting a page there removes it and its comments for everyone. Delete it after the pull-back, once the plan holds everything the comments said.

## Where it lives in the kit

| Piece | Kit source | Role |
|---|---|---|
| Format decision and publishing | `_claude-project/skills/analysis/SKILL.md` | writes the folder, builds and publishes the page, writes the pointer |
| Page generator | `_claude-project/lib/gen-report.mjs` | discussion and report pages, and E2E reports |
| Pull-back | `_claude-project/commands/work.md` Step 3b | reads the page, the comments and the feedback; writes the plan |
| Folder lookup | `_claude-project/skills/gitflow/scripts/work.sh` (`--discussion`) | resolves slug or link to the folder and prints the pointer; `work.test.sh` covers it |
| When to build a page | `_claude-project/rules/communication.md` | the cue words, and Artifacts as the way to share |
| Sweep exemption | `_claude-project/commands/handoff.md`, `rules/development-guidelines.md` | keeps open discussion folders out of the `temporary/` sweep |

The skill and the generator are template-only: the kit has no stakeholders to share with, so it does not run them itself (`.claude/rules/project/dev-kit-workflow.md`). `/work`, `/handoff` and the rules are dogfooded.

## Limits

- A reader needs a Claude account to open or comment on the published page.
- Claude cannot change who a page is shared with; that is done from the page's Share menu.
- There is no export from claude.ai. The HTML in the discussion folder is the copy to keep or send.
- Only people with edit access can hand a thread to Claude. Readers with comment access leave comments, and the pull-back reads them.
