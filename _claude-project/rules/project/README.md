# Project-Specific Rules

This directory is for rules that apply ONLY to this project and should never be synced to other projects.

`/sync-dev-kit` never reads the kit's `rules/project/` tree, so nothing you write here is ever compared against the kit or overwritten by it.

## Examples

- Project-specific conventions not shared with other projects
- Custom workflows unique to this repo
- Integration rules for project-specific tools

## The one file the kit seeds here

`ui-inventory.md` — the enumeration of this project's UI components and patterns, auto-loaded on every `.tsx` / `.jsx` edit. The kit ships it (from `_claude-project/templates/ui-inventory.md`) in `merge` mode: the project owns everything inside its `project:begin` / `project:end` regions, the kit owns the headings and instructions around them, and a later kit change to that text applies without touching the project's lists. Everything else in this directory is yours alone.
