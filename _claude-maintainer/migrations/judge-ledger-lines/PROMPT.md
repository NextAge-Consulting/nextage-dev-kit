# Migration: the judge's ledger names the line each item is about

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version whose design judge places a screen's item on the changed line it quotes. A project with no `.claude/ui-pending.json`, or none of the items below in it, needs nothing.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
jq '[.[] | select(.question == "FOLLOWS-RULE" and (.at | endswith(":1")) and .fingerprint == "e3b0c442")] | length' .claude/ui-pending.json 2>/dev/null || echo "no ledger"
jq 'length' .claude/ui-pending.json 2>/dev/null
```

The first number is the items it removes; the second, every item the ledger holds. `0` or `no ledger`: it does not apply. It edits `.claude/ui-pending.json` and nothing else.

---

Remove from this project's design-judge ledger the screen items that name no line. Make no git commits — leave everything uncommitted for me to review.

Run every command from the repository root.

1. When `.claude/ui-pending.json` does not exist, report that the migration does not apply and stop.
2. List the items to remove, and keep the list for the report:

   ```bash
   jq -r '.[] | select(.question == "FOLLOWS-RULE" and (.at | endswith(":1")) and .fingerprint == "e3b0c442") | "\(.at)  \(.quote)"' .claude/ui-pending.json
   ```

   None listed: report that and stop.
3. Remove them:

   ```bash
   jq '[.[] | select((.question == "FOLLOWS-RULE" and (.at | endswith(":1")) and .fingerprint == "e3b0c442") | not)]' .claude/ui-pending.json > .claude/ui-pending.json.tmp && mv .claude/ui-pending.json.tmp .claude/ui-pending.json
   ```

4. Run `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs` and keep its output.

Report each item removed, by file and quote; how many items the ledger holds now; and the status check's output. Say that a screen is asked the question again when its code next changes, and that `/design-audit screens` asks it of every screen.
