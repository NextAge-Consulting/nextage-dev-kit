# Pattern: Offsite Neon → S3 Database Backups

**What this is:** the reusable recipe for giving a kit-consumer project a daily
offsite logical backup of its Neon Postgres database to AWS S3, with rolling
retention. Hand this doc to a fresh AI session when standing backups up on a new
project — it contains every setting, the AWS provisioning commands, the workflow
template, the project-specific knobs, and the restore procedure.

Values below marked `<project>` / `<PLACEHOLDER>` are the ones that change per
project.

---

## Is this a kit template or custom-per-project?

**Custom-per-project, kit-documented — same model as `deploy-*.yml` / `migrate.yml`.**

The kit does **not** sync `.github/workflows/` YAML (there is no
`_claude-project/.github/`). Workflows are project-owned; the kit governs them
via (a) documentation like this file and (b) runtime-read substitution keys in
`sync-substitutions.json` that point kit *scripts* at project workflow filenames.
A backup workflow varies exactly where deploy ones do (bucket, SSM path, PG major,
DB name, region, schedule, single vs multi-DB), so it follows the same rule:
**generate a project-specific `db-backup.yml` from this doc; do not template it.**

There is intentionally **no** `sync-substitutions.json` key for backups —
`/deploy` does not trigger backups (they run on cron), so no kit script needs to
know the filename. If a project ever wires backup into `/deploy`, add a
`BACKUP_WORKFLOW` runtime-read key mirroring `MIGRATE_WORKFLOW`.

---

## Architecture

```
GitHub Actions (cron, daily)
  └─ ping healthchecks.io /start        ← dead-man's switch (fail-loud)
  └─ install pg_dump matching Neon's PG major (PGDG apt repo)
  └─ auth to AWS (static IAM keys today; OIDC is the tracked migration)
  └─ load DATABASE_URL from SSM Parameter Store (NOT a GH secret)
  └─ strip "-pooler" → Neon DIRECT endpoint (pg_dump requires unpooled)
  └─ pg_dump -Fc → local file → validate (pg_restore --list) → aws s3 cp
  └─ ping healthchecks.io success  (or /fail on any failed step)
S3 bucket
  └─ lifecycle rule: expire nightly/ after N days   ← retention lives HERE
healthchecks.io check (period 1 day, grace ~6h)
  └─ no success ping in window → PAGES  ← catches ALL silent-loss modes
```

**Why offsite at all:** Neon's own history window (PITR) covers *accidental*
deletes fast, but only within the retention window (commonly 24h). The S3
copy is for off-platform redundancy, archival beyond the window, and compliance —
a copy that survives the Neon project being lost entirely.

**Retention is an S3 lifecycle rule, not workflow bash.** Declarative, cannot
silently fail, and prunes even if a run is skipped. Do not re-implement deletion
in the workflow.

**A dead-man's switch is mandatory, not optional** — see its own section below.
A backup you don't monitor is a backup you will silently lose.

---

## Prerequisites (per project)

1. **Neon Postgres** with the connection string in **SSM Parameter Store** under
   the project path (e.g. `/<project>/DATABASE_URL`) — the same source the
   deploy/migrate workflows read via `scripts/load-env.sh`. Know the Neon
   **major version** (`SELECT version();`) — the dump client must be `>=` it.
2. **AWS account** with the CI IAM identity the other workflows already use
   (static-key user, e.g. `github-actions-ecr-push`, exposed as GH secrets
   `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION`).
3. `scripts/load-env.sh` present in the repo (kit-standard SSM loader).
4. A **healthchecks.io check** for this backup, and its ping URL stored as a
   **GitHub Actions secret** `HEALTHCHECKS_PING_URL_BACKUP` (NOT SSM — see the
   dead-man's-switch section for why). Same account/pattern the worker uses.

---

## AWS provisioning (one-time, per project)

Run as an admin identity. **First confirm you're in the right account/region** —
these operators use several AWS accounts; `aws sts get-caller-identity` must show
the project's account. Use a named profile (`aws --profile <project> ...`) and
pass `--region` on every command; never rely on the ambient default. See the
account+region-drift warning at the bottom.

```bash
BUCKET=<project>-db-backups        # globally-unique S3 name
REGION=us-east-1                   # MUST match the project's infra/Neon region
CI_USER=github-actions-ecr-push    # the static-key CI user (varies per project)
RETENTION_DAYS=7

# 1. Bucket (us-east-1 takes NO LocationConstraint; every other region does)
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"

# 2. Block all public access
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 3. Default encryption (SSE-S3)
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

# 4. Lifecycle: expire nightly/ after N days + abort stale multipart uploads
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "{\"Rules\":[{\"ID\":\"expire-nightly-after-${RETENTION_DAYS}-days\",\"Filter\":{\"Prefix\":\"nightly/\"},\"Status\":\"Enabled\",\"Expiration\":{\"Days\":${RETENTION_DAYS}},\"AbortIncompleteMultipartUpload\":{\"DaysAfterInitiation\":1}}]}"

# 5. Least-privilege S3 policy for the CI user (write to nightly/ only)
aws iam create-policy --policy-name <Project>DBBackupS3Policy \
  --description "Least-privilege S3 write for the nightly Neon pg_dump backup" \
  --policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"PutNightlyBackups\",\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::${BUCKET}/nightly/*\"},{\"Sid\":\"ListBackupBucket\",\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::${BUCKET}\"}]}"

aws iam attach-user-policy --user-name "$CI_USER" \
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/<Project>DBBackupS3Policy
```

The CI user typically already carries SSM-read (`ParameterStoreREADPolicy`) and
ECR-push; this adds only scoped S3 write. Verify:
`aws iam list-attached-user-policies --user-name "$CI_USER"`.

---

## The workflow template

Drop as `.github/workflows/db-backup.yml`. Replace the `<...>` knobs. Pin action
SHAs to whatever the repo's other workflows already use (keep them consistent).

```yaml
name: Nightly Neon DB Backup

on:
  schedule:
    - cron: '0 6 * * *'   # 06:00 UTC daily (state in UTC; DST shifts local hour)
  workflow_dispatch:

env:
  S3_BUCKET: <project>-db-backups
  PG_MAJOR: '18'          # MUST match Neon server major version

jobs:
  backup:
    name: Dump NeonDB and upload to S3
    runs-on: ubuntu-latest
    permissions:
      contents: read       # id-token: write only if you switch to OIDC

    steps:
      - name: Signal backup start          # dead-man's switch, best-effort
        run: curl -fsS -m 10 --retry 3 "${{ secrets.HEALTHCHECKS_PING_URL_BACKUP }}/start" || true

      - uses: actions/checkout@<sha>   # need scripts/load-env.sh

      # Use PostgreSQL's OFFICIAL repo setup script — do NOT hand-roll
      # `curl | sudo gpg --dearmor`: sudo gpg opens /dev/tty (absent on the
      # runner) and the step dies under pipefail.
      - name: Install PostgreSQL ${{ env.PG_MAJOR }} client
        run: |
          set -euo pipefail
          sudo apt-get update
          sudo apt-get install -y postgresql-common ca-certificates
          sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
          sudo apt-get install -y "postgresql-client-${PG_MAJOR}"
          # /usr/bin/pg_dump is Ubuntu's pg_wrapper → resolves to the runner's
          # preinstalled client 16; call the versioned binary explicitly.
          "/usr/lib/postgresql/${PG_MAJOR}/bin/pg_dump" --version

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@<sha>
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Load DATABASE_URL from Parameter Store
        env:
          SSM_PATHS: "/<project>/"
          AWS_REGION: ${{ secrets.AWS_REGION }}
        run: |
          chmod +x .github/workflows/scripts/load-env.sh
          .github/workflows/scripts/load-env.sh
          grep -q '^DATABASE_URL=' .env || {
            echo "::error::DATABASE_URL not found in /<project>/ SSM params"; exit 1; }

      - name: Dump NeonDB and upload to S3
        run: |
          set -euo pipefail
          # SSM URL is the POOLED endpoint; pg_dump needs the DIRECT one.
          # Neon host naming: pooled = <ep>-pooler.<...>, direct = <ep>.<...>
          source_url="$(grep '^DATABASE_URL=' .env | cut -d= -f2-)"
          direct_url="${source_url/-pooler/}"
          ts="$(date -u +'%Y-%m-%dT%H%M%SZ')"
          dump_file="<dbname>-${ts}.dump"
          # Explicit versioned binary — bare pg_dump hits pg_wrapper (client 16).
          pg_bin="/usr/lib/postgresql/${PG_MAJOR}/bin"
          "${pg_bin}/pg_dump" -Fc -d "${direct_url}" -f "${dump_file}"
          "${pg_bin}/pg_restore" --list "${dump_file}" > /dev/null   # integrity gate
          aws s3 cp "${dump_file}" "s3://${S3_BUCKET}/nightly/${dump_file}" --no-progress

      - name: Signal backup success        # only runs if every step above passed
        run: curl -fsS -m 10 --retry 3 "${{ secrets.HEALTHCHECKS_PING_URL_BACKUP }}" || true

      - name: Signal backup failure
        if: failure()
        run: curl -fsS -m 10 --retry 3 "${{ secrets.HEALTHCHECKS_PING_URL_BACKUP }}/fail" || true
```

**Why dump-to-file-then-upload, not `pg_dump | aws s3 cp -`:** a naked pipe can
upload a truncated object and still exit 0 if `pg_dump` dies mid-stream, poisoning
the bucket with a corrupt "backup." Dumping locally lets `pg_restore --list`
validate the archive before upload, so a bad dump fails the job instead.

---

## Project-specific knobs (the only things that change)

| Knob | example value | Where |
|---|---|---|
| S3 bucket | `<project>-db-backups` | `env.S3_BUCKET` + AWS setup |
| PG major | `18` | `env.PG_MAJOR` (match `SELECT version()`) |
| SSM path | `/<project>/` | Load step `SSM_PATHS` |
| DB / dump prefix | `<dbname>` | `dump_file=` |
| Region | `us-east-1` | AWS setup + `secrets.AWS_REGION` |
| Retention days | `7` | S3 lifecycle rule |
| Schedule | `0 6 * * *` | `cron` |
| CI user | `github-actions-ecr-push` | IAM attach |
| Healthchecks ping | `HEALTHCHECKS_PING_URL_BACKUP` | GH secret + `curl` steps |

Everything else — PGDG install, `-pooler` strip, dump/validate/upload logic,
static-key auth block, SSM loader — is byte-identical across projects.

---

## Neon gotchas (do not skip)

1. **Use the DIRECT (unpooled) endpoint for `pg_dump`.** Pooled connections
   (host contains `-pooler`) break `pg_dump`'s session `SET` usage — Neon returns
   errors. The workflow strips `-pooler`; Neon's naming guarantees the stripped
   host is the valid direct endpoint for the same compute.
2. **Client version must be `>=` server version.** `apt install postgresql-client`
   (unpinned) or the runner's default is usually too old. Pin the major via PGDG
   — **and call the versioned binary directly** (`/usr/lib/postgresql/<major>/bin/pg_dump`).
   Bare `pg_dump` on Ubuntu is `pg_wrapper`, which resolves to the runner's
   *preinstalled* client (16 on ubuntu-24.04) and aborts on a version mismatch
   even after you install the newer client.
3. **`-Fc` custom format**, not plain SQL + gzip: already compressed, and
   `pg_restore` can do selective/parallel restore and `--list` validation.

---

## Dead-man's switch (mandatory)

A cron backup fails silently by default: a broken step, revoked creds, Neon down,
or GitHub **auto-disabling the schedule after 60 days of repo dormancy** all leave
you with no backup and no signal. Prevention (keeping the cron armed) only
addresses the dormancy case; the correct design is **detection** — a dead-man's
switch that pages when a backup is missing *for any reason*.

**Mechanism** (reuse the healthchecks.io account):

- **`/start`** ping as the first workflow step,
- **success** ping as the last step (`if: success()` by default),
- **`/fail`** ping in a trailing `if: failure()` step.

Configure the healthchecks.io check: **period 1 day, grace ~6h**. Then:

| Failure mode | What healthchecks sees | Result |
|---|---|---|
| Backup runs clean | success ping in window | quiet |
| A step fails (dump/creds/S3/Neon) | `/fail` ping | pages immediately |
| Schedule disabled by dormancy, or GitHub skips it | no ping at all | pages after grace |

**Why the ping URL is a GitHub secret, not SSM:** the monitor must be independent
of the path it watches. If the ping URL came from SSM via `load-env.sh`, an
AWS-auth or SSM failure would break the backup *and* silence the `/fail` ping —
the exact case you most need to hear about. A GitHub secret is available from step
0, so `/start` fires before any AWS call and `/fail` fires even if AWS auth is
what broke.

Pings are best-effort (`|| true`): a monitoring hiccup must never fail the actual
backup. Retries (`--retry 3`) cover transient blips.

**Structural alternative to the dormancy disable (optional):** drive the run from
off GitHub's scheduler — AWS EventBridge Scheduler → GitHub `workflow_dispatch`
API. `workflow_dispatch` is never subject to the 60-day rule. Adds a serverless
cron + a stored GitHub token; only worth it for projects that genuinely go quiet
for months. The dead-man's switch already *detects* the disable, so this is
belt-and-suspenders, not a substitute. Do **not** use keepalive-commit hacks that
fake repo activity — they pollute history and are the kind of workaround the
constitution rules out.

## Restore procedure

1. **Provision a target.** Create a new Neon project (or branch), then create a
   database with the **same name** as the source (e.g. `<dbname>`).
2. **Get the target's DIRECT connection string** (Connect modal → *deselect*
   Connection pooling; host must NOT contain `-pooler`).
3. **Pull the dump from S3:**
   ```bash
   aws s3 ls s3://<project>-db-backups/nightly/          # pick the file
   aws s3 cp s3://<project>-db-backups/nightly/<dbname>-<ts>.dump ./restore.dump
   ```
4. **Restore** (install a matching-major `pg_restore` locally first):
   ```bash
   pg_restore -v --no-owner --no-privileges \
     -d "postgresql://<user>:<pw>@<direct-host>/<dbname>?sslmode=require" \
     ./restore.dump
   ```
   `--no-owner --no-privileges` because the source's owner role/ACLs won't exist
   on the fresh target — let objects be owned by the restoring role. Drop them if
   you are restoring into an identically-roled instance and want ACLs preserved.
5. **Verify:** row counts / `\dt` against the restored DB; spot-check a few tables.
6. **Repoint** the app's `DATABASE_URL` (SSM) at the restored DB if this is a
   real recovery, not a drill.

> Recovery drills belong on a schedule — an untested backup is a hope, not a
> backup. Restore to a throwaway Neon branch quarterly and confirm the row counts.

---

## Verification (first run)

After provisioning + committing the workflow: trigger `workflow_dispatch` once,
confirm the object lands (`aws s3 ls s3://<project>-db-backups/nightly/`), confirm
the summary shows a non-trivial size, and confirm the **healthchecks.io check
flipped to "up"** (proves the dead-man's switch is wired). A 403 on upload = the
IAM policy didn't attach to the CI user. No ping received = the
`HEALTHCHECKS_PING_URL_BACKUP` secret is missing or wrong.

---

## ⚠️ Account + region drift (common footgun)

Operators here work across **several AWS accounts and regions**, so there is no
single "correct" machine default — the ambient `~/.aws/config` `[default]` will
frequently be the wrong account/region for the project in hand, and it can also
differ from the AWS **console** default (which follows last-used region). A bare
CLI command then silently targets the wrong place and appears to "lose"
resources. Do not try to fix this by pinning one global default. Instead:

- **Verify identity first:** run `aws sts get-caller-identity` and confirm the
  `Account` matches the project's account **before** any create/attach.
- **Use named profiles per account:** `aws --profile <project> ...` (or
  `AWS_PROFILE=<project>`), rather than mutating the shared default.
- **Always pass `--region` explicitly** in every provisioning command — never
  inherit it. The workflows themselves are already safe (they pass
  `secrets.AWS_REGION` everywhere); the risk is only in ad-hoc CLI provisioning.

---

## Cost

Trivial for typical app DBs: a few MB–GB per daily dump × 7 days of retention in
S3 Standard is cents/month. Revisit only if dumps grow to tens of GB (then
consider `--expected-size` on streamed uploads, or S3 Infrequent-Access tiering
in the lifecycle rule).

---

## References

- Neon backups with `pg_dump`: https://neon.com/docs/manage/backup-pg-dump
- Neon connection pooling (pooled vs direct): https://neon.com/docs/connect/connection-pooling
- Neon automate pg_dump backups: https://neon.com/docs/manage/backup-pg-dump-automate
- PostgreSQL APT (PGDG) repo: https://www.postgresql.org/download/linux/ubuntu/
- GitHub OIDC for AWS (replaces long-lived access keys): https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
