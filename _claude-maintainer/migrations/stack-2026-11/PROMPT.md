# Migration: Better Auth 1.7.18 and the November pins

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the stack manifest blessed 2026-11-11 or later. A project that declares none of `better-auth`, `@tanstack/react-router` and `@tanstack/react-start` needs nothing; a project already at or above the manifest's version of each has only the Better Auth section to check.

## Estimate

Kind: asks for decisions — a sign-in by each method the app offers, checked in the running app
Your time: about 5 minutes for each app that configures Better Auth; none when no app does.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
M="$KIT/_claude-project/stack-manifest.json"
git ls-files '*package.json' | while IFS= read -r f; do jq -r --arg f "$f" --slurpfile m "$M" '[(.dependencies // {}), (.devDependencies // {})] | add // {} | to_entries[] | select(.key == "better-auth" or .key == "@tanstack/react-router" or .key == "@tanstack/react-start") | select($m[0].packages[.key].version != .value) | "\($f) \(.key) \(.value) -> \($m[0].packages[.key].version)"' "$f"; done
git grep -l 'betterAuth(' -- '*.ts' '*.tsx'
git grep -c -E 'phoneNumber\(|createAccessControl\(' -- '*.ts' '*.tsx'
```

The first list is every declared version that differs from the manifest's; one already newer than the manifest's stays where it is. The second names each auth config, one per app to check in the running app; none means the Better Auth section does not apply. The per-file counts are the phone-number and access-control setups the Better Auth section reads; none means it changes no code. Reach is the listed `package.json` files and the lockfile, plus, where a phone-number setup is counted, the calls that create a user.

---

Move this project onto the kit's November pins. Work through every section to the end. Make no git commits — leave everything uncommitted for me to review.

Run every command from the repository root, setting this in each shell:

```bash
M=.claude/stack-manifest.json
```

If `jq -e '.blessed_at >= "2026-11-11"' "$M"` fails, stop: the sync has not landed this kit version.

When no `package.json` declares `better-auth`, `@tanstack/react-router` or `@tanstack/react-start`, report that and stop.

An "app" is each workspace whose `package.json` has a `build` script.

## Baseline

Run `npm run check-types`, `npx biome lint`, `npm test`, and each app's `build` script. Keep each result, including the test count per vitest project and whether `|integration|` ran. A check that already fails here is fixed in this migration too.

## Versions

In every `package.json` that declares `better-auth`, `@tanstack/react-router` or `@tanstack/react-start` at a version older than the manifest's, set it to the manifest's version. A version already newer than the manifest's stays. Either way it is written without a range: a `^` or `~` comes off.

```bash
jq -r '.packages | to_entries[] | select(.key == "better-auth" or .key == "@tanstack/react-router" or .key == "@tanstack/react-start") | "\(.key) \(.value.version)"' "$M"
```

Set every declared `@better-auth/*` package to the `better-auth` version the project now declares. Run `npm install`, then `node scripts/check-stack.mjs` and `node scripts/check-dep-alignment.mjs`, and make both pass before going on.

## Better Auth

In each app that configures Better Auth:

1. Run the read-only schema check at the `better-auth` version the app now declares, against the app's auth config, and keep its output. It compares the configured schema, so a fix in the schema passes it without the migration being applied.

   ```bash
   npx --yes auth@<that version> check schema --cwd <app dir> --config <path to the auth config>
   ```

   Fix each mismatch it reports in the Drizzle schema, generate the migration with `drizzle-kit generate` (`.claude/rules/drizzle.md`), never apply it, and run the check again until it passes. Where the auth schema is not a Drizzle schema, report the mismatches instead.

2. Where the config uses the `phoneNumber` plugin: Better Auth refuses a sign-up or user creation whose request carries a phone number (`PHONE_NUMBER_CANNOT_BE_SET`). Find every call that creates a user, whatever it is named — `signUp.email`, `auth.api.signUpEmail`, `auth.api.createUser` and `admin.createUser` among them — and remove the phone number from what it sends, a spread object or shared payload type included. A user's number is set by the plugin's own `sendOtp` and `verify` calls; where a screen relied on creation storing it and has no such step, change nothing there and report the screen.
3. Where the config passes its own access control to the `admin` plugin (`admin({ ac, roles })`) and a role changes another user's phone number through `admin.updateUser`: add `set-phone` to that role's `user` statements, and to the `user` list given to `createAccessControl` when the project writes that list itself. A config using the plugin's default roles needs nothing.

## Prove it

Fix every failure in the code; never suppress one (constitution §XIII).

- `npm run check-types` passes.
- `npx biome lint` passes.
- `npm test` passes, with `|integration|` present whenever the baseline had it. A test that fails only because a migration generated above is unapplied is reported, not fixed.
- `node scripts/check-stack.mjs` and `node scripts/check-dep-alignment.mjs` pass.
- Each app's `build` script succeeds.
- Compare `git status` with the files you edited: report each new untracked path you did not create, and leave `.gitignore` alone.

## Report

- each version moved, per `package.json`, and each left because it was already newer;
- the schema check's output for each app, and any database migration generated, unapplied;
- each call changed in the Better Auth section, or that none applied;
- every check's result against the baseline;
- for me to verify in the running app, per app: a sign-in by each method it offers — password, a social provider, an emailed code, a texted code — then a sign-out; and where the app offers them, a sign-up and an email change;
- anything you could not resolve.
