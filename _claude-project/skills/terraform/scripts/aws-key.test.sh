#!/usr/bin/env bash
# Regression suite for aws-key.sh. aws is a stub holding the user's keys and the
# parameters in files: the contract under test is that the secret goes from IAM to
# Parameter Store without ever reaching a command line or the output, that IAM's
# two-key limit is respected, and that --retire never deletes the stored key.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

t(){ if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }
has(){ if grep -qF -- "$1" "$tmp/err"; then echo "  ✓ $2"; else echo "  ✗ FAIL — $2; stderr was: $(cat "$tmp/err")"; fail=1; fi; }

STUBS="$tmp/stubs"; mkdir -p "$STUBS" "$tmp/ssm"
# aws stub: keys in $tmp/keys (one id per line), parameters as files under $tmp/ssm.
cat > "$STUBS/aws" <<STUB
#!/bin/bash
echo "\$*" >> "$tmp/argv"
arg(){ local want="\$1"; shift; while [ \$# -gt 0 ]; do [ "\$1" = "\$want" ] && { echo "\$2"; return; }; shift; done; }
case "\$1 \$2" in
  "configure export-credentials") echo "export AWS_ACCESS_KEY_ID=AKIAEXAMPLE" ;;
  "sts get-caller-identity") echo "111111111111" ;;
  "iam list-access-keys") k=\$(tr '\n' '\t' < "$tmp/keys" | sed 's/\t\$//'); echo "\${k:-None}" ;;
  "iam create-access-key")
    n=\$(( \$(cat "$tmp/made" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$tmp/made"; echo "AKIANEW\$n" >> "$tmp/keys"
    printf '{"AccessKey":{"AccessKeyId":"AKIANEW%s","SecretAccessKey":"s3cr3t-value-%s"}}\n' "\$n" "\$n" ;;
  "iam delete-access-key") id=\$(arg --access-key-id "\$@"); grep -vx "\$id" "$tmp/keys" > "$tmp/keys.new"; mv "$tmp/keys.new" "$tmp/keys" ;;
  "ssm put-parameter")
    name=\$(arg --name "\$@"); [ "\$name" = "\${FAKE_PUT_FAIL:-}" ] && { echo "AccessDenied" >&2; exit 254; }
    v=\$(arg --value "\$@"); mkdir -p "$tmp/ssm\$(dirname "\$name")"; cp "\${v#file://}" "$tmp/ssm\$name"
    echo '{"Version": 1}' ;;
  "ssm get-parameter") name=\$(arg --name "\$@"); cat "$tmp/ssm\$name" ;;
esac
STUB
chmod +x "$STUBS/aws"

repo="$tmp/repo"; mkdir -p "$repo/.claude"; cd "$repo" || exit 1
printf '{"AWS_PROFILE":"client","AWS_REGION":"eu-west-1","AWS_ACCOUNT_ID":"111111111111"}\n' > .claude/sync-substitutions.json
run(){ ( PATH="$STUBS:$PATH" bash "$D/aws-key.sh" "$@" ) >"$tmp/out" 2>"$tmp/err"; echo $?; }
: > "$tmp/keys"

echo "aws-key.sh:"
t 2 "$(run)" 'no arguments: usage'
t 2 "$(run app-mailer my-app/SES)" 'a prefix without a leading /: refuses'

t 0 "$(run app-mailer /my-app/SES)" 'first key: created'
t "AKIANEW1" "$(cat "$tmp/ssm/my-app/SES_ACCESS_KEY_ID")" '…its id stored in <prefix>_ACCESS_KEY_ID'
t "s3cr3t-value-1" "$(cat "$tmp/ssm/my-app/SES_SECRET_ACCESS_KEY")" '…its secret in <prefix>_SECRET_ACCESS_KEY, with no trailing newline'
grep -q -- '--type SecureString' "$tmp/argv" && echo "  ✓ …as SecureString" || { echo "  ✗ FAIL — not SecureString"; fail=1; }
! grep -q 's3cr3t' "$tmp/argv" && echo "  ✓ …the secret never on a command line" || { echo "  ✗ FAIL — secret in argv"; fail=1; }
! grep -q 's3cr3t' "$tmp/out" "$tmp/err" && echo "  ✓ …nor in the output" || { echo "  ✗ FAIL — secret printed"; fail=1; }
! grep -q 'still works' "$tmp/err" && echo "  ✓ …and no old key to retire" || { echo "  ✗ FAIL — named an old key"; fail=1; }

t 0 "$(run app-mailer /my-app/SES)" 'second run: a rotation'
t "AKIANEW2" "$(cat "$tmp/ssm/my-app/SES_ACCESS_KEY_ID")" '…the parameters now hold the new key'
has 'The old key AKIANEW1 still works' '…the old key named, still working'
has 'app-mailer /my-app/SES --retire' '…with the retire command'

t 2 "$(run app-mailer /my-app/SES)" 'a third key: refused at IAM''s limit'
has 'already has two keys' '…saying why'
t 2 "$(wc -l < "$tmp/keys" | tr -d ' ')" '…and no key created'

t 0 "$(run app-mailer /my-app/SES --retire)" 'retire: runs'
t "AKIANEW2" "$(cat "$tmp/keys")" '…only the stored key is left'
t 0 "$(run app-mailer /my-app/SES --retire)" 'retire again: nothing to do'
has 'nothing to retire' '…and says so'

printf 'AKIAOTHER' > "$tmp/ssm/my-app/SES_ACCESS_KEY_ID"
t 1 "$(run app-mailer /my-app/SES --retire)" 'retire when the stored id is not one of the user''s keys: refuses'
t "AKIANEW2" "$(cat "$tmp/keys")" '…deleting nothing'
printf 'AKIANEW2' > "$tmp/ssm/my-app/SES_ACCESS_KEY_ID"

t 1 "$(FAKE_PUT_FAIL=/my-app/SES_SECRET_ACCESS_KEY run app-mailer /my-app/SES)" 'the secret cannot be written: fails'
t "AKIANEW2" "$(cat "$tmp/keys")" '…the new key deleted again'
t "AKIANEW2" "$(cat "$tmp/ssm/my-app/SES_ACCESS_KEY_ID")" '…and the parameters unchanged'
has 'both parameters are unchanged' '…saying so'

t 1 "$(FAKE_PUT_FAIL=/my-app/SES_ACCESS_KEY_ID run app-mailer /my-app/SES)" 'the id cannot be written after the secret: fails'
t "AKIANEW2" "$(cat "$tmp/keys")" '…the new key deleted again'
has 'already holds its secret — run aws-key.sh again' '…naming the half-moved parameter and the fix'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
