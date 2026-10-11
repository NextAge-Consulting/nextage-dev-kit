# Org Repo Cheat Sheet

One page for infrastructure work: asking for it from a project, and making it real in the
org repo. The role guide it belongs to is `devops-handbook.md`; the model behind it is
`infrastructure-terraform.md`. Everything not listed here works as in `gitflow-cheatsheet.md`.

---

## In a project that needs infrastructure

Say what the code needs — a bucket, a permission, a DNS record, another project's API.
Claude files it as an issue on the org repo and stops that part of the work.

- The project's PR names it: `Needs <org-repo>#N`.
- The project's `/deploy` refuses until that change is live in the org repo.

---

## In the org repo

```
/work <N>     # pick up the infrastructure request
/open-pr      # commit, plan every changed root, open the PR with the plans
/deploy       # make it real: apply the plans, then merge
```

**`/open-pr`** commits whatever is uncommitted (its prechecks run), plans each Terraform
root the branch changes, and opens the PR with each root's plan and a plain-words summary
of what is added, changed and destroyed. CI on the PR is the real gate.

**`/deploy`** runs on the PR's branch:

1. waits for CI to pass;
2. re-plans each changed root, and stops — applying nothing — if any plan no longer does
   exactly what the PR shows;
3. applies;
4. regenerates the infrastructure reference onto the PR;
5. merges. The org repo's main branch only ever holds what is live.

**`/merge` refuses** in an org repo: Terraform lands through `/deploy`.

---

## When `/deploy` stops

| It says | Meaning | Next |
|---|---|---|
| CI not green | A check failed on the PR | Fix it on the branch and push |
| A plan now differs from the PR | AWS changed, or another PR landed, since the PR was planned | Find out what changed, re-plan, update the PR's plan |
| Applying a root failed | The roots it names as applied are live; nothing merged | Fix forward on the same branch, `/deploy` again |
| No Terraform root changed | The PR is docs only | `/ship-main` |
