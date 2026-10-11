# Infrastructure access and change — <Org>

How the infrastructure in this organization's AWS account is reached and changed, and
the record each change leaves. All of it is changed through this repository, the org
repo; the projects `org-map.md` lists hold none of it. It does not cover the account
owner's own people and their access, which the account owner manages.

## Who can change the infrastructure

- **Named people only**, each signing in as themselves with multi-factor
  authentication: <names and roles>.
- **Each person's role sessions carry their name** (`role_session_name` in their AWS
  profile), so every action in CloudTrail names the person who took it.
- **The AI assistant holds no AWS credential of its own.** It acts only inside the
  session of the person directing it, with that person's permissions, and the session
  expires within the hour.
- **Machine identities are narrow and fixed**: each deploy key may start only its own
  project's named build projects, and holds nothing else. They are created and
  rotated by a person; their values never enter Terraform or a repository.

## Planned change

1. The need is raised as an issue on this repository — by a project, or by a person.
2. The change is written as Terraform on a branch, with the docs it affects.
3. A pull request carries the code, a plan for every part it changes produced against
   the live account, and a plain-words summary of what is added, changed and destroyed.
   CI checks the code.
4. A named person reads the plan and runs `/deploy`. It applies only when a fresh plan
   does exactly what the pull request shows, and stops otherwise.
5. The generated infrastructure reference is regenerated from the new live state and
   added to the pull request, which then merges — so the main branch only ever holds
   what is live.

Before any change, the affected part is planned first. A difference nobody made through
this procedure is reported and resolved before new work is added on top of it.

## Unplanned change

When a situation needs AWS changed directly — an incident, or something Terraform
cannot yet express — a named person makes the change with their own sign-in. In the
same working session the change is written back into Terraform, through a pull request
here, until a plan shows no difference. A change that stays outside Terraform by design
(a Parameter Store value a person sets, an access key) is recorded as an issue on this repository, saying what
was done, by whom and why.

## What is kept outside Terraform

Parameter Store values a person sets and access keys, the bucket holding Terraform's state, the role the
operators assume and its trust, the account owner's people's identities, and what AWS
creates itself. `org-map.md` lists each, with its reason.

## The record

| Evidence | Where |
|---|---|
| What was asked for, and by which project | Issues on this repository |
| What changed, the plan that was approved, and who applied it | Pull requests and commits in this repository |
| What exists now | The generated infrastructure reference in this repository |
| Who did what in AWS, when | CloudTrail, with each person's named sessions |
| Every previous version of the infrastructure's state | The state bucket's object versions |

## Controls this supports

A mapping to ISO/IEC 27001:2022 Annex A, for whoever prepares an audit. It describes
this procedure's contribution; it is not a statement of conformity.

| Control | How |
|---|---|
| 5.15 Access control, 5.18 Access rights | Named people only; the AI holds no credential of its own |
| 8.2 Privileged access rights | Change rights tied to a person's own sign-in; machine identities limited to starting named builds |
| 8.5 Secure authentication | Multi-factor sign-in; temporary role sessions |
| 8.9 Configuration management | The whole configuration is code, reviewed and versioned |
| 8.15 Logging | CloudTrail with named sessions; state versions; repository history |
| 8.32 Change management | Planned change through a reviewed plan, applied only as approved; unplanned change written back and recorded |
