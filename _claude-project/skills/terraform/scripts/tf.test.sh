#!/usr/bin/env bash
# Regression suite for tf.sh. aws and terraform are stubs: the contract under
# test is that tf.sh refuses to run Terraform unless the credentials it exported
# belong to the repository's AWS_ACCOUNT_ID, and says why whenever it refuses.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

t(){ if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }
has(){ if grep -qF -- "$1" "$tmp/err"; then echo "  ✓ $2"; else echo "  ✗ FAIL — $2; stderr was: $(cat "$tmp/err")"; fail=1; fi; }

STUBS="$tmp/stubs"; mkdir -p "$STUBS"
# aws stub: export-credentials and sts behave per $tmp/aws.mode.
cat > "$STUBS/aws" <<STUB
#!/bin/bash
mode=\$(cat "$tmp/aws.mode")
case "\$1 \$2" in
  "configure export-credentials")
    [ "\$mode" = expired ] && { echo "Error when retrieving token from sso: Token has expired" >&2; exit 255; }
    echo "export AWS_ACCESS_KEY_ID=AKIAEXAMPLE"; echo "export AWS_SECRET_ACCESS_KEY=example"; echo "export AWS_SESSION_TOKEN=example" ;;
  "configure get") echo "hub" ;;
  "sts get-caller-identity")
    [ "\$mode" = wrong ] && { echo "999999999999"; exit 0; }
    echo "111111111111" ;;
esac
STUB
cat > "$STUBS/terraform" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$tmp/terraform.args"
echo "\$*" >> "$tmp/terraform.calls"
# init writes the lock file when \$tmp/init.writes-lock exists.
[ "\$2" = init ] && [ -f "$tmp/init.writes-lock" ] && echo "provider" >> "\${1#-chdir=}/.terraform.lock.hcl"
env | grep -E '^AWS_(ACCESS_KEY_ID|PROFILE)=' > "$tmp/terraform.env" || true
STUB
chmod +x "$STUBS/aws" "$STUBS/terraform"

repo="$tmp/repo"; mkdir -p "$repo/.claude" "$repo/infra/terraform/prod" "$repo/infra/terraform/modules/env"
cd "$repo" || exit 1
run(){ ( PATH="$STUBS:$PATH"; AWS_PROFILE=leftover bash "$D/tf.sh" "$@" ) 2>"$tmp/err"; echo $?; }

echo "tf.sh:"
echo ok > "$tmp/aws.mode"
t 2 "$(run)" 'no root: usage'
t 2 "$(run prod plan)" 'no sync-substitutions.json: refuses'
has 'run this from the repository root' '…and says where to run it'
printf '{"AWS_PROFILE":"client","AWS_REGION":"eu-west-1","AWS_ACCOUNT_ID":""}\n' > .claude/sync-substitutions.json
t 2 "$(run prod plan)" 'a missing setting: refuses'
has 'AWS_ACCOUNT_ID' '…naming it'
printf '{"AWS_PROFILE":"client","AWS_REGION":"eu-west-1","AWS_ACCOUNT_ID":"111111111111"}\n' > .claude/sync-substitutions.json
t 2 "$(run staging plan)" 'a root that does not exist: refuses'
has 'no Terraform root at infra/terraform/staging' '…naming the path'
t 2 "$(run modules/env plan)" 'a module: refuses'
has 'is a module, not a root' '…and says so'
echo expired > "$tmp/aws.mode"
t 1 "$(run prod plan)" 'expired session: refuses'
has 'aws login --profile hub' '…naming the hub to sign in to, not the role profile'
echo wrong > "$tmp/aws.mode"
t 1 "$(run prod plan)" 'credentials for another account: refuses'
has 'reaches account 999999999999' '…naming both accounts'
[ ! -f "$tmp/terraform.args" ] && echo "  ✓ …and terraform never ran" || { echo "  ✗ FAIL — terraform ran"; fail=1; }
echo ok > "$tmp/aws.mode"
t 0 "$(run prod plan -out=prod.tfplan)" 'the right account: runs terraform'
t "-chdir=infra/terraform/prod" "$(sed -n 1p "$tmp/terraform.args")" '…in the root'
t "plan" "$(sed -n 2p "$tmp/terraform.args")" '…passing the arguments through'
grep -q '^AWS_ACCESS_KEY_ID=AKIAEXAMPLE' "$tmp/terraform.env" && echo "  ✓ …with the exported credentials" || { echo "  ✗ FAIL — credentials not exported"; fail=1; }
grep -q '^AWS_PROFILE=' "$tmp/terraform.env" && { echo "  ✗ FAIL — the caller's AWS_PROFILE leaked through"; fail=1; } || echo "  ✓ …and without the caller's AWS_PROFILE"

rm -f "$tmp/terraform.calls"
touch "$tmp/init.writes-lock"
t 0 "$(run prod init -input=false)" 'init that changes the lock file: runs'
grep -q "chdir=infra/terraform/prod init -input=false" "$tmp/terraform.calls" && echo "  ✓ …the init first" || { echo "  ✗ FAIL — no init: $(cat "$tmp/terraform.calls")"; fail=1; }
grep -q "chdir=infra/terraform/prod providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64" "$tmp/terraform.calls" \
  && echo "  ✓ …then locks the providers for CI and every Mac" || { echo "  ✗ FAIL — no providers lock: $(cat "$tmp/terraform.calls")"; fail=1; }
rm -f "$tmp/terraform.calls" "$tmp/init.writes-lock"
t 0 "$(run prod init -input=false)" 'init that leaves the lock file unchanged: runs'
grep -q "providers lock" "$tmp/terraform.calls" && { echo "  ✗ FAIL — locked without a lock-file change"; fail=1; } || echo "  ✓ …and does not lock"
rm -f "$tmp/terraform.calls"
run prod plan >/dev/null
grep -q "providers lock" "$tmp/terraform.calls" && { echo "  ✗ FAIL — plan also locked"; fail=1; } || echo "  ✓ …and any other command does not"

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
