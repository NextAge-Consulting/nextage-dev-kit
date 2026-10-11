# The org repo

One private repository per organization's AWS account, named `<org>-org`. A second AWS account gets a second org repo.

## What belongs in it

**Anything about the organization, or anything that crosses project boundaries:**

- all of the account's Terraform — every project's resources, what projects share, the legacy systems;
- the state bucket, and the ownership map (`project-documentation/org-map.md`): the projects, who owns each resource, what is not adopted and why;
- the cross-project register in the map — one project calling another's API or using its login, which credential, which side owns it;
- cross-org grants — written here when this org owns the resource, recorded here when this org's project consumes another org's;
- under `project-documentation/`: the organization's `infrastructure-overview.md`, one `projects/<project>/infrastructure.md` per project, the generated reference, and `infrastructure-access-and-change.md`.

**Everything about one project's code stays in that project** — its buildspecs, Dockerfiles, backup image, application config. A project's README links up to its org repo.

Every resource in the account is adopted into Terraform here. Nothing stays hand-managed except what the map lists as not adopted, each with its reason.

## Setting one up

Work through these in order.

1. **The person creates the GitHub repository.** Sync the kit into it with `REPO_KIND` = `org` — the walkthrough then settles the application settings and turns Gemini off — plus `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PROFILE`, and `ORG_REPO` naming the repo itself.
2. **Create the state bucket by hand** — Terraform needs it before it can store anything. The person runs these, or directs you to:
   ```bash
   B=<org>-tfstate-<account id>; R=<region>; P=<profile>
   aws s3api create-bucket --bucket "$B" --region "$R" --profile "$P" --create-bucket-configuration LocationConstraint="$R"
   aws s3api put-public-access-block --bucket "$B" --region "$R" --profile "$P" --public-access-block-configuration \
     BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
   aws s3api put-bucket-versioning --bucket "$B" --region "$R" --profile "$P" --versioning-configuration Status=Enabled
   aws s3api put-bucket-encryption --bucket "$B" --region "$R" --profile "$P" --server-side-encryption-configuration \
     '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
   aws s3api put-bucket-policy --bucket "$B" --region "$R" --profile "$P" --policy "$(jq -nc --arg b "$B" '{Version:"2012-10-17",Statement:[{Sid:"DenyInsecureTransport",Effect:"Deny",Principal:"*",Action:"s3:*",Resource:["arn:aws:s3:::\($b)","arn:aws:s3:::\($b)/*"],Condition:{Bool:{"aws:SecureTransport":"false"}}}]}')"
   ```
   For `us-east-1`, drop `--create-bucket-configuration`. Versioning is the recovery path for a damaged state file: restore the previous object version.
3. **Write the map** from `templates/org-map.md` into `project-documentation/org-map.md`: the bucket, the projects, their name prefixes.
4. **Take the inventory** (below) and record every resource in the map with its owner.
5. **Move in any Terraform a project repo already has** (`references/adopting.md`), then delete it from that project.
6. **Adopt what projects share** into `shared/`, each project's own resources into `projects/<project>/…`, and each legacy system into its own `legacy-<system>/` — one PR at a time, each planning only imports (`Plan: N to import, 0 to add, 0 to change, 0 to destroy.`).
7. **Point every project here**: its `ORG_REPO` setting, and a line in its README linking the org repo.
8. **Write the docs**: the org overview, a `projects/<project>/infrastructure.md` per project (`references/docs.md`), the generated reference, and `project-documentation/infrastructure-access-and-change.md` from the template.

## The inventory

Reading the whole account needs the person's go-ahead first — say what will be read and that nothing is changed.

- **Regions**: the account's own, plus `us-east-1` for global services (IAM, Route 53, CloudFront and its certificates). Check `aws ec2 describe-regions` against what the projects and the person name.
- **Search**: `aws resource-explorer-2 search --query-string "region:<region>"` where `aws resource-explorer-2 list-indexes` shows an index; otherwise `aws resourcegroupstaggingapi get-resources`, which misses resources never tagged.
- **Then list each kind directly**, because a search can miss what was never indexed: EC2 instances, Elastic IPs, volumes, owned images and snapshots; VPCs, subnets and security groups other than the defaults; load balancers, listeners and target groups; Route 53 zones and their records; certificates; S3 buckets; IAM roles, users and customer-managed policies; image repositories; CodeBuild projects and connections; CloudFront distributions; Lambda functions; ECS clusters, services and scheduled tasks; EventBridge rules and schedules; log groups and alarms; SNS topics and SQS queues; SES identities; Parameter Store and Secrets Manager names (never values); databases; KMS customer keys; web firewalls; backup plans; budgets.

Write each resource into the map's inventory with one owner: a project, `shared`, `legacy:<system>`, or `not adopted`. When the owner is unclear, ask the person — never guess a resource into a project.

## Not adopted, by design

Each listed in the map with its reason:

- **The state bucket** — Terraform needs it before it can run.
- **The operator role the hub assumes, and its trust policy** — a bad apply would lock everyone out of the account.
- **The sign-in identities of the account owner's people, and the root user** — the account owner manages its own people.
- **Parameter Store values a person sets, and access keys** — Terraform stores everything it sets in plain text.
- **What AWS creates itself** — the default VPC, its subnets and security group, service-linked roles, AWS-managed policies. Read them with data sources.
- **Release artifacts** — images in a repository, task definition revisions, backup snapshots.

## Values one root publishes for another

A root that owns something other roots attach to publishes it as an `aws_ssm_parameter` of type `String` (a list as `StringList`), named `/org/<kind>/<name>/<attribute>`, and the map lists it:

| Name | Value |
|---|---|
| `/org/network/<name>/vpc-id` | The network's id |
| `/org/network/<name>/subnet-ids` | Its subnets, as a `StringList` |
| `/org/host/<name>/instance-id` | A shared server |
| `/org/host/<name>/security-group-id` | That server's security group, for a project's ingress rule |
| `/org/lb/<name>/https-listener-arn` | A shared load balancer's HTTPS listener, for a project's routing rule and certificate |
| `/org/lb/<name>/security-group-id` | The load balancer's security group |
| `/org/zone/<domain>/zone-id` | A shared Route 53 zone |
| `/org/build/github-connection-arn` | The account's GitHub connection, for every project's CodeBuild |
