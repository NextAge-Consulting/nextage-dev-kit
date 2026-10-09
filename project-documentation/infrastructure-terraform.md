# Infrastructure as code with Terraform

For whoever builds or takes over a kit project's AWS infrastructure, and the Claude
session walking them through it. `infrastructure.md` describes the standard shape; this
is how to own that shape as Terraform instead of console clicks and CLI commands. Read
`infrastructure.md` first — nothing here changes what gets built, only how.

## Why bother

A hand-built box drifts. A setting made once in the console — an instance metadata hop
limit, a log retention, a firewall rule — is forgotten the day the box is rebuilt, and the
rebuild fails in a way nothing connects back to it. Two environments built by hand (Test
and Prod) diverge silently from the first day. And "who may reach what" exists only as
console state nobody reviews.

Terraform makes the infrastructure a reviewed file. A rebuild is one command, Test and
Prod come from one definition, and every permission is written down where an auditor can
read it.

## The rules that make it work

- **Claude writes the code and runs `plan`; a person reads the plan and runs `apply`.**
  Never the other way round, and never an `apply` nobody read.
- **Nothing is changed in the console.** A hand edit shows up as drift on the next plan
  and is undone by the next apply. Reading the console is fine.
- **No secret values in Terraform.** Everything Terraform sets is stored in plain text
  in its state. Parameter Store values are put in with `aws ssm put-parameter`; Terraform
  creates the paths' readers, not the values. Access keys are created with
  `aws iam create-access-key` for the same reason.
- **One state per environment**, plus one for what both share. A mistake in Test's code
  cannot plan a change to Prod.

## Layout

```
infra/terraform/
  tf.sh                    the only way to run terraform here (credentials, below)
  README.md                the commands, the state bucket, how to reach a server
  shared/                  what both environments use: certificate, mail identity,
                           image registry, the DNS records that belong to neither
  test/                    the Test environment and the build that deploys to it
  prod/                    the Prod environment, its promotion, its backup
  modules/environment/     one environment: server, firewall, load balancer, roles, logs
```

`test/` and `prod/` call the same module with their own names and paths. The difference
between Test and Prod is then a handful of arguments, and reviewing it is reading them.

Each root pins the provider (`~> 6.0`), commits its `.terraform.lock.hcl`, and refuses any
account but its own:

```hcl
provider "aws" {
  region              = "<region>"
  allowed_account_ids = ["<account id>"]
}
```

`.terraform/` (the provider binaries, hundreds of MB per root) is gitignored; the lock
files are not.

## The state bucket

Created once by hand, because Terraform needs it before it can store anything:

```bash
B=<project>-tfstate-<account id>
aws s3api create-bucket --bucket $B --create-bucket-configuration LocationConstraint=<region>
aws s3api put-public-access-block --bucket $B --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket $B --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket $B --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
```

plus a bucket policy refusing non-TLS requests. Each root's backend names a key in it and
uses S3's own locking — no DynamoDB table:

```hcl
backend "s3" {
  bucket       = "<project>-tfstate-<account id>"
  key          = "test/terraform.tfstate"
  region       = "<region>"
  encrypt      = true
  use_lockfile = true
}
```

Versioning is the recovery path for a damaged state: restore the previous object version.

## Credentials: `tf.sh`

The AWS provider cannot read the session `aws login` creates, so a profile that
authenticates that way fails with an error about the profile's source. `tf.sh` exports
the profile's temporary credentials into its own process and runs Terraform:

```bash
#!/bin/bash
set -euo pipefail
ROOT="${1:?usage: tf.sh <shared|test|prod> <terraform args...>}"; shift
DIR="$(cd "$(dirname "$0")" && pwd)/$ROOT"
[ -d "$DIR" ] || { echo "tf.sh: no Terraform root at $DIR"; exit 2; }
if ! CREDS="$(aws configure export-credentials --profile <profile> --format env 2>&1)"; then
  echo "tf.sh: could not get credentials: $CREDS"; exit 1
fi
eval "$CREDS"
exec terraform -chdir="$DIR" "$@"
```

The provider block then names no profile. `allowed_account_ids` is the guard against the
exported credentials being the wrong account.

## Adopting what already exists

A project usually reaches Terraform with infrastructure already running. Adopt it — never
rebuild it:

1. **Generate a starting point.** In a scratch directory, write an `import` block for each
   existing resource and run `terraform plan -generate-config-out=generated.tf`. The
   output is verbose and has conflicts (both `subnets` and `subnet_mapping`, both
   `records` and `alias`); it is a reference for the real values, not the code.
2. **Write the real code by hand** in the module and roots, from the generated reference,
   with the module's resource names.
3. **Import into the module addresses**: `import { to = module.environment.aws_lb.alb …}`
   in an `imports.tf` per root.
4. **Plan until it says import N, change 0.** Every difference is either a value to copy
   exactly or a harmless normalisation to accept knowingly. Two that always appear:
   - An HTTPS listener's forward action: AWS stores both the shorthand
     `target_group_arn` and the `forward` block. Write both, with the same ARN.
   - An alias record's `dualstack.` prefix: both forms resolve to the same load
     balancer.
5. **A person applies**, and the `imports.tf` files are deleted — an import block for a
   resource already in state does nothing.

**Leave alone what is not yours.** A DNS zone shared with other systems is managed record
by record, never as a zone, and a resource another team created stays out of the state.

## Moving and retiring resources

- **Renaming or making a resource conditional** (`count`): a `moved` block, so the state
  follows and nothing is recreated.
- **Handing a resource from one root to another** (a DNS record moving from Test to Prod at
  a cutover): a `removed` block with `destroy = false` in the old root, an `import` block
  in the new one. Apply the old root first.
- **Rebuilding a server on purpose**: `tf.sh <env> apply -replace=module.environment.aws_instance.server`.
  The module ignores later changes to the AMI and the bootstrap script, so an unrelated
  apply never stops or replaces a running server.

## Security scanning

`semgrep` in the commit gate scans Terraform too. The findings worth knowing:

- **Fix by adding the setting**: log retention, an explicit CodeBuild encryption key, load
  balancer access logs (a bucket per environment with a log-delivery policy and a
  lifecycle).
- **Suppress with a reason** where the rule's concern does not apply: CloudWatch log
  groups without a customer key (service-managed encryption; IAM decides who reads),
  `ecr:GetAuthorizationToken` (no narrower form), `iam:PassRole` scoped to named roles and
  one service, an image repository with one deliberately mutable tag (a build cache).
- **Where the marker goes**: `# nosemgrep: <rule id>` on the flagged line, or alone on
  the line directly above the resource. A reason comment between the marker and the
  resource stops it matching. Use the full rule id the scan prints.

## A generated reference

Alongside the overview a person writes, generate the exhaustive one from Terraform
itself, so it cannot drift: a script that runs `terraform show -json` and
`terraform graph` for each root, and writes every managed resource (address, type, ARN)
plus each root's dependency graph drawn by Graphviz (`dot -Tsvg`) into the project's
documentation. Rerun it after an apply. Have it read everything before writing anything,
and refuse to write a root that reports no resources, so a failed read never replaces a
good reference with an empty one.

## What stays outside Terraform

- Secret values and access keys (above).
- The state bucket itself.
- Resources in other providers the project uses (the database host, the identity
  provider, the uptime monitor) unless that provider's Terraform support is worth adding
  a second provider for.
