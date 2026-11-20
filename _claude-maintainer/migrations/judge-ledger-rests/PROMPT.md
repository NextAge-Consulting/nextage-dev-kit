# Migration: the judge's ledger drops the items placed on a file's first line

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version whose design judge rests a yes about rules on the sentences it quotes, and a yes about a whole component on the component's file. A project with no `.claude/ui-pending.json`, or none of the items below in it, needs nothing.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
jq '[.[] | select((.question | IN("RULE-REACH", "RULE-CONFLICT", "NAMED-FOR-DATA", "VARIANT-INCOMPLETE", "DUPLICATE-BLOCK", "SECOND-BLOCK")) and (.at | endswith(":1")) and (has("rests") | not))] | length' .claude/ui-pending.json 2>/dev/null || echo "no ledger"
jq 'length' .claude/ui-pending.json 2>/dev/null
```

The first number is the items it removes; the second, every item the ledger holds. `0` or `no ledger`: it does not apply. It edits `.claude/ui-pending.json` and nothing else.

---

Remove from this project's design-judge ledger the items placed on the first line of a file. Make no git commits — leave everything uncommitted for me to review.

Run every command from the repository root.

1. When `.claude/ui-pending.json` does not exist, report that the migration does not apply and stop.
2. List the items to remove, and keep the list for the report:

   ```bash
   jq -r '.[] | select((.question | IN("RULE-REACH", "RULE-CONFLICT", "NAMED-FOR-DATA", "VARIANT-INCOMPLETE", "DUPLICATE-BLOCK", "SECOND-BLOCK")) and (.at | endswith(":1")) and (has("rests") | not)) | "\(.question)  \(.at)  \(.about // "")  \(.quote | split("\n")[0])"' .claude/ui-pending.json
   ```

   None listed: report that and stop.
3. Remove them:

   ```bash
   jq '[.[] | select(((.question | IN("RULE-REACH", "RULE-CONFLICT", "NAMED-FOR-DATA", "VARIANT-INCOMPLETE", "DUPLICATE-BLOCK", "SECOND-BLOCK")) and (.at | endswith(":1")) and (has("rests") | not)) | not)]' .claude/ui-pending.json > .claude/ui-pending.json.tmp && mv .claude/ui-pending.json.tmp .claude/ui-pending.json
   ```

4. Run `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs` and keep its output.

Report each item removed, by question, file and quote; how many items the ledger holds now; and the status check's output. Say that each question is asked again when its rule or component next changes, that `/design-audit references` and `/design-audit components` ask them of every rule and component, and that a component still `pending` waits for the human's approval as before.
