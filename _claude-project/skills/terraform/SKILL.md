---
name: terraform
description: How AWS infrastructure is changed — always in the organization's org repo, never in a project repo. Use before ANY change to AWS resources (a bucket, a permission, a DNS record, a server, a load balancer, a deploy job), when a project needs infrastructure or something from another project, when a plan shows unexpected changes, when adopting resources built by hand, when setting up an org repo, and when writing the org or project infrastructure docs.
---

# Terraform

Every organization has one **org repo** per AWS account (`ORG_REPO` in `.claude/sync-substitutions.json`). It holds all of that account's Terraform, the ownership map, the register of what crosses between projects, and the infrastructure overview with one infra doc per project. Project repos hold no Terraform.

Paths in this skill — `scripts/`, `references/`, `templates/` — are inside `.claude/skills/terraform/`. Run the scripts from the repository root. `REPO_KIND` says which repo you are in: `org` is the org repo, anything else is a project.

## In a project repo

1. **Read `ORG_REPO`.** Missing, or empty and not in `_intentionally_empty`: stop and ask for it. Listed there: the project has no AWS — ask whether that has changed.
2. **Read the org repo's map** to see what exists and who owns it:
   ```bash
   gh api "repos/$(jq -r .ORG_REPO .claude/sync-substitutions.json)/contents/project-documentation/org-map.md" --jq .content | base64 -d
   ```
3. **File the need as an issue on the org repo** — `.claude/skills/gitflow/scripts/file-issue.sh --repo <ORG_REPO> --title … --body-file …`, which also puts it on the board — and stop that part of the work. The issue names the project, what its code needs (names, environments, permissions, the values it will read), why, and the project issue or branch it serves. A need for something another project owns — its API, its login, its data — is filed the same way, naming both projects.
4. **The project's PR carries `Needs <ORG_REPO>#N`** in its body. Its `/deploy` refuses until that change is live: the org PR merged, or a merged org PR that closes the issue — the org repo merges only after applying.

Never write Terraform, and never change AWS with the CLI, from a project repo. Reading AWS is fine (`cli-utilities.md`).

## In the org repo

The request arrives as an issue: `/work <N>`. While the org repo is first being set up, the work runs off its setup issue instead, and that issue is the record of everything setup does (`references/org-repo.md`).

**Before any change**, plan every root you will touch: `scripts/tf.sh <root> plan` must report `No changes.` Anything else means AWS was changed outside Terraform — tell the person what differs and on which resource, and let them decide whether the code or AWS is right before you add anything. A root that does not exist yet has nothing to plan; start it from `templates/root-main.tf.example`. When `tf.sh` prints `Sign in again: aws login --profile …`, hand the person that command with a leading `!` and end the turn.

**Layout** — every root under `infra/terraform/`:

| Root | Holds |
|---|---|
| `projects/<project>/<env>/` | What one project uses in one environment — its buckets, roles, users, deploy jobs, log groups, DNS records, and its additions onto shared resources |
| `projects/<project>/shared/` | What one project uses in every environment — its image repository, certificate, mail identity |
| `shared/` | What two or more projects use — a server they co-host, its load balancer and security groups, the network, a shared zone, the build connection |
| `legacy-<system>/` | One legacy system, adopted as it stands |
| `modules/<name>/` | Code roots share; never a root itself |

**Every root** uses the org's state bucket with the key `<root path>/terraform.tfstate`, pins the provider, refuses any account but `AWS_ACCOUNT_ID` (`allowed_account_ids`), tags everything through `default_tags` with `Project` and `ManagedBy`, and commits its `.terraform.lock.hcl`.

**Writing it:**
- A value another root owns comes from a data source by name or tag, or from a Parameter Store name the owning root publishes. Never `terraform_remote_state`.
- A value the project's code reads — a bucket name, a queue URL — is published as an `aws_ssm_parameter` under the project's own path, `/<project>/…`, which its env loader already reads. Every other Parameter Store value — anything a person sets, secret or not — is put in by the person and never written by Terraform.
- Create the environments the project already has; when the issue does not say and the project has more than one, ask.
- DNS is managed record by record with `aws_route53_record`; a shared zone is read with `data "aws_route53_zone"`.
- Write `terraform fmt`-clean code, then `scripts/tf.sh <root> validate`.
- In the same change, update the docs it affects, all under `project-documentation/`: `org-map.md` (owners, the cross-project register, cross-org grants), the project's `projects/<project>/infrastructure.md`, and the org `infrastructure-overview.md` (`references/docs.md`).

**Resources that overwrite each other across roots.** On anything another root or a person may also touch:

| Never | Instead |
|---|---|
| `ingress` / `egress` blocks inside `aws_security_group` | `aws_vpc_security_group_ingress_rule` / `_egress_rule`, one per rule |
| `aws_iam_policy_attachment` — exclusive across the whole account | `aws_iam_role_policy_attachment`, `_user_`, `_group_` |
| `inline_policy` / `managed_policy_arns` on `aws_iam_role` | `aws_iam_role_policy`, `aws_iam_role_policy_attachment` |
| A second `aws_s3_bucket_policy` on one bucket — each replaces the whole policy | One owner writes the bucket's policy |
| Changing a shared listener's `default_action` | `aws_lb_listener_rule` with a host or path condition, plus `aws_lb_listener_certificate` |
| `aws_route53_zone` on a shared zone, or `allow_overwrite` on a record | `aws_route53_record` per record |

**Ship it** — both on the person's word (`git.md`):
- `/open-pr` commits the work, plans every changed root, and opens the PR with each root's plan block and a plain-words summary — every destroy and replace on its own line (`commands/open-pr.md`).
- `/deploy` waits for green CI, applies only when each fresh plan matches the PR's, regenerates the reference, and merges. Typing it is the person's approval of the plan.
- Never run `apply` or `destroy` any other way.

**A cross-org grant** — another organization's project reaching into this account — is written here, in the org that owns the resource, and recorded in both orgs' maps.

## Unforeseen work

A person may change AWS directly with their own sign-in when the situation needs it — an incident, or something Terraform cannot yet express — and may direct you to run the CLI for it. Do it, then in the same session bring Terraform back to `No changes` through a PR in the org repo: write the change into the code, or import the new resource. A change outside Terraform by design (a Parameter Store value a person sets, an access key) gets a note saying what was done, by whom and why — on the setup issue during setup, otherwise on an issue on the org repo.

Never write to AWS with the CLI on your own initiative. Parameter Store values a person sets and access keys are always outside Terraform: the person runs `aws ssm put-parameter` or `aws iam create-access-key`, or directs you to; Terraform creates who may read them.

## Procedures

- Setting up an org repo, its state bucket and map, and adopting the whole account: `references/org-repo.md`.
- Adopting resources built by hand, moving resources between roots, moving a project's Terraform into the org repo: `references/adopting.md`.
- The org overview, the project infra docs and the generated reference: `references/docs.md`.
- The audit level (`ORG_AUDIT`, `ORG_DEPLOY_APPROVAL`) and the access-and-change procedure it requires: `references/org-repo.md`, `templates/infrastructure-access-and-change.md`.
