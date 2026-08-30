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

One host. nginx terminates TLS and proxies to application containers. The containers
bind to `127.0.0.1` only — never `0.0.0.0` — so the only way in is through nginx.
Images come from ECR, orchestrated by docker-compose with `restart: unless-stopped`.

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

**A deploy pulls one image and recreates one service.** `docker compose pull <app>`, then
`docker compose up -d --force-recreate --no-deps <app>`. `--no-deps` is what keeps the
sibling containers and nginx up while one app rolls; without it a single app deploy
restarts the whole box. Verify with `docker compose ps` and a log tail, not by assuming.

**Nothing that touches AWS holds a long-lived credential.** Three shapes exist across the
estate, best first:

1. **Build and deploy on AWS compute** — CodeBuild assuming a service role, reaching the
   host through SSM Session Manager rather than an inbound SSH port. No AWS credential in
   any repository secret, and the only remaining GitHub dependency is the git clone.
2. **GitHub Actions with OIDC** — a `role-to-assume` and no static keys. Correct for
   anything that must stay on Actions.
3. **Static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`** — the older shape. A project
   still on it has not been migrated, and that is a gap rather than a choice.

**Migrations run away from the box**, with `drizzle-kit` against `DATABASE_URL` — in
CodeBuild where the deploy has moved there, on a runner where it has not. Either way the
migration is versioned and logged with the deploy rather than applied by hand over SSH.

**A deploy reaching the host over SSM lets port 22 close entirely.** An attacker then
needs AWS credentials *and* the SSH key, where an open port needs only the key. The
deploy scripts do not change — the `scp` lines, the `ssh` heredocs and the `flock` all
stay as written; only the transport underneath moves, via an SSH `ProxyCommand`.

**Backups ping a dead-man's-switch.** The dump is pushed to S3 and the workflow pings a
healthcheck URL on success. A backup job that silently stops running looks exactly like a
backup job that is working, and the ping is the only thing that distinguishes them.

## Container resource limits

**Set `mem_limit` (and `memswap_limit`) on every service.** Without them the kernel's
OOM killer picks its victim by footprint rather than importance, so a leak in one app
can take out nginx or a sibling container — a whole-host outage. With a limit, the same
leak restarts one container, which `restart: unless-stopped` already handles.

Size from a measurement, not a guess: `docker stats --no-stream` under real load, plus
headroom for nginx and the OS. On a small host the sum of the limits must leave the OS
room to breathe.

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

Swap, or the deliberate absence of it, on a small instance. Unattended security upgrades.
Disk headroom for image layers — pulls accumulate. What happens to running containers on
reboot. None of these are interesting, and all of them are only noticed when missing.

## When to stop co-hosting

There is a point where a second app stops being another container on the same box and
becomes its own host. Horizontal scaling has correctness preconditions as well as
operational ones: an app holding per-process caches does not become correct just because
a second copy is running.
