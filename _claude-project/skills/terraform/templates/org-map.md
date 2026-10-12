# <Org> — org map

Who owns every resource in this organization's AWS account, and what crosses between
its projects. Every project session reads this before asking for infrastructure, so it
stays current: an owner, a dependency or a grant changes in the same change as the code
behind it.

## The account

| | |
|---|---|
| Account | `<account id>` (`<account alias>`) |
| Regions | `<region>`, plus `us-east-1` for global services |
| CLI profile | `<profile>` |
| State bucket | `<org>-tfstate-<account id>` in `<region>` — one key per root, `<root path>/terraform.tfstate` |

## Projects

| Project | Repo | Name prefix | Roots | Infra doc |
|---|---|---|---|---|
| <project> | `<owner>/<repo>` | `<prefix>-` | `projects/<project>/shared`, `…/test`, `…/prod` | `projects/<project>/infrastructure.md` |

A resource named with a project's prefix belongs to that project. A project with nothing in the account is not listed.

## Shared

Owned by the `shared` root. Projects attach to them with resources of their own and never
change them.

| Resource | Used by | Published as |
|---|---|---|
| | | |

## Between projects

One project relying on another — an API, a login, data. The owner is the project whose
change could break the other.

| From | To | What | Credential, and where it lives | Owner |
|---|---|---|---|---|
| | | | | |

## Across organizations

| Direction | Other org's project | What | Granted in | Owner |
|---|---|---|---|---|
| | | | | |

## Legacy systems

| System | Root | What it is | Still in use |
|---|---|---|---|
| | `legacy-<system>` | | |

## Not adopted

| Resource | Why |
|---|---|
| The state bucket | Terraform needs it before it can run |
| The operator role the hub assumes, and its trust policy | A bad apply would lock everyone out |
| The account owner's people's sign-in identities, and the root user | The account owner manages its own people |
| Parameter Store values a person sets, and access keys | Terraform stores what it sets in plain text |
| The default VPC, its subnets and security group, service-linked roles, AWS-managed policies | Created by AWS; read with data sources |
| Resource Explorer indexes and views | Account tooling, not part of any system |

## Inventory

Every resource found in the account, with its owner: a project, `shared`,
`legacy:<system>`, or `not adopted`.

| Type | Name or id | Region | Owner |
|---|---|---|---|
| | | | |
