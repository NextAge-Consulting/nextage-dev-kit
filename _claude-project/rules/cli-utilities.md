# CLI Utilities

Discipline for command-line tools that target a specific account / region / project,
where hitting the wrong one is expensive and often silent.

## AWS CLI

### An expired session is a HARD STOP — never substitute a guess (Zero Tolerance)

**Check the session FIRST, before the task — not when a command fails mid-flow.**
The moment a task will touch AWS at all:

```bash
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION  .claude/sync-substitutions.json)
aws sts get-caller-identity --profile "$PROFILE" --region "$REGION"
```

If that fails, **stop and ask the human to run `! aws login --profile <name>`.**
Sessions routinely expire between working sessions, so this is the normal first
step of any AWS-touching task, not an exception.

**What is forbidden is what actually happens:** the session is expired, and
rather than asking, the assistant proceeds on assumption — "the repository
presumably exists", "that's probably configured", "it's likely still set to X" —
and writes those assumptions into code, docs, or a report as if verified. That
is worse than the delay it avoids: an unverified claim stated confidently is
indistinguishable from a checked one, and it is exactly how documentation and
specs go stale.

| Forbidden | Instead |
|-----------|---------|
| "AWS isn't available, so I'll assume X" | Stop. Ask for `aws login`. |
| Writing an unverified claim into a doc/spec/report | Don't write it, or mark it explicitly unverified **and** say so in the reply |
| Discovering the expired session three commands into a task | Check `get-caller-identity` before starting |
| Handing the human a command *you* could run once authenticated | Ask for the login, then run it yourself |

If the human declines to authenticate, say plainly which specific facts are
therefore unknown, and do not fill the gap.

- **Verify before you act.** Run `aws sts get-caller-identity` and confirm it's the
  intended account before any operation that reads or writes.
- **Always explicit.** Pass `--region` and `--profile` on every command. Never rely
  on the shell's default, and never change the global default (`aws configure set`)
  to make a command work — that silently repoints every later command.
- **This project's target** is in `.claude/sync-substitutions.json`: `AWS_ACCOUNT_ID`,
  `AWS_REGION`, `AWS_PROFILE`. Read them (e.g. `jq -r .AWS_REGION .claude/sync-substitutions.json`)
  and use those exact values — they differ per project; the team works across several
  accounts and regions.

### Profile provisioning

- Profiles are created with **`aws login --profile <name>`** — the browser-based
  console sign-in. It writes a `login_session` line to `~/.aws/config` and manages
  temporary credentials + a refresh token; no static keys land on disk. The HUMAN
  runs it (give them `! aws login --profile <name>`), then set the region:
  `aws configure set region <region> --profile <name>`.
- **One profile per AWS account**, named for the account/org (e.g. `nextage`) —
  not per project. Projects sharing an account share the profile; each project
  still records it in its own `AWS_PROFILE` substitution value.
- **NEVER** create a profile via `aws configure` with static access keys, and
  never promote app runtime keys from `.env` into a CLI profile — those keys are
  scoped for the app (e.g. an S3-only user), not for CLI work.
- `AWS_PROFILE` empty but the project genuinely uses AWS → the resolution is the
  human running `aws login` for that account, not synthesizing a profile from
  whatever credentials are lying around.

### `aws login` is interactive — never run it yourself

It opens a browser and waits for a human to click through a console sign-in.
Invoked from a tool call it blocks until it times out, having accomplished
nothing. Hand the human `! aws login --profile <name>` and wait.

### 400 Bad Request from `aws login` → sign into the console FIRST

**Symptom.** The browser lands on
`https://<region>.signin.aws.amazon.com/oauth?…&client_id=arn:aws:signin:::devtools/same-device&…`
and shows a bare 400. The CLI is meanwhile waiting on its loopback callback
(`127.0.0.1:<port>`), which never fires, so it hangs with no error for several
minutes.

**Cause.** The sign-in portal rejects that OAuth request when the browser's AWS
session cookies are absent or stale. It is a cookie-state problem, not a
credential, region, or profile problem — the region in the URL is normal, and
the CLI-side token cache (`~/.aws/login/cache/`) is not involved because the 400
happens before anything reaches it.

**Fix.** Sign into the AWS console in the default browser, THEN run
`aws login --profile <name>`. Signing out and clearing cookies for
`signin.aws.amazon.com` also works; an incognito window does not reliably,
because the flow wants an established session.

Do not go hunting in `~/.aws/` for this one. Nothing there is wrong.

Upstream: https://github.com/aws/aws-cli/issues/10186
