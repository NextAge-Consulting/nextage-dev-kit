#!/usr/bin/env bash
# Regression suite for gen-reference.sh. tf.sh and Graphviz are stubs: the
# contract under test is that the reference is rewritten only when every root
# was read, and a root reporting no resources never replaces a good reference.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

t(){ if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }
has(){ if grep -qF -- "$1" "$tmp/err"; then echo "  ✓ $2"; else echo "  ✗ FAIL — $2; stderr was: $(cat "$tmp/err")"; fail=1; fi; }

# The script runs its sibling tf.sh, so it is copied beside a stub one.
bin="$tmp/bin"; mkdir -p "$bin"
cp "$D/gen-reference.sh" "$D/aws-session.sh" "$bin/"
cat > "$bin/tf.sh" <<STUB
#!/bin/bash
root="\$1"; shift
case "\$1" in
  show) cat "$tmp/state-\${root//\//_}.json" ;;
  graph) echo "digraph { a -> b }" ;;
esac
STUB
stubs="$tmp/stubs"; mkdir -p "$stubs"
printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && { echo "<svg/>" > "$2"; shift; }; shift; done\n' > "$stubs/dot"
# aws stub: one key for app-mailer, none for anyone else; IAM refused on demand.
cat > "$stubs/aws" <<STUB
#!/bin/bash
case "\$1 \$2" in
  "configure export-credentials") echo "export AWS_ACCESS_KEY_ID=AKIAEXAMPLE" ;;
  "sts get-caller-identity") echo "111111111111" ;;
  "iam list-access-keys")
    [ -n "\${FAKE_IAM_FAIL:-}" ] && { echo "AccessDenied" >&2; exit 254; }
    if [ "\$4" = app-mailer ]; then echo '{"AccessKeyMetadata":[{"AccessKeyId":"AKIAMAILER","Status":"Active","CreateDate":"2026-03-04T05:06:07+00:00"}]}'
    else echo '{"AccessKeyMetadata":[]}'; fi ;;
esac
STUB
chmod +x "$bin"/*.sh "$stubs/dot" "$stubs/aws"

repo="$tmp/my-app"; mkdir -p "$repo/.claude"; cd "$repo" || exit 1
printf '{"AWS_PROFILE":"client","AWS_REGION":"eu-west-1","AWS_ACCOUNT_ID":"111111111111"}\n' > .claude/sync-substitutions.json
git init -q
run(){ ( PATH="$stubs:$PATH"; bash "$bin/gen-reference.sh" ) >"$tmp/out" 2>"$tmp/err"; echo $?; }
doc=project-documentation/infrastructure-reference.md

echo "gen-reference.sh:"
t 2 "$(run)" 'no infra/terraform: refuses'
mkdir -p infra/terraform/prod infra/terraform/modules/env
t 1 "$(run)" 'no root with a lock file: refuses'
has 'nothing to read' '…and says so'
touch infra/terraform/prod/.terraform.lock.hcl
cat > "$tmp/state-prod.json" <<'JSON'
{"values":{"root_module":{"resources":[
 {"address":"aws_s3_bucket.b","mode":"managed","type":"aws_s3_bucket","values":{"arn":"arn:aws:s3:::example-bucket"}},
 {"address":"data.aws_caller_identity.me","mode":"data","type":"aws_caller_identity","values":{"id":"x"}}]}}}
JSON
t 0 "$(run)" 'one root with resources: writes the reference'
grep -q '^# my-app infrastructure' "$doc" && echo "  ✓ …titled with the repository name" || { echo "  ✗ FAIL — title"; fail=1; }
grep -q '## `prod` — 1 resources' "$doc" && echo "  ✓ …counting managed resources only, not data sources" || { echo "  ✗ FAIL — count: $(cat "$doc")"; fail=1; }
grep -qF 'arn:aws:s3:::example-bucket' "$doc" && echo "  ✓ …listing each resource's identifier" || { echo "  ✗ FAIL — identifier"; fail=1; }
grep -q 'UTC' "$doc" && echo "  ✓ …stamped in an explicit timezone" || { echo "  ✗ FAIL — timestamp zone"; fail=1; }
[ -f project-documentation/infrastructure-reference/prod.svg ] && echo "  ✓ …with the root's graph" || { echo "  ✗ FAIL — no graph"; fail=1; }
! grep -q 'Access keys' "$doc" && echo "  ✓ …and no key table for a root without IAM users" || { echo "  ✗ FAIL — key table without users"; fail=1; }

cat > "$tmp/state-prod.json" <<'JSON'
{"values":{"root_module":{"resources":[
 {"address":"aws_iam_user.mailer","mode":"managed","type":"aws_iam_user","values":{"arn":"arn:aws:iam::111111111111:user/app-mailer","name":"app-mailer"}},
 {"address":"aws_iam_user.reader","mode":"managed","type":"aws_iam_user","values":{"arn":"arn:aws:iam::111111111111:user/app-reader","name":"app-reader"}}]}}}
JSON
t 0 "$(run)" 'a root with IAM users: writes the reference'
grep -qF '| `app-mailer` | `AKIAMAILER` | Active | 2026-03-04 |' "$doc" && echo "  ✓ …each key listed with its status and created date" || { echo "  ✗ FAIL — key row: $(cat "$doc")"; fail=1; }
grep -qF '| `app-reader` | no key | | |' "$doc" && echo "  ✓ …and a user with no key says so" || { echo "  ✗ FAIL — keyless user row"; fail=1; }
before=$(cat "$doc")
t 1 "$(FAKE_IAM_FAIL=1 run)" 'IAM refuses the key list: fails'
has 'could not list the access keys of app-mailer' '…naming the user'
[ "$(cat "$doc")" = "$before" ] && echo "  ✓ …and the existing reference is untouched" || { echo "  ✗ FAIL — reference overwritten"; fail=1; }
before=$(cat "$doc")
mkdir -p infra/terraform/legacy/mail; touch infra/terraform/legacy/mail/.terraform.lock.hcl
echo '{"values":{"root_module":{}}}' > "$tmp/state-legacy_mail.json"
t 1 "$(run)" 'a nested root with no resources: refuses'
has 'the legacy/mail state holds no resources' '…naming the root'
[ "$(cat "$doc")" = "$before" ] && echo "  ✓ …and the existing reference is untouched" || { echo "  ✗ FAIL — reference overwritten"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
