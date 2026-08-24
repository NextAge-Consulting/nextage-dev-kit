# Rules Removed in the 2026-08 Audit

What left the kit's rules and skills, and why. Written so a later "something feels
off" has context to land on.

## 1. `constitution.md` §I — The Third-Party Library Rule

Told the model to assume it was using a library wrong before blaming it, and to
require multiple independent sources before claiming a library bug.

A guardrail for reflexive blame-shifting to dependencies — the behaviour class
Anthropic described removing for Opus 5 with no eval regression. §XI still routes
research through Ref before choosing an approach.

## 2. `rules/integrations/ref.md` — the "use Ref" line

> When asking about a library, end the prompt with "use Ref"…

Ref's own marketing copy, written as advice to a human composing a prompt. Claude
calls `mcp__Ref__ref_search_documentation` directly; there is no prompt of its own
for the phrase to go at the end of. The cold reader flagged it as the one line in
the file it could not act on.

## 3. `git.md` — the "Proactive Use of Subagents and Skills" section

~25 lines naming five skills to reach for. All five were gone:
`dispatching-parallel-agents`, `systematic-debugging`, `root-cause-tracing`,
`subagent-driven-development`, `requesting-code-review`. The `Explore` and `Plan`
agents it also named are real and carry their own descriptions.

Also not about git — every turn paid to load tooling advice out of a file about
commits.

## 4. `typescript-rules.md` §IX — Mobile Standards

Touch targets, battery optimization, iOS/Android parity, `React.memo` for "complex
components". The stack is TanStack + Astro. §VIII already carries the 44px target
and the responsive checklist; `a11y-baseline.md` owns ARIA and keyboard nav;
constitution §X owns error handling.

Mobile apps are coming. This gets rewritten then, for the stack actually chosen.

## 5. `skills/shadcn/mcp.md`

94 lines documenting the shadcn MCP server. All seven of its tools have CLI
equivalents already in `cli.md` — `get_project_registries` → `info`,
`search_items` → `search`, `view_items` → `view`, `get_item_examples` → `docs`,
`get_add_command` → `add`; the audit checklist is in `rules/a11y-primitives.md`.
MCP is not used here and the server was never in `.mcp.json`.

Its private-registry configuration — `@`-prefixed names, the `{name}` URL
placeholder, `${VAR}` auth-header resolution — was not MCP-specific and moved to
`cli.md` beside the `registries` field.

## Also fixed, not deleted

Three rules contradicted each other and were repaired in place:

- §XII forbade any `TODO` without express direction while §XIV instructed writing
  `// TODO(signature-mismatch)`. §XII now names §XIV as the exception.
- §XIV said to "attest it once" without saying where. Now: the PR body.
- §IX said resolve diagnostics "before claiming work done"; §XII said "in a file you
  touched". §IX now defers to §XII's broader scope.

Removing §IX from `typescript-rules` also left `block-console-log.sh` citing
`§II (No Console.log)` after that section was renamed to "Logging". Corrected.
