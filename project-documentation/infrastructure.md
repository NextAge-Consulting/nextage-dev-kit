# Infrastructure

How the box under a kit-pipeline app is normally built. **This is how we do it, not
the only way to do it** — a project is free to diverge with a reason.

A reference, read when relevant. Not a rule, not enforced, not synced into consumer
projects. The kit ships no `deploy.yml` because deploy targets vary (HANDBOOK §11.9);
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

**Images live in ECR.** The deploy workflow ensures the repository exists and applies a
lifecycle policy, so old layers expire instead of accumulating until the registry bill or
the disk becomes the problem.

**Runtime configuration lives in SSM Parameter Store**, fetched by path at deploy time.
Not baked into the image, not a `.env` sitting on the box. Rotating a value is a parameter
write plus a recreate, with no rebuild.

**A deploy pulls one image and recreates one service.** `docker compose pull <app>`, then
`docker compose up -d --force-recreate --no-deps <app>`. `--no-deps` is what keeps the
sibling containers and nginx up while one app rolls; without it a single app deploy
restarts the whole box. Verify with `docker compose ps` and a log tail, not by assuming.

**CI authenticates to AWS with OIDC** — a `role-to-assume` and no long-lived credentials
in repository secrets. Static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` is the older
shape; a project still on it has not been migrated yet, and that is a gap rather than a
choice.

**Migrations run from CI, not from the box.** An ubuntu runner with `drizzle-kit` against
`DATABASE_URL`, so the migration is versioned and logged with the deploy rather than
applied by hand over SSH.

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
