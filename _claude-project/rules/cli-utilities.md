# CLI Utilities

Discipline for command-line tools targeting a specific account, region or project, where hitting the wrong one is expensive and usually silent.

## AWS CLI

### Check the session before the task, not when a command fails (Zero Tolerance)

The moment a task will touch AWS at all:

```bash
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION  .claude/sync-substitutions.json)
aws sts get-caller-identity --profile "$PROFILE" --region "$REGION"
```

Check that the `Account` it returns equals `AWS_ACCOUNT_ID` from the same file before any operation that reads or writes. If the command fails, **stop and ask the human to run `! aws login --profile <name>`** — the leading `!` is what they type in the Claude Code prompt to run it in this session, so paste it with the bang. Sessions expire between working sessions, so this is the normal first step of an AWS task rather than an exception.

**With an expired session, stop — never substitute a guess.** "The repository presumably exists", "that's probably configured", "it's likely still set to X", written into code, docs or a report as though verified, is worse than the delay it avoids: an unverified claim stated confidently is indistinguishable from a checked one.

| Forbidden | Instead |
|-----------|---------|
| "AWS isn't available, so I'll assume X" | Stop. Ask for `aws login`. |
| Writing an unverified claim into a doc, spec or report | Don't write it — or mark it explicitly unverified **and** say so in the reply |
| Discovering the expired session three commands into a task | Check `get-caller-identity` before starting |
| Handing the human a command *you* could run once authenticated | Ask for the login, then run it yourself |

If the human declines to authenticate, say plainly which specific facts are therefore unknown, and leave the gap open.

### Always explicit

Pass `--region` and `--profile` on every command, and never rely on the shell's default. Never run `aws configure set` **without** `--profile` to make a command work — that repoints every later command silently. Scoped to a named profile it is fine, which is why the region-setting step below is allowed.

This project's target values live in `.claude/sync-substitutions.json`, relative to the repo root, as `AWS_ACCOUNT_ID`, `AWS_REGION` and `AWS_PROFILE`. Read them and use those exact values; they differ per project, across several accounts and regions.

### Profile provisioning

**The human runs `aws login --profile <name>`** — hand them `! aws login --profile <name>` and wait. It is a browser console sign-in that writes a `login_session` line to `~/.aws/config` and manages temporary credentials with a refresh token, so no static keys land on disk. Invoked from a tool call it blocks until it times out, having accomplished nothing. Once they report it done, you set the region yourself: `aws configure set region <region> --profile <name>`.

One profile per AWS account, named for the account or org (e.g. `nextage`), not per project. Projects sharing an account share the profile, and each still records it in its own `AWS_PROFILE` value.

Never create a profile via `aws configure` with static access keys, and never promote app runtime keys from `.env` into a CLI profile — those are scoped for the app, not for CLI work.

An empty `AWS_PROFILE` on a project that genuinely uses AWS is resolved by the human running `aws login` for that account, never by synthesizing a profile from whatever credentials are lying around.

### 400 Bad Request from `aws login`

**Fix it by signing into the AWS console in the default browser first, then running `aws login --profile <name>`.** Signing out and clearing cookies for `signin.aws.amazon.com` also works; an incognito window does not reliably, because the flow wants an established session.

The symptom is a bare 400 at `https://<region>.signin.aws.amazon.com/oauth?…&client_id=arn:aws:signin:::devtools/same-device&…` while the CLI hangs for minutes on a loopback callback that never fires. The cause is stale or absent browser session cookies — not a credential, region or profile problem. Nothing in `~/.aws/` is wrong, so don't go hunting there; the 400 happens before anything reaches the token cache.

Upstream: https://github.com/aws/aws-cli/issues/10186
