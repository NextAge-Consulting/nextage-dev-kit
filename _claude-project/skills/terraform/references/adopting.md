# Adopting, moving and retiring resources

All of this happens in the org repo.

## Adopt what exists — never rebuild it

A resource built by hand is taken over where it stands.

1. **Generate a starting point** in a scratch root, `infra/terraform/scratch-adopt/`, holding only the provider block from `templates/root-main.tf.example` (no backend) and an `import` block per resource. Being under `infra/terraform/`, it gets its credentials from `scripts/tf.sh scratch-adopt init`, then `scripts/tf.sh scratch-adopt plan -generate-config-out=generated.tf`. A plan writes no state. The output is a reference for the real values, not the code — it is verbose and carries conflicting arguments (both `subnets` and `subnet_mapping`, both `records` and `alias`). It is gitignored, so it is never committed; delete it once the real code is written.
2. **Write the real code by hand** in the root the map gives the resource to, with the names the code will keep.
3. **Import into those addresses** with `import` blocks in an `imports.tf` in the root, e.g. `import { to = module.environment.aws_lb.alb, id = "<arn>" }`.
4. **Plan until it reports only imports and normalisations** — `Plan: N to import, A to add, M to change, 0 to destroy.`, where every add and change is one of the normalisations below. Every other difference is a value to copy exactly. The normalisations:
   - the root's `default_tags` added to each imported resource that carries tags — an in-place change to its tags and nothing else;
   - an argument AWS never returns, such as a credential's token, which the import reads as unset and would replace the resource over — give it `lifecycle { ignore_changes = [<argument>] }`;
   - a provider-only argument recorded into state for the first time (`force_destroy`, `revoke_rules_on_delete`, `publish`) — it makes no AWS call;
   - an account setting the provider cannot import (`aws_iot_logging_options`) — declare its current values; it plans as one add that writes them unchanged;
   - a web ACL whose managed rule group has no pinned version: the block form plans a change on every run, so write its rules as `rule_json` in AWS's own shape (`aws wafv2 get-web-acl` → `Rules`), which plans once as an addition;
   - an HTTPS listener's forward action: AWS stores both `target_group_arn` and the `forward` block — write both, with the same ARN. A listener rule's forward action is stored as the `forward` block alone — write only that;
   - an alias record's `dualstack.` prefix — both forms resolve to the same load balancer.
5. **`/open-pr`, then `/deploy`.** The PR's plan block shows the imports; `/deploy` applies them. Then delete `imports.tf` in a follow-up change — an import block for a resource already in state does nothing.

A resource the map does not list yet is added to the map first, with its owner.

## Move a project's Terraform into the org repo

A project repo that already holds Terraform moves it here, keeping every resource in place:

1. **Copy each root** to `infra/terraform/projects/<project>/<root>/`, and its modules to `infra/terraform/modules/`, updating the module paths.
2. **Point each root's backend** at the org's state bucket with the key `projects/<project>/<root>/terraform.tfstate`.
3. **The person moves the state**: `! .claude/skills/terraform/scripts/tf.sh projects/<project>/<root> init -migrate-state -force-copy`, which reads the state from its old location and writes it to the new one.
4. **`scripts/tf.sh <root> plan` reports `No changes.`** for every root. Anything else is a difference in the copy — fix it before going further.
5. **Land it** with `/open-pr` and `/deploy`; each root's plan block reads `no changes`, so nothing is applied.
6. **Remove the Terraform from the project repo** in a project change, with a README line pointing to the org repo unless the project is public. The old state objects are deleted once every root has moved and planned clean.

## Rename, restructure, make conditional

A `moved` block, so state follows the code and nothing is recreated:

```hcl
moved {
  from = aws_instance.server
  to   = module.environment.aws_instance.server
}
```

## Hand a resource from one root to another

A DNS record moving from Test to Prod at a cutover, a server one project owned becoming shared:

1. **The new root** writes the resource and an `import` block for it.
2. **The old root** replaces the resource with `removed { from = <address>  lifecycle { destroy = false } }`, and anything that referred to it now reads it through a data source or the Parameter Store name the new root publishes.
3. **Both land in one PR.** Either apply order is safe: the import never changes the resource, and `destroy = false` never destroys it.
4. Update the map in the same change.

## Rebuild a server on purpose

A rebuild is a change to the code, so the PR's plan shows it and `/deploy`'s fresh plan matches it. Give a server resource `lifecycle { ignore_changes = [ami, user_data], replace_triggered_by = [terraform_data.<server>_rebuild] }` beside a `terraform_data "<server>_rebuild" { input = "<date>" }`: an unrelated apply never stops or replaces the running server, and changing that `input` is the rebuild.

## Retire a resource

Delete it from the code: the PR's plan block shows the destroy, the person reads it and `/deploy` applies it. Retiring a resource another project still uses is a change to the map first. A root is emptied this way and deployed before its folder is deleted — `changed-roots.sh` refuses a deleted root whose resources still exist.
