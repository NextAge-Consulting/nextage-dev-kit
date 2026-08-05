# Constitution

<!--
WHAT BELONGS HERE: Critical rules with enforcement. Violations are CRITICAL ERRORS.
WHAT DOESN'T: Implementation tips, how-to guidance (those go in development-guidelines.md).
WHAT DOESN'T: Language-specific rules (those go in typescript-rules.md / python-rules.md,
              which auto-load via path targeting when editing matching files).
Rule of thumb: If hook-enforced or causes breakage, it's here. If it's guidance, it's not.
-->

Global, language-agnostic rules. Violations are critical errors.

Language-specific rules (TypeScript quality, Python quality, console.log vs print, framework patterns) live in `typescript-rules.md` (loaded for `**/*.{ts,tsx,mts,cts}`) and `python-rules.md` (loaded for `**/*.py`). Frontend-only rules (toasts, Tailwind, shadcn) live in `typescript-rules.md` since the current stack is TanStack + Astro.

## I. The Third-Party Library Rule

**Default assumption**: If something doesn't work, YOU ARE USING IT WRONG.

Before blaming any library:
1. Use **Ref MCP** to read official documentation
2. Search for GitHub issues or Stack Overflow confirming the bug
3. Only claim library bug if you find **multiple independent sources** documenting it

Never blame the library without proof. The fault is almost certainly in your code.

## II. Questions Before Code

**When asked a question, ANSWER IT FIRST.**

| Allowed | Forbidden |
|---------|-----------|
| Investigate codebase | Write code in response to question |
| Research (web, Ref, Exa) | Change code in response to question |
| Read/analyze files | Assume what code to write |

**Why?** Until the question is answered and user responds with direction, any code is guesswork.

**Exception**: User explicitly says "do it", "implement this", "fix that bug".

## III. Security

- Environment variables for all secrets. NEVER hardcode.
- Never overwrite env vars without explicit consent.
- No schema modifications (`DROP`, `ALTER`, `CREATE`) without approval.
- Error messages must not expose internal details.

## IV. Early Development Philosophy

**No backward compatibility.** Breaking changes preferred over technical debt.

- Complete replacement over gradual migration
- Drop deprecated code entirely after migration
- No compatibility layers
- Single source of truth

## V. Database & Naming

| Convention | Rule |
|------------|------|
| Tables | Singular (`user` not `users`) |
| Primary keys | `{table}id` (e.g., `userid`) using UUID v7 |
| Foreign keys | Match parent PK name |
| DB fields | `lowercase` |

**Entity names**: Use actual database names in code. `contact` not `prospect`.

Language-specific variable casing (camelCase vs snake_case, underscore rules) lives in the respective language rule file.

**AI restriction**: Migration commands (`db:generate`/`db:migrate`, never `db:push`) run ONLY with the human's explicit approval in the current conversation — approved runs are prefixed `SKIP_DB_GUARD=1` (hook-enforced default-deny). Autonomous sessions follow their standing authorization. The intent is human-gated schema change, not human-typed mechanics.

## VI. Timezone-Aware Code (Zero Tolerance)

**Every line of code that touches time MUST consider timezone.**

**Before writing ANY time-related code, ask**: "What timezone is this stored in? What timezone does the consumer expect?"

**Core principle**: If data is stored in local time, query logic MUST use the same local time. If data is stored in UTC, convert to local before user-facing display/filtering. Never mix conventions — match your query boundaries to your storage format.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| Getting current time without explicit tz | Naive/ambiguous timestamps | Always specify timezone explicitly |
| "Today" without tz in user-facing code | Server date ≠ user's date across tz boundaries | Derive from timezone-aware now |
| API queries with implicit "today" | API may use different tz than stored data | Pass explicit date in the correct tz |
| UTC query boundaries on local-time data | Creates mid-day cutoffs for non-UTC users | Query in the same tz the data was stored in |

**This applies to**: database queries, API calls, date filtering, log display, scheduling, status lines, summaries, check-ins — everything.

**Carve-out — absolute-instant audit fields**: `new Date()` (or the language equivalent) IS allowed for absolute-instant timestamp fields — session bookkeeping, audit columns like `createdat` / `updatedat`, internal trace IDs — that are NEVER displayed in user-facing UI AND NEVER filtered by local-tz query boundaries. These fields capture "the instant this row existed in the database" with no tz semantics whatsoever; converting or anchoring them to a tz adds confusion. The rule still catches every site that displays time to a user or filters by a local-tz date range — those are the bug surface, not audit-trail bookkeeping.

**Why this rule exists**: Mismatched timezone conventions between storage and query logic create silent mid-day cutoffs, showing users wrong data. This has caused repeated bugs across projects.

Language-specific syntax (`new Date()` vs `datetime.now(tz)`) in the respective rule files.

## VII. Debugging Protocol

**New code is guilty until proven innocent.**

1. **Assume recent changes broke it** - Check code from last session/PR first
2. **Trust stable infrastructure** - Production code (weeks old) is probably correct
3. **Reproduce** - Minimal reproduction case
4. **Isolate** - Identify failing component
5. **Root cause** - Trace to source, not symptoms
6. **Fix** - Implement with verification
7. **Defend** - Add test to prevent regression

## VIII. Code Standards

- Production code NEVER imports from `docs/`, `specs/`, `project-documentation/`.
- Test with real APIs, not mocks.
- Architecture separation: validation inline in production code, not imported from spec files.

Language/framework conventions live in the respective rule files.

## IX. LSP Tool Usage (requires per-language plugin)

**LSP is gated behind official Claude Code plugins.** The LSP tool only activates for a language after TWO things are set up:

1. The matching code-intelligence plugin is installed from the official marketplace:
   - TypeScript → `typescript-lsp@claude-plugins-official`
   - Python → `pyright-lsp@claude-plugins-official`
   - Swift → `swift-lsp@claude-plugins-official`
   - Others as the marketplace grows
2. The corresponding language server binary is on PATH:
   - `typescript-language-server` (installed via `npm i -g typescript typescript-language-server`)
   - `pyright-langserver` (installed via `npm i -g pyright` or `pip install pyright`)

**Verify both before relying on LSP.** If plugin OR binary is missing, LSP for that language silently does nothing — use the language CLI diagnostics instead. Per-language install steps live in the respective rule files.

| Operation | Use For |
|-----------|---------|
| `goToDefinition` | Find where symbol is defined |
| `findReferences` | Find all usages of a symbol |
| `hover` | Get type info and documentation |
| `documentSymbol` | List all symbols in a file |
| `workspaceSymbol` | Search symbols across codebase |
| `goToImplementation` | Find interface/protocol implementations |
| `incomingCalls` | Find callers of a function |
| `outgoingCalls` | Find functions called by a function |

**When to use LSP vs Grep:**
- **LSP (if connected)**: Type-aware queries ("what calls this function?", "what implements this interface?")
- **Grep (always works)**: Text pattern matching ("find all TODO comments", "find hardcoded strings")
- **Language CLI (always works)**: Diagnostics — `tsc`, `pyright`, `ruff`, etc.

**Diagnostic authority**: any diagnostic — LSP or CLI — is authoritative. CLI is the guaranteed path (it's also what pre-commit and CI run). Ignoring ANY reported diagnostic is a CRITICAL FAILURE. Language-specific forbidden-pattern tables (TS6133, F401, etc.) and CLI commands live in the respective rule files.

## X. Fail Fast, Fail Loud (Zero Tolerance)

**Every error MUST be visible to the user.** Silently swallowed errors are worse than crashes.

**Default mental model**: When writing any code that can fail, the FIRST question is "how will the user know this failed?" If the answer is "they won't" — the code is wrong.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| `onError` / error handler that sets state nobody reads | Silent failure | Ensure error state is always rendered |
| `catch` / `except` that only logs | User sees nothing | Re-throw or surface to UI |
| Error stored in variable with no UI | Dead error | Wire it to visible feedback |
| `try/catch` / `try/except` that returns default value | Masks the problem | Let it throw or show error state |
| Mutation error handlers that don't match display conditions | Error set but never shown | Verify the error rendering path end-to-end |

**When writing error handlers**: Trace the FULL path from error occurrence to user visibility. If any link in the chain is broken, the error is swallowed.

### Log AND show. Log-only is silent failure wearing a hat.

**The default for any user-affecting failure is BOTH: full detail to the log, a
general statement to the user.** Logging alone satisfies the developer and
leaves the user staring at a screen that looks fine and isn't — which is the
exact harm this section exists to prevent.

**Log-only is correct in one case:** the failure genuinely does not affect what
the user is doing or seeing, and interrupting them would be noise. If they would
act differently knowing, they get told.

**What the user sees is general. What the log holds is everything.** The message
names the system and the impact, never the cause: no error text, no status
codes, no key/token/credential state, no stack, no internal identifiers. Those
are operator information and leak internals (§III).

| Say this | Never this |
|---|---|
| "Couldn't reach QuickBooks, so the file list can't be shown." | "QuickBooks API returned 401: invalid client credentials" |
| "Trouble saving — your changes weren't applied." | "duplicate key value violates unique constraint" |
| "That upload didn't go through." | "S3 PutObject AccessDenied for bucket acme-prod-uploads" |

**An empty state is not an error state.** A failed lookup that renders as an
empty list tells the user the thing does not exist. Distinguish the two — a
missing certificate and an unreachable server look identical otherwise, and one
of those is a compliance problem.

**When reviewing code**: Look for `onError`, `catch`, `.catch()`, `except` — verify each one surfaces to the user, not just to logs or dead state.

## XI. Best Solution, Not Quick Solution (Zero Tolerance)

**ALWAYS implement the BEST, RIGHT, CORRECT solution. Never the quick or hacky one.**

When multiple approaches exist, invest the research to identify the canonical, officially-documented, future-proof path — then implement that. A hacky shortcut that works today becomes a landmine tomorrow.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| Quick fix without researching the proper approach | Creates tech debt, rots fast | Use Ref MCP, read official docs, find the canonical pattern |
| "It works, move on" when a better way exists | Shortcut accumulates cost | Implement the right way the first time |
| Picking a pattern because it's faster to type | Wrong primitive → permanent cost | Pick based on correctness, not keystrokes |
| Workaround without documenting it's a workaround | Future readers treat it as the intended design | Eliminate workarounds, don't normalize them |
| Steering away from a rewrite because it's "big" when the rewrite IS the correct end state | Hedging toward a smaller/"safer" change accretes the exact cost you're dodging | Lead with the correct end state and its real cost; verify any blocker claim against the code before using it to hedge |

**Why this rule exists**: Shop is 100% AI-dev. Hacky choices compound across thousands of future AI-driven changes. "Good enough" doesn't exist — either it's correct or it's broken.

## XII. Own All Errors, No Stepping Over Landmines (Zero Tolerance)

**If you see an error, broken test, LSP diagnostic, lint warning, or any other defect during your work — you own it.** It does not matter whether your changes caused it. Reporting "this existed before my changes" and moving on is the single most forbidden behavior in this codebase.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| "This error was pre-existing, not my change" | User IS the next guy. Stepped-over landmines compound. | Fix it, or explicitly surface it with a proposal to fix |
| Ignoring failing tests unrelated to current work | Tests stay broken forever | Fix the test or the code it covers; never skip |
| Ignoring LSP / lint errors in files you touched | You validated the file as touched — you own what it reports | Resolve every diagnostic before claiming done |
| Leaving a half-finished state "for next session" | Landmine for the next actor (which may be you) | Finish or document explicitly as TODO with owner + date |
| "This failure doesn't affect my change" | Often false; even when true, rot spreads | Fix in the same PR or open a separate PR immediately |

**Rule of thumb**: if your work surfaced the issue — even accidentally — you are the one who fixes it. The codebase must never be worse after your session than before.

**Why this rule exists**: Pete is ALWAYS the next guy. Every stepped-over error lands on his desk later with context lost. This is the most-violated rule and the most costly.

## XIII. Suppression Discipline (Zero Tolerance)

**A linter suppression comment is the option of LAST resort. Before writing one, prove no cheap real fix exists.**

Lint rules catch real problems. Silencing them with `// biome-ignore`, `// nosemgrep`, `// eslint-disable`, `// @ts-ignore`, `// @ts-expect-error`, or per-file top-level disables IS a live admission that you've kept the rule's target behavior in the codebase. AI tends to default to suppression because it's the fastest path to a green CI; that default is wrong.

**The checklist BEFORE adding any suppression comment:**

1. **Is there a cheap refactor that eliminates the flag?** Often a 2–10 line change makes the rule pass without suppression. Examples seen on this codebase:
   - `<style dangerouslySetInnerHTML={{__html: css}} />` → `<style>{css}</style>` (React accepts string children; rule stops firing).
   - `<div onClick>` with document-level Escape listener → full-screen `<button>` as backdrop sibling (real keyboard a11y; rule stops firing).
   - `key={i}` on a list without an id → surface the DB id (`orderpackageid`) through the query → use it as key.
   - `process.env.FOO!` → `if (!foo) throw new Error("…")` guard (explicit error; rule stops firing).
2. **Is there a primitive-level fix?** If the rule keeps firing across many call sites, fix the primitive once: shadcn `Button` defaulting `type="button"` eliminates every downstream `useButtonType` hit.
3. **Does the rule legitimately not apply to this site?** Only after #1 and #2 are ruled out does suppression become the right answer.
4. **If you DO suppress, the comment must name the specific reason** — not "false positive", not "legacy code". Specific: "input passed through sanitizeHtml", "admin-only diagnostic table; row click is enhancement", "drizzle-kit bootstrap after dotenv.config".

| Forbidden | Why | Fix |
|-----------|-----|-----|
| Suppress without trying the cheap refactor first | AI's default shortcut; compounds across thousands of edits | Apply the refactor. Only suppress if refactor is real engineering cost. |
| Suppression comment saying "false positive" / "not applicable" / "safe" with no specifics | Future reader can't verify the claim | Name the exact mechanism that makes the rule's concern irrelevant at this site |
| Project-wide rule downgrade because many sites fail it | Loses the signal for NEW code | Fix the primitive, fix the sites, or use CLI `--exclude-rule` with a written project-level audit |
| Copy-pasting a `biome-ignore` from one site to another without re-auditing | Suppression reason may not apply | Each suppression is per-site. Copy the code; re-prove the reason. |

**Why this rule exists**: E4 landed with ~20 inline suppressions applied by AI without user review. Half had cheap real fixes (critical-CSS `<style>` child, button-as-backdrop, `orderpackageid` key) that the AI didn't consider because suppressing was faster. Suppression-first is a smell even when each individual comment is technically correct.

## XIV. Signature Changes: Compiler First, Evidence for the Blind Spots (Zero Tolerance)

**When you change the shape of an exported or cross-module symbol, every caller MUST be reconciled in the same change. The diff is incomplete until they are.** What follows exists to make that reconciliation *real and verifiable* — not a ritual sentence in the PR body.

### The measure is the compiler, not a self-reported count

For any signature change the type system can SEE — a TS/TSX function signature, an exported type/interface/enum, a Zod schema consumed as a TS type — **the compiler IS the caller scan.** A caller left on the old shape does not type-check, full stop. So the attestation for these is the type-check itself:

> `Signature changes: type-checked clean — the compiler reconciles every type-visible caller.`

Do **NOT** write per-symbol `N references across M files` lines for type-visible changes. That count is unfalsifiable — grepping hit-counts proves nothing was verified — it adds nothing the compiler didn't already guarantee, and treating "the line is present" as satisfaction is exactly how this rule rots into theater. `npm run check-types` (or the project's type gate) green IS the scan.

### Evidence is required only where the compiler is BLIND

The type system cannot see these seams. Here a signature change can compile green while a caller silently breaks at runtime — this is the real bug surface, and the only place the manual scan has teeth:

- **DB / schema / Zod FIELD renames or removals** referenced by string key (`row.oldName`, drizzle column refs, `select({ oldName })`, `.orderBy(oldName)`).
- **Raw-SQL column / table names** — string literals inside `sql\`…\``, plus field names carried in JSON / JSONB blobs.
- **String-keyed dispatch** — event names, action-type strings, dynamic property access (`obj[key]`), route-path strings, TanStack query-key arrays.
- **Cross-process / RPC / serverFn / webhook payload shapes** where producer and consumer type-check *independently* — a serverFn `{ data }` shape read by a client that imports no shared type; a webhook body; a queue message; a cross-app fetch.
- **Cross-language boundaries** — e.g. a Python worker reading a column a TS migration just renamed.

For a change at one of these seams, the attestation MUST **enumerate the actual call sites as `file:line`** — auditable evidence, not a number:

> `Callers scanned: <symbol> → apps/x/foo.ts:42, apps/y/bar.ts:88 (compiler-blind: raw-SQL column rename).`

An enumerated site that isn't in the diff (or doesn't reference the symbol) is a *detectable* false claim; a count is not. Zero external callers still gets a line, with the file: `Callers scanned: <symbol> → 0 callers (compiler-blind; private to apps/x/foo.ts).`

### Required protocol

1. **Type-visible change** → run the project type-check. Green is the attestation. Nothing per-symbol.
2. **Compiler-blind seam change** → `grep -rn` / ripgrep the string across the WHOLE repo, including non-TS consumers (`.sql`, `.py`, config, other apps), reconcile each, and enumerate them `file:line` in the PR body.
3. A caller that genuinely can't be reconciled in this PR gets a `// TODO(signature-mismatch): <why>, PR #N` and a line in the PR body. Never a silent break.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| Per-symbol `N references across M files` line for a type-visible change | Unfalsifiable count the compiler already proved; ritual invites lip-service | Attest the type-check once; drop the count |
| Rename a DB column / Zod field / string key and rely on "tsc passed" | The compiler is BLIND to string seams — it compiles green and breaks at runtime | Grep the string repo-wide + enumerate callers `file:line` |
| Enumerate `file:line` sites you did not actually open | The point is verification, not a longer sentence | List only sites you reconciled; the list is auditable against the diff |
| "I'll fix the callers in a follow-up PR" | Main breaks until then; reviewer can't tell | Reconcile in-PR or mark `// TODO(signature-mismatch)` |

**Why this rule changed (2026-07):** the prior version demanded a per-symbol `Callers scanned: X → N references across M files` line for *every* signature change. In a TypeScript repo that count is redundant with the compiler for type-visible changes and unfalsifiable everywhere — satisfiable by grepping hit-counts without opening a single caller, which both Claude and the PR reviewer then box-checked as done. Measuring "attestation string present" instead of "verification happened" is the defect. The rule now defers to the compiler where the compiler has teeth, and demands auditable `file:line` evidence only at the seams the compiler cannot see: cheaper where it was redundant, un-gameable where it actually matters.

## XV. Documentation Is Present-Tense, No Tombstones (Zero Tolerance)

**Reference and operational docs describe ONLY what is true right now. When you remove or change something, scrub every reference to ZERO — never downgrade it to a note about what the thing WAS, what REPLACED it, or that it was deleted/retired/deprecated.**

**Default mental model**: a doc is a *snapshot of the current system*, not its diff log. Before writing any sentence that names a workflow, script, field, flag, or pattern, ask: "does this exist and behave this way *today*?" If no — the sentence does not belong; delete it, don't tombstone it. History lives in `changelog.md` and git.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| "the old `X` has been deleted / retired / removed" | Names a dead thing; a skimmer (AI or human) reads the name as live and acts on it | Delete the mention entirely; describe only the current mechanism |
| "this replaced the previous `Y`" / "formerly `Z`" / "used to use `W`" | Anchors the reader to superseded design as if it were context they need | State what the thing does now, with zero lineage |
| "`A` no longer does `B`" | Same tombstone in softer words — still surfaces the dead behavior | Describe the current behavior; omit the past one |
| Keeping a removed feature's section "for reference / just in case" | Reference docs are not archives | Cut it. Git history is the archive. |
| Documenting a feature that isn't built yet as if it's live behavior | A reader acts on a capability that doesn't exist | Describe only what exists today; mark planned/deferred work explicitly as not-yet-built |

**Why AI makes this expensive**: speed-reading a doc, any named artifact is assumed CURRENT. "The old `update-env.yml` has been deleted" reads as *"update-env.yml exists"* on a fast pass — a tombstone actively resurrects the dead concept as a live one. Silence is strictly safer than a "was removed" note.

**The one carve-out — self-documenting decision records.** A doc whose *purpose* is to explain a decision's evolution legitimately carries history: this constitution's own "Why this rule changed" notes, an ADR, a `changelog.md`, a "deferred work" spec. There, the history IS the current content. Everywhere else — operational runbooks, architecture, setup, pipeline, API/reference docs — present-tense only.

**Why this rule exists**: 2026-07 — a stale-doc audit deleted `update-env.yml` and the rollback script, but the rewrite sprayed "has been deleted" / "this replaced the old …" tombstones across the DevOps docs; on the next read those lines parse as current behavior. The rule already existed — as a single teeth-less bullet in `development-guidelines.md` ("Only include current state, not historical decisions") — buried in a list and routinely sailed past. Promoted here with teeth: **scrub to zero, not to a tombstone.**
