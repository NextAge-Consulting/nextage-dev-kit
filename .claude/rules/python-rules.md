---
paths: "**/*.py"
---

# Python Rules

<!--
Loaded only when editing Python files. Universal rules in constitution.md.
-->

## I. Python Quality (Zero Tolerance)

**No type errors or lint violations in committed code.** Enforced by git pre-commit hook.

Ruff and type checker diagnostics are authoritative. Run via CLI (guaranteed) or LSP if connected (see constitution §IX and §X below for setup). These errors are NOT suggestions — they are quality failures.

| Forbidden Pattern | Why | Fix |
|-------------------|-----|-----|
| `# type: ignore` | Hides type errors | Fix the type issue |
| `# noqa` | Hides lint errors | Fix the lint issue |
| `Any` type | Disables type checking | Use proper types |
| Unused imports | Dead code | DELETE |

| Error | Fix |
|-------|-----|
| F401 (unused import) | DELETE |
| F841 (unused variable) | DELETE |
| E501 (line too long) | Reformat |
| Type mismatch | Fix at source |

## II. No Print Statements

**`print()` is FORBIDDEN in production code.** Enforced by PreToolUse hook.

Use Python's `logging` module with structured loggers.

```python
import logging
logger = logging.getLogger(__name__)

logger.info("Processing request", extra={"user_id": user_id})
logger.error("Request failed", exc_info=True, extra={"request_id": req_id})
logger.debug("Debug context", extra={"data": data})
```

**Log monitoring**: `tail -f logs/app.log`. Server lifecycle (start / never-kill / leave-running) is governed by `.claude/rules/dev-server.md`.

## III. Naming

| Convention | Rule |
|------------|------|
| Python variables / functions | `snake_case` |
| Classes | `PascalCase` |
| Constants | `UPPER_SNAKE_CASE` |

## IV. Timezone-Aware Code — Python Patterns

See constitution §VI for the principle. Python-specific forbidden patterns:

| Forbidden | Fix |
|-----------|-----|
| `datetime.now()` without tz | `datetime.now(tz)` with explicit timezone |
| `datetime.utcnow()` | Deprecated — use `datetime.now(timezone.utc)` |
| `date.today()` in user-facing code | Derive from timezone-aware `datetime.now(tz)` |
| Naive datetime into DB | Use tz-aware datetime; DB column should be `TIMESTAMPTZ` |

## V. Optional Handling

Use explicit `is None` checks:

```python
# ❌ WRONG - truthy check can miss valid falsy values
if user:
    process(user)

# ✅ CORRECT - explicit None check
if user is not None:
    process(user)
```

## VI. Type Narrowing

Use `isinstance` and type guards for safe narrowing:

```python
from typing import TypeGuard

def is_valid_user(obj: object) -> TypeGuard[User]:
    return isinstance(obj, User) and obj.email is not None
```

## VII. Async Best Practices

**Never block the event loop.**

| Forbidden | Use Instead |
|-----------|-------------|
| `time.sleep()` | `await asyncio.sleep()` |
| `requests.get()` | `httpx.AsyncClient` or `aiohttp` |
| Sync file I/O in async | `aiofiles` |
| Blocking DB calls | async drivers (asyncpg, etc.) |

### Task Groups (Python 3.11+)

```python
async with asyncio.TaskGroup() as tg:
    task1 = tg.create_task(fetch_user(user_id))
    task2 = tg.create_task(fetch_settings(user_id))
# Both complete or all cancelled on error
```

### Graceful Shutdown

Handle SIGTERM/SIGINT:

```python
async def shutdown():
    await db.close()
    await scheduler.shutdown()
```

## VIII. FastAPI Guidelines

### Dependency Injection

```python
async def get_db() -> AsyncGenerator[AsyncSession, None]:
    async with async_session() as session:
        yield session

@app.get("/users")
async def get_users(db: AsyncSession = Depends(get_db)):
    ...
```

### Pydantic Models

```python
from pydantic import BaseModel, Field

class UserCreate(BaseModel):
    email: str = Field(..., description="User email")
    name: str = Field(..., min_length=1)
```

## IX. Code Standards

- Python 3.11+ required
- Type hints on all functions

## X. LSP & CLI Setup

**LSP for Python requires Claude Code's official plugin + the pyright binary.** See constitution §IX for the general mechanism. One-time machine setup:

```bash
# 1. Install the Claude Code plugin
/plugin install pyright-lsp@claude-plugins-official

# 2. Install the language server binary
npm install -g pyright
# or: pip install pyright
```

**Verify binary + plugin:** `which pyright-langserver` must return a path. `/plugin list` must show `pyright-lsp`. If either is missing, LSP for Python is dead — fall back to CLI.

**Verify end-to-end:** Run LSP `documentSymbol`, `hover`, and `findReferences` against a known-good Python file. If all three return real results, LSP is working. Confirmed working on Claude Code 2.0.74+ (2026-04-17). See `project-documentation/claude-code-setup.md` §Python for the canonical fixture and expected results.

**CLI (always works, also what CI/pre-commit runs):**

- `pyright` — type check (or `mypy .` if the project standardizes on mypy)
- `ruff check .` — lint
- `ruff format .` — format

**Per-project config:**
- `pyrightconfig.json` at the REPO ROOT, OR `[tool.pyright]` in the root `pyproject.toml`
- `[tool.ruff]` in `pyproject.toml`

**Pyright reads config only from its own project root — the directory it is launched in.** Editors
and the LSP plugin launch it at the repo root. So in a repo whose Python lives in subdirectories
(`services/*/`, `packages/*/`), a `[tool.pyright]` block in a SUBDIRECTORY `pyproject.toml` is never
read and is silently inert: pyright falls back to the system interpreter and no `site-packages`, then
false-flags modern stdlib symbols (`datetime.UTC`) and reports every first-party and third-party
import as unresolvable. A correct-looking block in the wrong file reads as configured and is not.

- Put the config at the repo root. Verify with `pyright --outputjson | jq .summary` — check
  `filesAnalyzed` matches the real file count, not just that `errorCount` is 0.
- Multiple venvs under one root: pyright takes ONE project-level `venv`, so give each subtree an
  `executionEnvironments` entry whose `extraPaths` carries its `src` plus its venv's
  `site-packages`. (The docs also rank `venvPath`/`venv` as the least robust resolution mechanism.)
- Scope `include` to the SUBTREE ROOTS, not enumerated `src`/`tests` — enumerating silently exempts
  operational code (`scripts/`, `deploy/`) from ever being checked. Green because it wasn't looked at
  is not green.

**Per-project dev dependencies** (`pyproject.toml` / `uv` / `pip`):
- `ruff` — always
- `pyright` or `mypy` — pick one; match the CI config
- Pinned exact and identical across services — see §XI.

## XI. Dependency & Environment Discipline

**Two kinds of dependency, two opposite rules.** Conflating them is the mistake — one is a library
the code needs, the other is the gate that judges the code.

**Runtime dependencies are per-service and independent.** One venv per service/package, each with
its own `pyproject.toml` and lockfile. Services that don't import each other have no reason to agree
on their libraries; forcing agreement couples them for nothing.

**Shared dev tooling is pinned EXACT and IDENTICAL in every service** — ruff, the type checker, the
test runner, anything used by more than one.

| Rule | Why |
|------|-----|
| `ruff==X.Y.Z`, same version everywhere. Never `>=` for a linter/formatter/type checker | A linter is the GATE, not a library. With a floor, each service locks whatever was current the day it was last resolved — then a rule added in a patch release fails code nobody touched, in ONE service only |
| Bump the pin in every service in the SAME change | A one-service bump silently re-opens the split |
| Pin the interpreter with `.python-version` in EVERY service | `requires-python = ">=3.11"` is a floor, not a pin. Without the file, `uv` picks any compatible interpreter installed — so one service lands on 3.13 while its sibling stays on 3.11, on the same machine |
| Match the pinned interpreter to the DEPLOY target | An interpreter that only exists on the dev machine is a bug you discover in production |

**Do NOT reach for a `uv` workspace to fix cross-service drift.** uv scopes workspaces to
*interconnected* packages sharing one lockfile and one venv, and explicitly excludes members that
"desire a separate virtual environment for each member." For independent services one shared venv is
actively harmful: uv cannot prevent service A importing a dependency only service B declares, so it
passes every local test and then fails wherever A is deployed on its own.

## XII. Development Commands

- `python -m pytest` — Run tests
- `ruff check .` — Lint
- `ruff format .` — Format
- `pyright` or `mypy .` — Type checking

## XIII. Code Health

- F401 (unused import) / F841 (unused variable)
- Check for indirect usage before deleting flagged code
