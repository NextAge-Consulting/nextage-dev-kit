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
| Doing adjacent or prep work while waiting for the login | Stop. The login request is the entire reply. |

**Stop the whole turn, not just the AWS command.** An expired session blocks the
task, so the reply is the login request and nothing else. Do not keep working around
it — not adjacent prep, not "everything that doesn't need AWS yet", not reading the
files you would have checked afterwards. That work is built on facts you have not
established, so it gets redone or discarded the moment the answer arrives, and it
buries the one line the human has to act on under output they cannot use.

If the human declines to authenticate, say plainly which specific facts are therefore unknown, and leave the gap open.

### Always explicit

Pass `--region` and `--profile` on every command, and never rely on the shell's default. Never run `aws configure set` **without** `--profile` to make a command work — that repoints every later command silently. Scoped to a named profile it is fine, which is why the region-setting step below is allowed.

This project's target values live in `.claude/sync-substitutions.json`, relative to the repo root, as `AWS_ACCOUNT_ID`, `AWS_REGION` and `AWS_PROFILE`. Read them and use those exact values; they differ per project, across several accounts and regions.

### Profile provisioning

**Only ONE account is signed into. Every other account is reached by assuming a role
from it.** The hub is `nextage`; client accounts hold a `NextAgeOperator` role that
trusts it, and their profiles carry `role_arn` + `source_profile = nextage` with no
credentials of their own:

```
[profile nextage]
login_session = arn:aws:iam::<hub-account>:user/<your-iam-user>
region = us-east-2

[profile <client>]
role_arn = arn:aws:iam::<client-account>:role/NextAgeOperator
source_profile = nextage
external_id = <per-client value>
region = <their-region>
```

Every client role carries an `sts:ExternalId` condition, so a profile missing
`external_id` fails with `AccessDenied ... not authorized to perform: sts:AssumeRole`.
That error means the config line is missing, **not** that the session expired — an
expired session reports a token error against `nextage` instead.

So a client profile that reports an expired session is fixed by logging into
**`nextage`**, not that profile. The CLI calls STS itself, caches the temporary
credentials under `~/.aws/cli/cache`, and refreshes them without asking.

**The human runs `aws login --profile nextage`** — hand them
`! aws login --profile nextage` and wait. It is a browser console sign-in that writes
a `login_session` line and manages temporary credentials with a refresh token, so no
static keys land on disk. Invoked from a tool call it blocks until it times out,
having accomplished nothing.

Standing up a client account's role is `new-project-setup.md` step 0, and the client
creates it — the assistant cannot, and should hand over the instructions there rather
than improvising a policy document.

One profile per AWS account, named for the account or client, not per project.
Projects sharing an account share the profile, and each still records it in its own
`AWS_PROFILE` value.

Never create a profile via `aws configure` with static access keys, and never promote
app runtime keys from `.env` into a CLI profile — those are scoped for the app, not
for CLI work.

### 400 Bad Request from `aws login`

**Fix it by signing into the AWS console in the default browser first, then running `aws login --profile nextage`.** Sign the browser in **as the account being authenticated** — a console session for a different account is what produces the 400, which is why the hub-and-role shape above avoids this entirely: there is only ever one account to sign into. Signing out and clearing cookies for `signin.aws.amazon.com` also works; an incognito window does not reliably, because the flow wants an established session.

The symptom is a bare 400 at `https://<region>.signin.aws.amazon.com/oauth?…&client_id=arn:aws:signin:::devtools/same-device&…` while the CLI hangs for minutes on a loopback callback that never fires. The cause is stale or absent browser session cookies — not a credential, region or profile problem. Nothing in `~/.aws/` is wrong, so don't go hunting there; the 400 happens before anything reaches the token cache.

Upstream: https://github.com/aws/aws-cli/issues/10186
