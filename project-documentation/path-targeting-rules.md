# Path-Targeting Rules Reference

Claude Code's `.claude/rules/` directory supports **path-specific rules** via YAML frontmatter. Rules only load when Claude works on matching files.

## Why Path-Target?

**Problem**: All rules in `.claude/rules/` receive high priority. When everything loads every session, Claude can't distinguish what's relevant to the current task.

**Solution**: Path-targeting scopes when rules receive elevated attention. API rules only load for API files. Test rules only load for test files.

## Syntax

Add YAML frontmatter with `paths` field at the top of the rule file:

```markdown
---
paths: src/api/**/*.ts
---

# API Development Rules

These rules only load when working on API files.
```

Rules **without** `paths` frontmatter load unconditionally (universal rules).

## Glob Patterns

| Pattern | Matches |
|---------|---------|
| `**/*.ts` | All TypeScript files anywhere |
| `src/**/*` | All files under src/ |
| `*.md` | Markdown files in project root only |
| `src/components/*.tsx` | Direct children of components/ only |
| `**/*.test.ts` | All test files anywhere |

### Multiple Patterns

**Brace expansion** for similar patterns:
```yaml
---
paths: src/**/*.{ts,tsx}
---
```
Matches both `.ts` and `.tsx` files.

**Comma-separated** for different patterns:
```yaml
---
paths: src/**/*.ts, tests/**/*.test.ts
---
```

**Multiple directories**:
```yaml
---
paths: {src,lib}/**/*.ts
---
```

### Array syntax (alternative)
```yaml
---
paths:
  - src/api/**/*.ts
  - src/lib/serverFunctions/**/*.ts
---
```

## When to Path-Target

**DO path-target**:
- Framework-specific rules (TanStack, React, etc.)
- Testing conventions (only for test files)
- API/backend rules (only for API files)
- Heavy documentation that adds context bloat

**DON'T path-target**:
- Constitution/core rules (always apply)
- Git workflow rules (always apply)
- Security rules (always apply)
- Naming conventions (always apply)

## Example: Domain-Specific Rules

### TanStack Routes
```markdown
---
paths: **/routes/**/*.ts, **/routes/**/*.tsx
---

# Route File Rules

- Only export createFileRoute() or API handlers
- No component definitions in route files
- Use loaderDeps for parameter dependencies
```

### Server Functions
```markdown
---
paths: **/serverFunctions/**/*.ts, **/server/**/*.ts
---

# Server Function Rules

- Always use { data: params } destructuring
- Include proper auth middleware
- Tree-shake Node.js imports with serverOnly
```

### Test Files
```markdown
---
paths: **/*.test.ts, **/*.spec.ts, **/tests/**/*.ts
---

# Testing Rules

- Mock external services, never real APIs
- One assertion per test when possible
- Use descriptive names: "should [action] when [condition]"
```

### UI Components (shadcn)
```markdown
---
paths: **/*.tsx, **/*.css, **/tailwind.config.*, **/components.json
---

# UI Component Rules

- Use shadcn/ui primitives
- Semantic class names (ButtonActive not ButtonRed)
- Check shadcn MCP for component patterns
```

**Note**: Use `**/` prefix for monorepo compatibility. Patterns like `src/components/` break in monorepos where paths are `apps/web/src/components/`.

### Database/ORM
```markdown
---
paths: **/db/**/*.ts, **/schema.ts, **/migrations/**/*
---

# Database Rules

- Singular table names (user not users)
- Primary keys: {table}id with UUID v7
- Never run migrations without human approval
```

## Discovery Behavior

1. Rules in `.claude/rules/` are discovered recursively
2. Subdirectories are supported (e.g., `.claude/rules/frontend/react.md`)
3. Path-targeted rules only load when Claude reads/edits matching files
4. Universal rules (no paths) load at session start

## Precedence

```
Project .claude/rules/  →  Higher authority
User ~/.claude/rules/   →  Lower authority (overridable)
```

Project rules override user rules. This allows per-project customization.

## Debugging

Use `/memory` command during session to see which rule files are currently loaded.

## Migration Pattern

When converting universal rules to path-targeted:

1. Identify sections that only apply to specific file types
2. Extract to new file with appropriate `paths` frontmatter
3. Keep universal portions in original file
4. Test with `/memory` to verify loading behavior

## Common Path Patterns by Domain

All patterns use `**/` prefix for monorepo compatibility.

| Domain | Suggested Paths |
|--------|-----------------|
| React components | `**/*.tsx` |
| API routes | `**/api/**/*.ts`, `**/routes/api/**/*.ts` |
| Server functions | `**/serverFunctions/**/*.ts`, `**/server/**/*.ts` |
| Tests | `**/*.test.ts`, `**/*.spec.ts` |
| Styles | `**/*.css`, `**/tailwind.config.*` |
| Database | `**/db/**/*.ts`, `**/schema.ts` |
| Auth | `**/auth/**/*.ts`, `**/middleware/**/*.ts` |
| Config | `*.config.*`, `.env*` |

---

*Reference: [Claude Code Memory Docs](https://code.claude.com/docs/en/memory)*
*See also: indexed-context-optimization.md for broader context strategy*
