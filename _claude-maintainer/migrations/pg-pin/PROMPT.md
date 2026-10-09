# Migration: pin pg to the kit's blessed version

The maintainer pastes everything below the line into a consumer project's Claude session, on the maintainer machine, after `/sync-dev-kit` has landed the kit version whose `stack-manifest.json` blesses `pg`. A project that declares no `pg` dependency needs nothing.

---

Pin this project's `pg` to the version the kit blesses. Make no git commits — leave everything uncommitted for me to review.

1. Read the blessed version: `jq -r .packages.pg.version .claude/stack-manifest.json`.
2. In every `package.json` that declares `pg`, set it to exactly that version — no `^` or `~`.
3. Run `npm install` from the repository root, so `package-lock.json` resolves `pg` to it.
4. Run `node scripts/check-stack.mjs` and confirm it reports no `pg` finding.
5. Run `npm test` from the repository root and confirm the integration tier ran (`|integration|` files, tens of seconds) and passed: `pg` is the driver every database test goes through.
