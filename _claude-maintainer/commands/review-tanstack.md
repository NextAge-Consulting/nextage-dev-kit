# /review-tanstack

Maintainer-only review of the kit's TanStack standard: are the blessed versions
still right, have the vendored reference docs drifted, and is there upstream
content we should now be carrying.

**This is the ONLY way the TanStack manifest changes.** A consumer project never
bumps a version to make its build pass — `scripts/check-tanstack.mjs` fails there
by design, and the fix is a kit decision made here.

## When to invoke

The user types `/review-tanstack`, or says "review tanstack", "check for tanstack
updates", "what's new in tanstack since we pinned". Run it when there is time to
act on the answer — it produces judgment calls, not a notification.

**Never invoke proactively.** Never invoke it from a consumer project session to
work around a failing `tanstack-standard` CI job.

## Modes

| Invocation | Does |
|---|---|
| `/review-tanstack` | Full pass: versions, watch entries, vendored-doc drift, unvendored upstream skills |
| `/review-tanstack --check-updates` | Versions + watch only. Fast — no tarball downloads |

## Procedure

### Step 1: Gather

```bash
~/.claude/scripts/review-tanstack.sh            # or --check-updates
```

Emits JSON: `versions`, `watch`, `vendored_drift`, `unvendored_skills`. The script
decides nothing — everything below is your judgment on its output.

If it exits 4, the kit path or manifest is missing; surface the message and stop.

### Step 2: Versions — recommend, do not auto-bump

For every entry with `status: "behind"`, work out whether the gap is worth taking.
Read the upstream changelog or releases for the range; do not guess from version
numbers.

State for each: what changed, whether it touches how **we** use the library, and
whether any of our house guidance or a vendored reference goes stale as a result.
"Router moved 1.170.21 → 1.172.4; three changes touch loader behaviour, two are
covered by `router-data-loading.md`, the third needs a line in SKILL.md §1" is
useful. "A new version exists" is not.

Remember what a bump costs: **lockstep is absolute**, so every project upgrades
together. A bump is an N-project event, and the projects most affected may not be
the one the user is sitting in.

Present the recommendation and **wait**. The user decides. Only then edit
`_claude-project/tanstack-manifest.json` — and update `blessed_at` in the same
edit, since a pin without a date reads as accidental six weeks later.

### Step 3: Watch entries

`watch` records things we are deliberately waiting on. For each with
`published: true`, the wait is over — say so explicitly and carry out the
`action` recorded in the manifest.

The live one: **`@tanstack/query-intent`**. TanStack/query PR #10879 adds 29 Query
skills in that new package. When it publishes, most hand-written Query content in
`SKILL.md` and `references/tanstack-query.md` becomes redundant and should be
replaced by vendored references. That is the single largest maintenance win
available, because Query is currently the only major area with no upstream to
sync from — so flag it loudly rather than noting it in passing.

### Step 4: Vendored drift

| Status | Meaning | Action |
|---|---|---|
| `clean` | Our copy matches upstream at the blessed version | Nothing |
| `drift` | Content differs | Almost always a hand-edit of a vendored file, which is forbidden. Re-vendor and move the house content into `SKILL.md` or a house reference |
| `missing-upstream` | The skill is gone from the package at that version | Upstream restructured. Decide: re-point the manifest at the new path, or drop the reference |
| `missing-local` | The manifest names a file we do not have | Re-vendor it |

Re-vendoring means copying the upstream `SKILL.md` over our copy, re-applying the
provenance header (source package@version, vendor date) and rewriting upstream
relative links to this folder's flat filenames. Then mirror to every consumer per
the maintainer propagation rules.

### Step 5: Unvendored upstream skills

Skills present upstream that the manifest does not carry.

**Check `references_rejected` in the manifest first.** Anything matching an entry
there was already decided against, with the reason recorded — do not re-raise it.
That includes every `migrate-*` skill: migrations are one-offs, and `SKILL.md`
already tells a session where to read one.

Anything NOT matching an entry is genuinely undecided, and gets a conscious call:

- **Vendor it** — add to `references`, vendor the file, add any new cross-link
  targets to `link_rewrites`.
- **Reject it** — add to `references_rejected` with the reason, and say what would
  change the answer ("revisit when we adopt virtualised lists").

Silence is the failure mode. An upstream skill that is neither vendored nor
recorded as rejected comes back as undecided on every future review, and the
repeat noise is what buries a genuinely new one.

### Step 6: Propagate

Any change here touches the kit source AND every consumer, in ONE pass, per
`kit-maintainer.md`:

- `_claude-project/tanstack-manifest.json`
- `_claude-project/skills/mfing-bible-of-tanstack/**`
- each consumer's `.claude/` copies of both

The bible skill is **template-only** — the kit does not dogfood it (kit has no
TanStack code), so do NOT mirror into the kit's own `.claude/`.

`diff` the copies to prove byte-identity. Do not run `/sync-dev-kit` as the
propagation step, and do not commit — kit git belongs to the human.

### Step 7: Report

- Versions: current vs behind, with the recommendation and its blast radius
- Watch entries that fired
- Drift resolved, or drift found and left (say which, and why)
- Unvendored skills accepted or rejected, each with a reason
- Whether `blessed_at` moved

If nothing needs doing, say that in one line. A review that finds nothing is a
good outcome, not a reason to manufacture work.
