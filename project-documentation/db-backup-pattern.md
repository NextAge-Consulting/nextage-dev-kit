# Pattern: Offsite Neon → S3 Database Backups

**What this is:** the recipe for giving a kit-consumer project a daily offsite logical
backup of its Neon Postgres database to AWS S3, with rolling retention and a
dead-man's-switch monitor. Hand this doc to a fresh AI session when standing backups up
on a project — it carries the architecture, the AWS provisioning, the project-specific
knobs, the monitor, and the restore procedure.

Values marked `<project>` / `<PLACEHOLDER>` are the ones that change per project.

---

## This is the SECOND line of defence — size the effort accordingly

**Neon's own point-in-time recovery is the primary backup.** It is continuous, it is the
thing you actually reach for after a bad migration or a mistaken `DELETE`, and it needs
no work from us. This pattern is the *offsite* copy: it covers the cases PITR cannot —
the Neon project itself lost, an account closed or compromised, a provider-wide failure,
or a retention window that has already rolled past the damage.

That ranking is not a footnote, it is the budget. It means the correct amount of
machinery here is: dump, validate, upload, and one dead-man's switch. Everything past
that is being built for the second line of defence against a failure whose first line
still works, and it competes for attention with real work.

**So the bar for adding anything to this pattern is high, and "it would be nice to be
warned earlier" does not clear it.** The worked example, decided and not to be reopened:
a check comparing the image's `pg_dump` major against the live server major, so a Neon
major upgrade is announced before the dump fails. It sounds prudent and it is not worth
building.

- The case is **already fail-loud**. Postgres refuses outright — "pg_dump cannot dump
  from PostgreSQL servers newer than its own major version; it will refuse to even try" —
  so the run exits non-zero, the trap pings `/fail`, and the monitor pages that night.
  Nothing is silent.
- Nothing is **down**. The primary backup is unaffected; what has stopped is the copy of
  a copy, and the fix is a one-line `FROM` bump and an image push.
- The check **cannot warn earlier anyway**. Nothing inside the container can see a
  scheduled provider upgrade, so the first signal is the first failed run either way. The
  gain is a better error message on a once-in-two-years event.
- A second monitor for it is worse than nothing — see the dead-man's-switch section.
  One vendor, one place to look.

Apply the same test to anything else proposed here: does it detect a failure that is
otherwise silent, and does that failure put real data at risk? If not, it is tinkering,
and the documentation is the control.

---

## The shape

```
EventBridge Scheduler  (daily, in the project's AWS account)
  └─ runs ECS Fargate task
       └─ ping healthchecks.io /start          ← dead-man's switch, before anything else
       └─ read DATABASE_URL from SSM Parameter Store
       └─ pg_dump -Fc  →  local file
       └─ validate with pg_restore --list      ← a truncated dump must fail, not upload
       └─ aws s3 cp    →  s3://<bucket>/nightly/
       └─ ping healthchecks.io success   (or /fail on any error)
S3 bucket
  └─ lifecycle rule: expire nightly/ after N days     ← retention lives HERE
healthchecks.io check  (period 1 day, grace ~2h)
  └─ no success ping in window → PAGES               ← catches every silent-loss mode
```

**The schedule and the compute both live in the account that owns the data.** Nothing in
this path depends on GitHub.

### Why not a GitHub Actions cron

Actions is the least reliable GitHub component, and its *scheduler* is the least reliable
part of it. Measured across two unrelated orgs on 2026-08-27/28: nightly backups fired
3h07m late, 10h05m late, and on one night not at all — with GitHub's status page reporting
Actions operational throughout, no incident raised, and **no record left behind**. A
schedule that does not fire creates no run object, so there is nothing in the Actions tab
and nothing in the API to find afterwards.

A deploy on Actions survives that because a human dispatched it and is watching. A nightly
backup has nobody watching, so the same unreliability is silent — and it is silent about
the one artifact you only reach for on your worst day.

Two shapes that look like fixes and are not:

- **EventBridge Scheduler → GitHub `workflow_dispatch`.** Replaces GitHub's scheduler but
  keeps the Actions control plane in the path, so an Actions outage still stops the backup.
  It also adds a stored GitHub token as a new standing credential. One of two problems.
- **Keepalive commits** to dodge the 60-day dormancy disable. Pollutes history, and treats
  a symptom the dead-man's switch already detects.

### Why Fargate rather than Lambda or CodeBuild

- **Lambda** is cheaper and simpler at today's dump sizes, but needs `pg_dump` packaged as
  a layer or container image and carries a hard 15-minute ceiling. That ceiling sits on the
  disaster-recovery path and arrives silently as a database grows.
- **CodeBuild** is the right home for the workloads that *are* builds. A backup has no
  source to check out and nothing to compile; carrying a build project for it is cosmetic
  consistency.

Fargate has no execution-time limit, needs no packaging beyond an ordinary container
image, and scales with the database instead of hitting a wall.

---

## Is this a kit template or custom-per-project?

**Custom-per-project, kit-documented — same model as the deploy and migrate buildspecs.**

The pieces vary exactly where the deploy ones do: bucket, SSM path, PG major, database
name, region, schedule, retention, single vs multi-DB. Generate project-specific
infrastructure from this doc; do not template it.

No `sync-substitutions.json` key is needed. No kit script triggers a backup — the schedule
lives in AWS — so nothing needs to know its name.

---

## Prerequisites (per project)

1. **Neon Postgres**, with the connection string in **SSM Parameter Store** under the
   project path (e.g. `/<project>/DATABASE_URL`) — the same source deploy and migrate
   read. Know the Neon **major version** (`SELECT version();`); the dump client must be
   `>=` it.
2. **An AWS account** for the project, reached through a named profile.
3. **An ECR repository** for the backup image, with a lifecycle policy created in the same
   step (see `infrastructure.md` — a missing lifecycle policy never fails anything, it
   just bills forever).
4. **A healthchecks.io check** for this backup, with its ping URL stored as an SSM
   parameter under the project path.

---

## The image

A small image carrying a matching-major `pg_dump` and the AWS CLI, plus the backup script
as its entrypoint. Built once and pushed to the project's ECR; rebuilt only when Neon's
major version moves.

```dockerfile
FROM public.ecr.aws/docker/library/postgres:<PG_MAJOR>-alpine
RUN apk add --no-cache aws-cli curl
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh
ENTRYPOINT ["/usr/local/bin/backup.sh"]
```

The script's shape, in order — **the ordering is the design, not incidental**:

1. Read the ping URL from SSM **first and alone**, and exit non-zero if it is missing or
   not a URL. With no URL there is nothing to ping, so this one failure is reported by
   the dead-man's switch when the grace window closes, not by `/fail`.
2. `set -euo pipefail`, trap failure to ping `${HEALTHCHECKS_URL}/fail`, then ping
   `${HEALTHCHECKS_URL}/start` — before any other AWS call, so every later failure
   pings `/fail` at once.
3. Read each database URL from SSM with `--with-decryption`. **Never echo a URL.**
4. `pg_dump -Fc -d "$url" -f "$dump_file"` — **to a local file, never piped straight to
   S3.** A pipe can upload a truncated object and still exit 0 if `pg_dump` dies
   mid-stream.
5. `pg_restore --list "$dump_file" > /dev/null` to validate, so a corrupt dump fails the
   task instead of poisoning the bucket.
6. `aws s3 cp` to `s3://<bucket>/nightly/`.
7. Ping `${HEALTHCHECKS_URL}` on success.

Pings are best-effort (`|| true`) — a monitoring hiccup must never fail the actual backup.
Use `--retry 3` for transient blips.

**Back up every database together when a project has more than one.** A multi-tenant
project's registry and its tenant data are restored as a set; a lone restore leaves the
pair inconsistent.

---

## AWS provisioning (one-time, per project)

Run as an admin identity. **Confirm the account first** — these operators work across
several AWS accounts and regions. `aws sts get-caller-identity --profile <project>` must
show the project's account before any create. See the drift warning near the bottom.

### 1. The bucket

```bash
BUCKET=<project>-db-backups        # globally-unique S3 name
REGION=<region>                    # MUST match the project's infra
RETENTION_DAYS=7
PROFILE=<project>

# us-east-1 takes NO LocationConstraint; every other region does
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --profile "$PROFILE"

aws s3api put-public-access-block --bucket "$BUCKET" --profile "$PROFILE" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption --bucket "$BUCKET" --profile "$PROFILE" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# Retention is a lifecycle rule, NOT script logic — declarative, cannot silently
# fail, and prunes even when a run is skipped. Do not re-implement deletion.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --profile "$PROFILE" \
  --lifecycle-configuration "{\"Rules\":[{\"ID\":\"expire-nightly-after-${RETENTION_DAYS}-days\",\"Filter\":{\"Prefix\":\"nightly/\"},\"Status\":\"Enabled\",\"Expiration\":{\"Days\":${RETENTION_DAYS}},\"AbortIncompleteMultipartUpload\":{\"DaysAfterInitiation\":1}}]}"
```

### 2. The two roles

Fargate needs both, and conflating them is the usual mistake:

- **Execution role** — what ECS itself uses to pull the image and write task logs.
  `AmazonECSTaskExecutionRolePolicy`, plus `ssm:GetParameter` if any parameter is injected
  as a task-definition secret.
- **Task role** — what the *backup script* uses. Scope it to exactly two things:
  `ssm:GetParameter` on `/<project>/*`, and `s3:PutObject` on
  `arn:aws:s3:::<bucket>/nightly/*` plus `s3:ListBucket` on the bucket.

**The task role is the only identity with write access to `nightly/`.** Nothing else — no
CI identity, no deploy role, no user — needs it, and any other principal holding it is a
standing grant on the backups nobody is watching. Worth confirming on an audit, since
nothing fails when it is wrong.

No standing IAM user, and no long-lived access key anywhere in this path.

### 3. The task definition

Fargate, `awsvpc` networking, the ECR image above, both roles attached, and a CloudWatch
log group. Pass the SSM parameter *names* and the bucket as environment variables; the
script reads the values at runtime through the task role. `0.25 vCPU / 512 MB` is
generous for a dump of a few hundred MB — size up only when a measurement says to.

The task needs egress to reach Neon, SSM, S3 and healthchecks.io. Public subnets with
`assignPublicIp: ENABLED`, or private subnets with a NAT — the same choice the rest of the
project's infrastructure already made.

### 4. The schedule

An **EventBridge Scheduler** schedule with an `ECS RunTask` target, a
`cron(<minute> <hour> * * ? *)` expression in UTC, and `FlexibleTimeWindow: OFF`.

**Pick an hour that is low-traffic for the client's users, not for you** — a dump takes a
consistent snapshot but still competes for the database. Derive the hour from the client's
actual timezone.

### 5. The task-state log

**ECS discards a stopped task after about an hour, taking `stoppedReason` with it.** That
is the one field naming why a task died before its container ever ran, and a nightly job
is almost always investigated after that hour has passed. An EventBridge rule copying the
task's STOPPED event into a log group keeps it.

This is not a second monitor and it raises no alerts — the dead-man's switch is still the
only thing that pages. It is a record, written once a night, so the next investigation
starts from a fact instead of an inference.

Match **every** STOPPED event for the family, not just failures. A pre-start failure
carries `stopCode: TaskFailedToStart`, so a filter aimed at container exits is exactly the
filter that drops the case this exists for. One event a night costs nothing.

```bash
LOG_GROUP=/aws/events/<project>-db-backup-task-state

aws logs create-log-group --log-group-name "$LOG_GROUP" --profile <p> --region <r>
aws logs put-retention-policy --log-group-name "$LOG_GROUP" \
  --retention-in-days 90 --profile <p> --region <r>
```

EventBridge writes to a log group through a **resource policy on the log group**, not an
IAM role — the console creates it silently, the CLI does not. Without it the rule matches,
the delivery fails, and nothing anywhere says so:

```bash
aws logs put-resource-policy --policy-name EventBridgeToCWLogs --profile <p> --region <r> \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "EventBridgeToCWLogs",
      "Effect": "Allow",
      "Principal": { "Service": ["events.amazonaws.com", "delivery.logs.amazonaws.com"] },
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:<region>:<account-id>:log-group:/aws/events/*:*",
      "Condition": { "StringEquals": { "aws:SourceAccount": "<account-id>" } }
    }]
  }'
```

Both service principals are what AWS's own example carries, and the policy `Resource` takes
a trailing `:*` because the actions operate on log streams. The policy is account-wide and
an account gets ten of them, so one `/aws/events/*` statement covers every rule of this
kind rather than one per job.

Then the rule and its target:

```bash
aws events put-rule --name <project>-db-backup-task-state --state ENABLED \
  --profile <p> --region <r> --event-pattern '{
    "source": ["aws.ecs"],
    "detail-type": ["ECS Task State Change"],
    "detail": {
      "clusterArn": ["arn:aws:ecs:<region>:<account-id>:cluster/<cluster>"],
      "group": ["family:<project>-db-backup"],
      "lastStatus": ["STOPPED"]
    }
  }'

aws events put-targets --rule <project>-db-backup-task-state --profile <p> --region <r> \
  --targets '[{"Id":"cwlogs","Arn":"arn:aws:logs:<region>:<account-id>:log-group:'"$LOG_GROUP"'"}]'
```

**No `RoleArn` on a CloudWatch Logs target** — AWS documents that explicitly, and the
resource policy above is what authorises the write. The target ARN is the bare log-group
ARN with no `:*`; that differs from the policy ARN, and AWS publishes no example of it, so
treat a working delivery as the proof rather than the docs.

Skip the InputTransformer. Left off, the whole event body becomes the log message, which
is what you want — it carries `stopCode`, `stoppedReason`, per-container `exitCode`,
`availabilityZone`, and `pullStartedAt`/`pullStoppedAt` for pinning an image-pull stall.

**Verify by running the task once and reading the log group.** A misspelled ARN or a
missing resource policy fails silently, so a rule that exists is not evidence that
anything is being recorded.

---

## Project-specific knobs (the only things that change)

| Knob | Example | Where |
|---|---|---|
| S3 bucket | `<project>-db-backups` | Bucket setup + task env |
| PG major | `18` | Image `FROM`, must match `SELECT version()` |
| SSM path | `/<project>/` | Task role policy + task env |
| Databases | one, or a registry + tenants | Script's list |
| Region | `<region>` | Every provisioning command |
| Retention days | `7` | S3 lifecycle rule |
| Schedule | `cron(37 10 * * ? *)` | EventBridge Scheduler |
| Healthchecks ping | SSM `/<project>/HEALTHCHECKS_URL_BACKUP` | Task env + check |
| Task-state log | `/aws/events/<project>-db-backup-task-state` | Log group + EventBridge rule |

Everything else — the script, both role shapes, the validate-before-upload order — is
identical across projects.

---

## Neon gotchas (do not skip)

1. **Use the DIRECT (unpooled) endpoint for `pg_dump`.** A pooled host (containing
   `-pooler`) breaks `pg_dump`'s session `SET` usage. Some projects already store the
   direct endpoint in SSM because migrations need it too — **check before adding a strip
   step**, and do not add one whose input is already direct.
2. **Client version must be `>=` server version.** This is why the image pins the major
   rather than taking whatever the base image ships.
3. **`-Fc` custom format**, not plain SQL plus gzip: already compressed, and `pg_restore`
   gets selective restore, parallel restore, and `--list` validation.

---

## The dead-man's switch (mandatory)

A scheduled backup fails silently by default. A broken step, revoked credentials, Neon
down, or a schedule that simply does not fire all leave you with no backup and no signal.
Prevention addresses none of it; the correct design is **detection**.

**healthchecks.io is the monitoring system for this, and for everything else that needs
one.** One vendor, one place to look, one set of alert routing. Do not add a second
monitoring implementation per workload — monitoring scattered across four vendors is four
places to check and four ways to miss something.

It is deliberately **outside AWS**. A monitor that shares an account and credentials with
the thing it watches fails with its subject, which is the case you most need to hear
about. That is the same argument that moves the compute into AWS, applied in the other
direction: the workload belongs where its data is, and the monitor belongs where the
workload is not.

**Mechanism:**

| Failure mode | What healthchecks sees | Result |
|---|---|---|
| Backup runs clean | success ping in window | quiet |
| A step fails (dump, creds, S3, Neon) | `/fail` ping | pages immediately |
| The ping URL itself cannot be read | no ping at all | pages after grace |
| Task never starts, or schedule never fires | no ping at all | pages after grace |
| Task is launched but the container never runs | no ping at all | pages after grace |

**A liveness signal is the point — not a failure signal.** An alarm wired to task failure
cannot fire when the task never starts: no run, no metric, no alarm, and the backup is
silently not happening. Alarm on the *absence* of success.

**Grace: ~2h on a daily period.** With the schedule in EventBridge there is no
hours-late-delivery problem to absorb, so the window only needs to cover a slow dump plus
a retry. A wide grace is detection latency you are choosing to accept; do not carry one
that was sized for a scheduler you no longer use.

**Store the ping URL in SSM alongside the other parameters.** The earlier reason to keep
it out of SSM was that a GitHub-hosted job could lose AWS auth and thereby silence its own
`/fail`. A Fargate task cannot start at all without AWS working, so that case no longer
exists.

### When it pages and there are no logs

The last row of that table is a distinct failure shape, and it is easy to misread as the
row above it. The schedule fires, ECS accepts the task, and the container never starts. Nothing
in the script runs — not the `/start` ping, not the first SSM read — so there is no
`/fail` either, because the trap that sends it lives *inside* the container. The check
goes down on silence, which is what it is for.

**Read the task-state log group first** — `/aws/events/<project>-db-backup-task-state`,
provisioned in step 5. It holds the STOPPED event for every run, and its `stoppedReason`
and `stopCode` name the cause outright. On a task that never started, `stopCode` is
`TaskFailedToStart` and `stoppedReason` carries the detail — typically a
`ResourceInitializationError` or a `CannotPullContainerError`.

That log group exists because **ECS itself keeps a stopped task for only about an hour**.
After that `describe-tasks` returns `MISSING` and `stoppedReason` is gone, and a nightly
job is almost always investigated later than that. If a project predates step 5 and has no
such log group, the cause is not recoverable and the rest of this section is what is left.

Establish the shape from what else outlives the task:

| Question | Where to look | A clean run shows |
|---|---|---|
| Did the schedule fire? | CloudTrail `RunTask` in the hour around the schedule | one event, `"failures":[]`, a task id |
| Did the container run? | the task's log group | a log stream named for that task id |
| Did the script start? | CloudTrail `GetParameter` by the task role | the SSM reads the script makes |

`RunTask` with no failures, no log stream, and no `GetParameter` places the failure
between PROVISIONING and RUNNING. Rule out the standing causes before calling it
transient: the image tag still resolves in ECR, the schedule is still ENABLED and points
at a live task definition revision, and the subnet is one that has worked on other nights.
Then re-run the task by hand. **If an unchanged task definition and image succeed
minutes later, it was transient** — the backup is restored and there is nothing to fix.

**Do not add retry machinery for this**, and do not treat one such night as a defect in
the pattern. It fails the test at the top of this doc: the dead-man's switch detected it,
loudly, and the primary backup was never at risk. A wrapper that retries the task buys one
night of the *second* line of defence and costs a permanent new component in every project
that runs this.

Do not reach for the grace either. **Size it by when a human will actually act, not by
how fast an alert can be produced.** If a failed nightly backup gets worked the next
morning regardless — the usual case, since nothing is down — then a tighter window only
moves the page into the middle of the night and buys no earlier action. And it never buys
diagnosis: ECS's hour beats any grace worth setting, so the task is gone either way.
Treat the grace as detection latency and set it against the response you will really
give it.

---

## Restore procedure

1. **Provision a target.** Create a new Neon project (or branch), then create a database
   with the **same name** as the source.
2. **Get the target's DIRECT connection string** (Connect modal → *deselect* connection
   pooling; the host must not contain `-pooler`).
3. **Pull the dump:**
   ```bash
   aws s3 ls s3://<project>-db-backups/nightly/ --profile <project>
   aws s3 cp s3://<project>-db-backups/nightly/<dbname>-<ts>.dump ./restore.dump --profile <project>
   ```
4. **Restore** (install a matching-major `pg_restore` locally first):
   ```bash
   pg_restore -v --no-owner --no-privileges \
     -d "postgresql://<user>:<pw>@<direct-host>/<dbname>?sslmode=require" \
     ./restore.dump
   ```
   `--no-owner --no-privileges` because the source's owner role and ACLs do not exist on a
   fresh target. Drop those flags only when restoring into an identically-roled instance
   where you want the ACLs preserved.
5. **Verify:** row counts and `\dt` against the restored database; spot-check tables.
6. **Restore every database of a multi-database project together**, then repoint the app's
   SSM parameters if this is a real recovery rather than a drill.

> Recovery drills belong on a schedule — an untested backup is a hope, not a backup.
> Restore to a throwaway Neon branch quarterly and confirm the row counts.

---

## Verification (first run)

Trigger the task once by hand (`aws ecs run-task` with the same definition, or the
schedule's target), then confirm all four:

- the object lands (`aws s3 ls s3://<project>-db-backups/nightly/`) at a non-trivial size,
- the task exits 0 and its CloudWatch log shows the validate step passing,
- the **healthchecks.io check flips to "up"** — which is what proves the switch is wired,
- **no connection string appears in the log.**

A 403 on upload means the *task* role lacks S3 write — check the task role, not the
execution role. No ping received means the ping URL parameter is missing or wrong.

---

## ⚠️ Account + region drift (common footgun)

Operators here work across several AWS accounts and regions, so there is no correct
machine default — the ambient `[default]` profile will frequently be the wrong account for
the project in hand, and can differ from the console's default (which follows last-used
region). A bare CLI command then silently targets the wrong place and appears to "lose"
resources. Do not fix this by pinning one global default:

- **Verify identity first.** `aws sts get-caller-identity` must show the project's account
  before any create or attach.
- **Use a named profile per account** (`--profile <project>`), never mutate the shared
  default.
- **Pass `--region` explicitly** on every command.

---

## Cost

Trivial. A Fargate task at `0.25 vCPU / 512 MB` running a couple of minutes a day is cents
per month, and a few MB–GB per dump across 7 days of S3 Standard is cents more. Revisit
only if dumps reach tens of GB, at which point consider S3 Infrequent-Access tiering in
the lifecycle rule.

---

## References

- Neon backups with `pg_dump`: https://neon.com/docs/manage/backup-pg-dump
- Neon connection pooling (pooled vs direct): https://neon.com/docs/connect/connection-pooling
- EventBridge Scheduler targets: https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-targets.html
- ECS task role vs execution role: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html
- `infrastructure.md` — where this sits in the standard client build-out
