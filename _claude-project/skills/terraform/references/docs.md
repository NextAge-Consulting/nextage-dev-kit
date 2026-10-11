# The infrastructure docs

All of them live in the org repo's `project-documentation/`, and read top-down:

1. **`infrastructure-overview.md`** — the organization: every project, what they share, the account, and how to reach each project's doc. Start it from `templates/infrastructure-overview.md`.
2. **`projects/<project>/infrastructure.md`** — one per project: its pieces, how a request and a release reach it, who can reach what, how to operate it. Start it from `templates/project-infrastructure.md`.
3. **`infrastructure-reference.md`** — generated: every resource of every root, with its identifier, and each root's dependency graph.

Each project with infrastructure here links from its README to its org repo's overview, unless the project is public; the overview links to every project's doc; every project doc links back up.

## Writing the overview and the project docs

- **Update them in the same change as the Terraform**, before `/open-pr`, so the reviewer reads the code, the plan and the docs together.
- **Describe what exists now**, in the words a person uses — the screen, the server, the address — never Terraform addresses. The reference holds those.
- **Draw the shape with Mermaid**: one diagram for the whole, one per flow (a request, a release).
- **Name every place a person might act**: how to reach a server, where the logs are, how a backup is restored, who can change what.
- **No secret values, no credentials, no access keys** — ever, including in examples.

**When a doc is shared as a page**, its URL sits at the top inside `<!-- page:omit -->` … `<!-- /page:omit -->`, the lines the page leaves out. After every change to the Markdown, republish the page from it to the same URL — the Artifact tool, with `url` set to that page. The Markdown stays the authority; the page is never edited by hand.

## The reference

`/deploy` regenerates it with `scripts/gen-reference.sh` after every apply and commits it onto the PR's branch before merging, so it always matches what is live. Never edit it by hand. Run the script yourself only to rebuild it outside a deploy, from the repository root.

The script reads everything before writing anything, and refuses to write when a root reports no resources, so a failed read never replaces a good reference with an empty one.
