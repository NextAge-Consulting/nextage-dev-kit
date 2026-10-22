# Migration: pin pg to the kit's blessed version

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version whose `stack-manifest.json` blesses `pg`. A project that declares no `pg` dependency needs nothing.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
jq -r .packages.pg.version "$KIT/_claude-project/stack-manifest.json"
git ls-files '*package.json' | xargs grep -H '"pg":'
```

Each `package.json` listed declares `pg`; one whose version differs from the first line is changed, along with the lockfile. None listed: it does not apply.

---

Pin this project's `pg` to the version the kit blesses. Make no git commits — leave everything uncommitted for me to review.

1. Read the blessed version: `jq -r .packages.pg.version .claude/stack-manifest.json`.
2. In every `package.json` that declares `pg`, set it to exactly that version — no `^` or `~`.
3. Run `npm install` from the repository root, so `package-lock.json` resolves `pg` to it.
4. Run `node scripts/check-stack.mjs` and confirm it reports no `pg` finding.
5. Run `npm test` from the repository root and confirm the integration tier ran (`|integration|` files, tens of seconds) and passed: `pg` is the driver every database test goes through.
