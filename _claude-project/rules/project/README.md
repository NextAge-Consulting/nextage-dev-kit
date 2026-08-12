# Project-Specific Rules

This directory is for rules that apply ONLY to this project and should never be synced to other projects.

`/sync-dev-kit` never reads the kit's `rules/project/` tree, so nothing you write here is ever compared against the kit or overwritten by it.

## Examples

- Project-specific conventions not shared with other projects
- Custom workflows unique to this repo
- Integration rules for project-specific tools

## The one file the kit seeds here

`ui-inventory.md` — the enumeration of this project's UI components and patterns, auto-loaded on every `.tsx` / `.jsx` edit. The kit ships a starting shape (from `_claude-project/templates/ui-inventory.md`) in `template` mode: it arrives once, the project owns every line from then on, and a later kit change to the shape is shown as information only. Everything else in this directory is yours alone.
