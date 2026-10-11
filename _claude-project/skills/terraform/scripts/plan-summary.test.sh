#!/usr/bin/env bash
# Regression suite for plan-summary.sh. tf.sh is a stub printing a fixture plan in
# Terraform's JSON plan format.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

t(){ if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL — $3"; printf '    got:\n%s\n    want:\n%s\n' "$2" "$1"; fail=1; fi; }

bin="$tmp/bin"; mkdir -p "$bin"
cp "$D/plan-summary.sh" "$bin/"
cat > "$bin/tf.sh" <<STUB
#!/bin/bash
[ "\$2 \$3" = "show -json" ] || exit 9
cat "$tmp/plan.json"
STUB
chmod +x "$bin"/*.sh
run(){ bash "$bin/plan-summary.sh" "$@" 2>"$tmp/err"; }

echo "plan-summary.sh:"
cat > "$tmp/plan.json" <<'JSON'
{"format_version":"1.2","resource_changes":[
 {"address":"aws_s3_bucket.uploads","change":{"actions":["create"]}},
 {"address":"aws_iam_role_policy.app","change":{"actions":["update"]}},
 {"address":"aws_instance.server","change":{"actions":["delete","create"]}},
 {"address":"aws_eip.old","change":{"actions":["delete"]}},
 {"address":"aws_lb.alb","change":{"actions":["no-op"],"importing":{"id":"arn:aws:x"}}},
 {"address":"aws_route53_record.www","change":{"actions":["update"],"importing":{"id":"Z_www"}}},
 {"address":"module.env.aws_security_group.web","previous_address":"aws_security_group.web","change":{"actions":["no-op"]}},
 {"address":"aws_ssm_parameter.unchanged","change":{"actions":["no-op"]}},
 {"address":"data.aws_caller_identity.me","change":{"actions":["read"]}}
]}
JSON
t "create aws_s3_bucket.uploads
delete aws_eip.old
import aws_lb.alb
import+update aws_route53_record.www
move aws_security_group.web -> module.env.aws_security_group.web
replace aws_instance.server
update aws_iam_role_policy.app" "$(run shared x.tfplan)" 'each action named, sorted, unchanged resources and data reads left out'

echo '{"format_version":"1.2","resource_changes":[{"address":"a.b","change":{"actions":["no-op"]}}]}' > "$tmp/plan.json"
t "no changes" "$(run shared x.tfplan)" 'a plan that touches nothing says so'

printf '{"resource_changes":[{"address":"aws_s3_bucket.b","change":{"actions":["create"]}}]}' > "$tmp/plan.json"
block=$(run --block projects/web/prod x.tfplan)
t '<!-- plan:projects/web/prod -->
```text
create aws_s3_bucket.b
```
<!-- /plan:projects/web/prod -->' "$block" '--block wraps it in the root'"'"'s markers'

body=$(printf '## Summary\n\nAdds a bucket.\n\n%s\n\n<!-- plan:shared -->\n```text\nno changes\n```\n<!-- /plan:shared -->\n' "$block")
t "create aws_s3_bucket.b" "$(printf '%s' "$body" | run --from-pr projects/web/prod)" '--from-pr reads back exactly what --block wrote'
t "no changes" "$(printf '%s' "$body" | run --from-pr shared)" '…for each root separately'
printf '%s' "$body" | run --from-pr projects/web/test >/dev/null; rc=$?
t 4 "$rc" '--from-pr fails for a root the body has no plan for'

echo 'not json' > "$tmp/plan.json"
run shared x.tfplan >/dev/null; rc=$?
t 1 "$rc" 'output that is not a plan fails'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
