# Migration: the changelog becomes the project's own rule

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version where `/deploy` writes a changelog entry only by the project's `.claude/rules/project/changelog.md`. Every project that has no rule of its own receives one. A project that already has the rule has nothing to do.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
test -f .claude/rules/project/changelog.md && echo "rule present — does not apply" || echo "rule missing — writes .claude/rules/project/changelog.md"
git ls-files | grep -ix "changelog.md" || echo "no changelog file yet — the next /deploy creates it"
```

The first line decides it: "rule present" means it does not apply. Otherwise it writes the one rule file and touches nothing else; the second line only says which changelog file the rule will govern.

---

Give this project its own changelog rule, so `/deploy` writes a changelog entry at each release. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
MIG="$KIT/_claude-maintainer/migrations/changelog-project-rule"
```

## 1. Write the rule

1. If `.claude/rules/project/changelog.md` exists, stop: this project already owns its changelog rule.
2. `mkdir -p .claude/rules/project && cp "$MIG/changelog.md" .claude/rules/project/changelog.md`.

The rule is now the project's. Every release gets its own header carrying its version, a second release on the same day included; a release with only `chore`, dependency, tooling or other left-out commits gets no entry.

## 2. Prove it

- `head -5 .claude/rules/project/changelog.md` shows the `paths:` front matter naming `changelog.md`.
- `git status --short` shows the new rule file and nothing else from this migration.

## Report

- whether the rule was written or was already there;
- which changelog file it governs, or that the next `/deploy` creates one;
- that a team wanting a different audience, format or placement edits `.claude/rules/project/changelog.md` — it is theirs.
