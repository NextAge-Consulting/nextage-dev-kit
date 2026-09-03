# Infrastructure

How the box under a kit-pipeline app is normally built. **This is how we do it, not
the only way to do it** — a project is free to diverge with a reason.

A reference, read when relevant. Not a rule, not enforced, not synced into consumer
projects. The kit ships no `deploy.yml` because deploy targets vary (handbook §11.9);
what does not vary in practice is the shape below, and re-deriving it per project is
how pieces get silently skipped.

**Verify against the live configuration, never against this document.** Every claim
here describes the intended shape. An infra doc written from intent drifts from the
running system, and the drift is invisible until something is exploited or falls over.
Read the actual security groups, the actual compose file, the actual nginx config.

## The standard shape

One host behind an Application Load Balancer. **The ALB terminates TLS with an ACM
certificate**; nginx on the box listens on `:80` only and proxies to application
containers, splitting by `server_name` when the host serves more than one site. The
containers bind to `127.0.0.1` only — never `0.0.0.0` — so the only way in is through
nginx. Images come from ECR, orchestrated by docker-compose with
`restart: unless-stopped`. A WAF is attached to the ALB.

## Why not CloudFront instead of the ALB

*Recorded against the present-tense rule (§XV) because it comes up about once a year,
always in the same words: "why are we paying $16/month for a load balancer with one
target."*

**The ALB is not there to balance anything. It is there so that TLS is AWS-managed and
invisible.** That is the whole purchase, and it is why a single-target ALB is correct
rather than embarrassing.

Drop it and the certificate moves onto the box, where it expires on a timer, unattended,
and its failure mode is the site ceasing to serve HTTPS. About $194/year to never own
that is the trade, and we take it.

## Network boundaries

**A security group per tier, never one shared group.** A single group attached to both
the load balancer and the instance opens every rule to both, which is how a box ends up
directly reachable on `:80` — bypassing the WAF that the load balancer exists to enforce.

- **Load balancer group** — `:443` (and `:80` only to redirect) from `0.0.0.0/0`.
- **Instance group** — `:80`/`:443` accepted *only from the load balancer's security
  group*, referenced by group id, not by CIDR. Nothing from the open internet.
- **SSH is never open to `0.0.0.0/0`.** Use SSM Session Manager, which needs no inbound
  rule at all, or a bastion. A world-open `:22` is a standing invitation, and it is the
  rule most often added "temporarily" during a build-out and never removed.

Check what is actually attached before believing any of this is true of a given box.

## What the pipeline assumes about the box

The per-project workflows — `deploy-<app>.yml`, `migrate.yml`, `db-backup.yml` — are
project-specific precisely because they encode these assumptions. The kit templates none
of them, but the shape below is what they all expect to find.

**They stay project-owned; this is settled, not pending.** Their differences are real
rather than drift: backup cadence and retention follow a client's own risk-versus-cost
call, and a multi-tenant project migrates an HQ database plus every tenant where a
single-database project migrates one. Templating that would force one answer onto
projects entitled to different ones. When you do need to compare, diff the file across
two projects — it is cheap, and it is the right tool for spotting a genuine improvement
worth carrying by hand.

**Images live in ECR, and a repository is created together with its lifecycle policy —
one step, never two.** Creating the repository is self-enforcing: the first push fails
without it. The policy is not. Nothing fails when it is missing; images simply accumulate
forever and the bill arrives months later. The standard policy drops untagged images after
a day and keeps the three newest images, which is roughly the last two deploys:

```json
{"rules":[
  {"rulePriority":1,
   "description":"Expire untagged after 1 day.",
   "selection":{"tagStatus":"untagged","countType":"sinceImagePushed","countUnit":"days","countNumber":1},
   "action":{"type":"expire"}},
  {"rulePriority":2,
   "description":"Expires images after 3 images created.",
   "selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":3},
   "action":{"type":"expire"}}]}
```

One deploy pushes several tags — `latest`, a short sha, a timestamp — that ECR counts as a
single image, plus a separate `buildcache` image which takes one of the three slots. So the
real rollback depth is the current release plus one prior. Untagged layers still referenced
by a live `buildcache` manifest list are never expired; ECR refuses to break a manifest list,
so a repository legitimately retains untagged images beyond the count.

**The deploy workflow asserts both and fails when either is missing.** That assertion, not
this document, is what prevents recurrence. No `deploy.yml` is templated, so the requirement
has to travel with the file people actually copy: a service is added to an existing project
by copying a neighbouring workflow, never by re-reading a setup doc. The check itself, the
read-only `ecr:GetLifecyclePolicy` grant it needs, and why it must distinguish a missing
policy from a missing permission are in `new-project-setup.md` §7a.

**Sweep established projects and every new account.** A missing policy never fails a build,
so nothing surfaces it retroactively, and an account nobody has audited is where it hides.
§7a's verify block loops every repository in a region and is the entire audit.

**Runtime configuration lives in SSM Parameter Store**, fetched by path at deploy time.
Not baked into the image, not a `.env` sitting on the box. Rotating a value is a parameter
write plus a recreate, with no rebuild.

**Client build-time config is a different thing from runtime config, and it fails
differently.** A bundler inlines its public variables at BUILD time, so by the time the
container starts the bundle is already written and no amount of correct runtime
configuration can fix it. A missing one does not crash: it falls back to a development
default and ships, which is how a customer portal reaches production with its auth client
still pointed at `http://localhost`. The build must therefore verify them itself.

**Derive the required list from the source, never from a declaration.** The build asserts
that every public variable the application code READS was actually fetched, by scanning
the source for the framework's own accessor (`import.meta.env.VITE_*` for Vite, and its
equivalent elsewhere) and checking each name against what came back from Parameter Store.

**Derive the SCOPE from the project too, never from a directory list in the buildspec.**
Start at the service's own app directory and read the aliases the project already
declares for itself — `compilerOptions.paths` in that app's `tsconfig.json`, or the
equivalent resolver config. Add an aliased directory to the scan only when the service's
source actually imports that alias, matched against a quote-anchored import specifier so
a mention in a comment pulls nothing in, and iterate to a fixpoint so a shared package
that reaches another shared package is followed. A package the service never touches then
contributes no requirement.

The block that results names no directory, no alias and no package. That is the point:
the same block ships unmodified to the next repo and reads the layout out of the project
it is building. A buildspec carrying `apps/$SERVICE plus packages plus apps/shared` looks
generic and is not — it encodes one repo's shape, passes review, and has to be
re-tailored by hand for every project after it.

The source is both the consumer and the contract, which is what makes this
self-maintaining: adding a variable to a component makes it required on the next build,
and removing the last reference retires the requirement. Three other shapes were tried
first and all were wrong — worth recording so none is reinvented:

- **Keying off the Dockerfile declaring the build ARG** fails every build for a project
  that carries the plumbing and legitimately uses no public variables. The ARG is generic
  infrastructure; its presence says nothing about whether the app has any.
- **Keying off a hand-set "this project needs them" flag** goes silent the moment someone
  adds a variable and forgets to flip it — reintroducing the exact silent failure the
  check exists to prevent, while looking like it is still guarding.
- **Hardcoding the scan roots** as the app directory plus a fixed list of shared
  directories. It passes its own project's builds, so nothing surfaces the flaw: it
  demands one app's variables of a sibling that never imports the package they live in,
  and it is a fresh hand-edit in every repo that adopts it.

A dynamic lookup escapes the scan, but the bundler cannot inline one either, so it is
already broken more visibly.

**A deploy pulls one image and recreates one service.** `docker compose pull <app>`, then
`docker compose up -d --force-recreate --no-deps <app>`. `--no-deps` is what keeps the
sibling containers and nginx up while one app rolls; without it a single app deploy
restarts the whole box. Verify with `docker compose ps` and a log tail, not by assuming.

**Nothing that touches AWS holds a long-lived credential, and everything that touches AWS
runs on AWS compute.** Deploy, migrate and every other AWS-touching workload is a
CodeBuild project assuming a service role, reaching the host through SSM Session Manager
rather than an inbound SSH port. No AWS credential lives in a repository secret, and the
only remaining GitHub dependency is the git clone. **This is where a new project starts** —
standing one up on GitHub Actions intending to move it later is the expensive path.

Only PR CI and commit linting stay on Actions: event-driven, high-frequency, wanting the
PR-integrated UI, and touching no AWS credential at all. Where something genuinely must
stay on Actions and still needs AWS, it uses OIDC (`role-to-assume`) — never a static key
pair.

**The carve-out is a credential whose own permissions are the safety boundary, not its
lifetime.** The rule above is about admin/infra access — broad reach, where a long-lived
credential is dangerous because of what it *could* do if it leaked. A recurring,
single-purpose trigger is a different shape: a static key scoped to nothing but
`codebuild:StartBuild` + `codebuild:BatchGetBuilds` on named project ARNs can never do
anything else, whether it lives five minutes or five years — the IAM policy is the
boundary, not the clock. That is the deploy-trigger case (`new-project-setup.md` §"Deploy
trigger credential"): create it directly in the target account, store it wherever that
project keeps secrets (`.env`, never committed), and never route it through a consultant's
admin hub-and-role chain (`cli-utilities.md`) — that chain solves a different problem
(one person, many client accounts) and has no bearing on one narrow job in one account.

**One CodeBuild service role per project, `<project>-codebuild-deploy`, shared by every
build project — the migration project included.** Not one role per project-per-workload.
Settled; provision the single role and move on.

The reason is that a per-workload split does not create a boundary between different
principals. Every build project runs buildspecs out of the same repository, authored by
the same people, reviewed the same way. A narrower role on the migration project would
defend against a buildspec that reaches for ECR or the host — but anyone able to edit
that buildspec can edit the deploy one just as easily, so the split costs provisioning
surface and buys nothing against the attacker it appears to address. The boundary that
does real work is the account: the role is reachable only from CodeBuild in the project's
own account, and it holds no credential anyone can carry away.

Scope the one role to the union of what the build projects need — ECR push on the
project's repository prefix, parameter read on the project's path, an SSM session onto
the deploy target, its own log group, and use of the source connection. Scope it to the
prefix and the path, never to `*`.

**The scheduled backup is the exception and keeps its own roles.** It is a different
principal on a different substrate, it is the only identity that may write to the backup
prefix, and nothing else in the estate should hold that grant — see `db-backup-pattern.md`
§"The two roles". A shared build role has no business writing backups, and the backup task
has no business pushing an image.

**Migrations run away from the box**, with `drizzle-kit` against `DATABASE_URL`, in its
own CodeBuild project gated ahead of the app deploy. The migration is versioned and logged
with the deploy rather than applied by hand over SSH.

**A deploy reaching the host over SSM lets port 22 close entirely.** An attacker then
needs AWS credentials *and* the SSH key, where an open port needs only the key. The
deploy scripts do not change — the `scp` lines, the `ssh` heredocs and the `flock` all
stay as written; only the transport underneath moves, via an SSH `ProxyCommand`.

**Install the SSM client on the operator's machine BEFORE closing the port, never after.**
The build gets its own copy — a buildspec installs `session-manager-plugin` in its
`install` phase on every run, so the pipeline half needs nothing local. The machine the
operator works from is a separate question, and it is the one that gets forgotten, because
the pipeline keeps working and hides it.

Closing `:22` removes the operator's shell too. Everything after that — an interactive
`start-session`, and the SSH `ProxyCommand` form equally — needs `session-manager-plugin`
locally, and installing it usually wants a package manager and an admin password. Get the
order wrong and access disappears at exactly the moment the cutover most needs verifying:
the deploy reports green or red and nobody can open the host to find out which is true.

**Assume the host has no second operator.** Where the AI does the host-level work, "a
human can log in and check" is not a fallback — there is no one holding a second key.
Treat operator access as part of the infrastructure and prove it works before removing
what it replaces: install the client, open a session, and do something real over it —
read a log, list the containers — rather than accepting a successful handshake as proof.

`ssm:SendCommand` runs a shell command and returns output with no local plugin at all,
which makes it a genuine fallback for "tail me that log" and a poor one for debugging. It
is a reason not to panic, never a reason to skip the install.

**The agent is not on every image.** AWS preinstalls it on Amazon Linux, Ubuntu, SLES,
AlmaLinux, macOS and Windows — **Debian is not on that list**, and a Debian host needs the
`.deb` fetched from `s3.<region>.amazonaws.com/amazon-ssm-<region>/latest/debian_amd64/`
and enabled by hand. Attaching `AmazonSSMManagedInstanceCore` to the instance role is
necessary and not sufficient; with no agent installed the role changes nothing and the
instance simply never appears in `describe-instance-information`, which reads like an IAM
problem and is not one. Check the AMI before concluding anything about permissions.

**Backups ping a dead-man's-switch.** The dump is pushed to S3 and the workflow pings a
healthcheck URL on success. A backup job that silently stops running looks exactly like a
backup job that is working, and the ping is the only thing that distinguishes them.

## Container resource limits

**Set `mem_limit` on every service, and set `memswap_limit` to the same value.** A
container with no limit is an unbounded host-level risk: the kernel's OOM killer picks
its victim by footprint rather than importance, so a leak in one app can take out nginx
or a sibling — a whole-host outage. With a limit, the same leak restarts one container,
which `restart: unless-stopped` already handles.

Size from a measurement, not a guess: `docker stats --no-stream` under real load, plus
headroom for nginx and the OS. On a small host the sum of the limits must leave the OS
room to breathe.

**These hosts run without swap, deliberately — do not add it.** Swap does not prevent
the failure a memory limit prevents; it converts a fast, contained OOM kill into the
whole box thrashing on EBS, which takes every service down together and is harder to
diagnose because nothing died. Equal `mem_limit` and `memswap_limit` is what switches
swap off for a container, which is why the two are set together above. A container that
keeps hitting its ceiling needs a bigger limit or a bigger box, never swap.

## Health checks that mean something

A 200 on `/health` proves the process answers, not that it is well. A container thrashing
at its memory ceiling answers right up until it dies. Where a check is worth having, make
it touch the thing that actually fails — a database round-trip, a cache read.

## Logs

A bind-mounted `logs/` volume fills the root disk given long enough. Rotate them, and
set the docker daemon's own log driver limits — the defaults grow without bound.

## Scheduled workloads run in AWS, not on GitHub's clock

**Anything that runs on a schedule and touches AWS is scheduled by EventBridge Scheduler
and executed by an ECS Fargate task in the client's own account.** Not a GitHub Actions
`cron` — and when standing up a new client, do not start there intending to move it later.
The move is the expensive part.

The nightly database backup is the case that forces this, and today it is the only one.
**Its full recipe is `db-backup-pattern.md`** — the image, both IAM roles, the schedule,
the bucket lifecycle, the monitor and the restore procedure. That doc is long and
operational because it is a runbook; this section only says where it sits in the build-out.

**Why not Actions.** GitHub's Actions scheduler does not deliver reliably: measured across
two unrelated orgs, nightly backups fired 3 and 10 hours late and then, on one night, not
at all — with the status page reporting Actions operational, no incident raised, and no
record left behind, because a schedule that does not fire creates no run object. A deploy
survives that, since a human dispatched it and is watching. A nightly job has nobody
watching, so the same unreliability is silent.

**Every scheduled job needs a liveness signal — proof it RAN, not just proof it did not
fail.** This is the part that gets built wrong. An alarm on task failure cannot fire when
the task never starts: no run, no metric, no alarm, and the job is silently not happening.

**That monitor is healthchecks.io**, the same one everything else here reports to. One
vendor, one place to look. Keeping it outside AWS is deliberate, and is the same argument
as moving the compute in: a monitor sharing an account and credentials with its subject
fails alongside it. The workload belongs where its data is; the monitor belongs where the
workload is not.

## What "monitored" should mean at this scale

A memory limit plus a restart policy is self-healing with no monitoring at all.
Monitoring earns its place only when someone needs to *know* it happened. Say that
plainly rather than building a dashboard nobody reads.

## The things forgotten on the second box

None of these are interesting, and all of them are only noticed when missing. **Each
line is one command against the live account** — run them on every box, not only new
ones. An established project is where these hide, because nothing ever surfaced them.

| Check | Command | Wrong answer looks like |
|---|---|---|
| A WAF is actually attached | `aws wafv2 list-web-acls --scope REGIONAL` then `list-resources-for-web-acl` | An empty list. A project ran for months with an ALB and no WAF, and nothing anywhere reported it |
| The public IP is Elastic, not auto-assigned | `aws ec2 describe-instances --query 'Reservations[].Instances[].NetworkInterfaces[].Association.IpOwnerId'` | `amazon` — the IP **moves on stop/start**, silently breaking `EC2_HOST` secrets and any A record pointing at it |
| The instance group is not world-open | `aws ec2 describe-security-groups` | Any `0.0.0.0/0` on the *instance* group. `:80` there bypasses the WAF entirely; `:22` there is a standing invitation |
| SSH is closed and SSM works | `aws ssm describe-instance-information` | Agent absent while `:22` is open — the port cannot be closed until the agent is proven |
| ECR repositories have a lifecycle policy | `aws ecr get-lifecycle-policy` per repository | `LifecyclePolicyNotFoundException`. Nothing fails; images accumulate and the bill arrives months later |
| Swap is OFF | `swapon --show` | Any swap on a container host — it trades a contained OOM kill for host-wide thrashing |
| Containers report healthy | `docker ps` | `(unhealthy)`. Check the probe target before the app — a healthcheck pointed at a path that redirects fails forever while the app is fine |
| Every container has `mem_limit` | `docker inspect -f '{{.Name}} {{.HostConfig.Memory}}' $(docker ps -q)` | A `0`. Unbounded containers are the actual control here — this is the row that matters |
| The instance is not wildly oversized | 30-day `CPUUtilization` in CloudWatch | A flat 3% with burst credits pinned at maximum, usually left over from a build-on-the-box era |

Unattended security upgrades, disk headroom for image layers, and what happens to running
containers on reboot round out the list.

## When to stop co-hosting

There is a point where a second app stops being another container on the same box and
becomes its own host. Horizontal scaling has correctness preconditions as well as
operational ones: an app holding per-process caches does not become correct just because
a second copy is running.
