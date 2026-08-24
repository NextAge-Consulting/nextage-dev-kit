# Dependency Management — the monorepo "one stack" discipline

**What this is.** The hard-won discipline for keeping a multi-workspace (monorepo) JavaScript/TypeScript project on **one** coherent dependency stack, plus the CI gate that enforces it. Distilled from a real production outage (a 3-version `better-auth` skew across apps that no check caught) and the cleanup that followed.

**Who it's for.** Any Node consumer of the kit, especially monorepos with multiple apps/packages under `workspaces`. Single-package repos still get the gate (it's a guaranteed no-op pass for them) and still benefit from the trust-but-verify and verification-standard sections.

**The machinery this doc backs:**
- `scripts/check-dep-alignment.mjs` — the alignment gate (ships via `_claude-project/templates/scripts/`; HANDBOOK §11.16).
- the `dep-alignment` CI job in `ci.yml` (Node-gated; HANDBOOK §11.16).
- `npm run check:deps` — the local convenience script consumers add to `package.json`.

---

## 1. The core invariant — one version per shared dependency

A monorepo exists **because every workspace runs the same stack.** The entire value proposition is that there is never a "will this work in *this* app?" question. The moment a dependency is declared at two different versions across workspaces, that property is gone — you have "works in one app, breaks in another" failures that are brutal to diagnose because the symptom (a runtime crash in app B) is nowhere near the cause (a version bump in app A's manifest).

**Dependabot makes this worse, not better.** It bumps each manifest independently and has no concept of cross-app consistency, so it *creates* skew rather than catching it.

**The gate:** `scripts/check-dep-alignment.mjs` fails if any dependency is declared at more than one version across the workspaces. It reads `package.json` files only (no install), runs as the `dep-alignment` CI job on every PR, and is the check that would have caught the outage.

### When a dependency needs updating

Bump it to the **same version in every workspace that declares it**, in one change:

```bash
npm i pkg@X -w apps/foo -w apps/bar -w packages/shared   # every workspace that declares it
npm run check:deps                                        # must print ✓
# then build + verify (see §5)
```

Never bump one workspace and not the others — the gate will fail the PR. That failure is the feature.

---

## 2. Trust but verify — old workarounds are guilty until proven innocent

**The single most expensive lesson.** A dependency update that "physically can't be applied" is almost never the new dep's fault — it's usually an **old workaround masking the real problem**, treated as gospel ever since it was first guessed at.

Real example: months of running on a transitive-dependency override + an `ssr.noExternal` hack added in a panic to fix a production SSR crash — when the **actual** root cause was a package that was imported and used but never *declared* as a dependency. It rode transitive-resolution luck; a patch bump shifted that luck and the "crash" came back, and the instinct was to pile new hacks on the old ones.

**Rules:**
- **Old pins / overrides / `noExternal` / `resolutions` are guilty until proven innocent.** Before working *around* one, `git log -S '<the-config>'` it: when it was added, by whom, for what. A "fix … in Docker build" commit from months ago is a prime suspect, not scripture.
- **The real fix is usually "declare what you use," not another hack.** If app code imports X and uses X's API, X belongs in that app's `package.json` at the right major. Don't rely on hoisting / transitive resolution, and don't pin the *rest* of the tree around the gap.
- **Test whether each workaround is still needed:** remove it, clean-install, build + run the **real deploy image**, verify (§5). Works without it → delete it.
- **Verify on the DIVERGENT surface, not the convenient one.** If app A passes but app B carries extra config app A never had, app A passing proves nothing about app B. Build the app that actually differs.
- **Don't accept "it runs" as "it's clean."** A green build can be a pile of old cruft luckily cohering. After it runs, ask which pins/overrides/hacks are still earning their place, and drop the rest.

**The counter-lesson (equally important):** "removal proves deadness" holds ONLY when you build + run the real deploy image **and exercise the real path** (e.g. log in). A workaround that looks dead because the dev server boots fine can still be load-bearing for a production code path that loads lazily. Some `noExternal` / bundling config is the **canonical, documented** pattern for a library's SSR build (verify against the library's own docs via Ref before touching it) — removing it because "another app works without it" is how you cause the *next* outage. Prove deadness on the real image, on the real path, on the divergent app.

---

## 3. One shared build config

Put cross-cutting build policy — bundler plugins, SSR externalization rules (`ssr.noExternal`), shared compiler options — in **ONE** shared file that every workspace's config is a thin wrapper over. The way these drift is by being copied per-app and then edited in one place but not another. A single source means:
- **Do NOT** add a per-app override block that the shared config is supposed to own — that is exactly how they diverge.
- **Do NOT** remove a load-bearing entry because one app "works without it" — see §2's counter-lesson. Cite the source (library docs / issue) in the shared file so the next reader knows it's deliberate.

---

## 4. Solid-version philosophy — not bleeding-edge, not stale

Standardize on the newest version that is **vuln-free AND battle-tested**: roughly 2+ weeks of supply-chain bake, on a mature non-RC / non-canary line. Never a package released in the last few days; never a year-stale pin. Updates are deliberate and cited, applied across the board (§1), not one app at a time.

Watch for traps:
- **RC / canary lines** masquerading as "latest" (e.g. a `1.0-rc`, a `-canary`) — these are not the solid line.
- **Major bumps that are actually migrations**, not version bumps (e.g. a bundler swap under the hood). Treat them as a deliberate migration with its own verification, not a routine update.
- **Peer-dependency exclusions** — a plugin whose peer range excludes your framework's current major is a real defect; take the fixed major, don't pin your framework down to satisfy a stale plugin.

---

## 5. Verification standard — "logged-in," not "200 on a route"

A build is **NOT** proven until you:
1. Build the **real production image** (the deploy path — e.g. `npm ci --omit=dev`, the real Dockerfile), not a dev build.
2. Run it on the app's **native port**, with runtime env that matches production (e.g. an auth client's baked base URL must match the port you're hitting).
3. Complete a **real end-to-end exercise of the critical path** — for an authed app, a real login landing on an authed page; not a health-check ping.

**Why this bar.** "Server ready" in the log proves nothing — crypto / auth / native modules often load lazily *per request*, so a process can boot cleanly while every request 500s. The minimum server-side proof is a real POST to the auth endpoint returning a session; the full proof is a browser login. A route returning 200 is not the same as the feature working.

**Caveat:** do not run write-heavy E2E (checkout, registration) against a locally-run prod image if it points at the production database. Cover write paths with integration tests on ephemeral DB branches instead; use the prod image only for read/login verification.

---

## 6. Accepted security residuals — documented, not punted

After `npm audit fix` (which clears the genuinely-reachable transitives, including all HIGH) and any pinned `overrides`, some advisories may remain that npm can only "fix" with a breaking major **downgrade**, or that have no fix yet. For each one that is **dev/build/export-time only with no production-bundle exposure**, the correct action is to **dismiss the GitHub alert with a specific, written reason** — not leave it perpetually red, and not pile on hacks.

The discipline:
- **Prove non-reachability**, don't assert it. Name *why* the vulnerable code path can't be hit (e.g. "we never run the tool's `serve` mode; we only use it as a bundler," "the ID it generates is internal, not attacker-controlled," "not deployed on the affected OS").
- **Record the residual** in the project's dependency notes (and in a tracking issue if action is deferred), with the dismissal reason verbatim.
- **Revisit on update**, don't forget — if the residual exists only because an upstream hasn't shipped a patched transitive, note the trigger ("revisit when <pkg> updates").

Dismissing with a specific reason is the audit trail. "False positive" / "safe" with no specifics is not (constitution §XIII).

### Dependabot security updates are a separate toggle

A `dependabot.yml` group governs **version** updates. **Security** PRs are a *separate repo setting*: Settings → Code security → **Dependabot security updates**. A repo can have a perfectly good `dependabot.yml` and still open **zero** security PRs because that toggle is off. If an audit shows N auto-fixable advisories but no security PRs, check the toggle.

---

## 7. Cross-references

- **HANDBOOK §11.16** — the `dep-alignment` job + `scripts/check-dep-alignment.mjs` wiring and the `check:deps` convention.
- **HANDBOOK §11.10** — `dependabot.yml` (grouping / cooldown / monthly cadence).
- **HANDBOOK §11.6** — `dependabot-surfacing.yml`.
- **PIPELINE.md §1.4** — quality + security tools (where the gate sits in the pipeline).
- **constitution §X / §XIII** — fail-loud and suppression discipline (the gate fails loud; §6 residuals are the disciplined alternative to silent suppression).
