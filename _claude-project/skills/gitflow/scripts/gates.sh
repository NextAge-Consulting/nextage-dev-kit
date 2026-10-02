#!/bin/bash
# gitflow gates: the local checks /commit, /ship-main and /merge run before they
# act. Sourced by commit.sh, ship-main.sh and merge.sh.
#
# Every gate passes (return 0) or fails (return 4, or 15 for the build gate), and
# says which: what it inspected, how much, or why it does not apply here. A gate
# that cannot run — its tool missing, its file list unreadable — fails. It never
# reports success it did not earn.
#
# <action> finishes each failure sentence: "Fix before <action>."
#
# Each gate runs from the repository root, as the scripts that source this do.

# has_typescript_sources — whether the repository holds TypeScript of its own: a
# .ts, .tsx, .mts or .cts file git sees, outside node_modules, .claude and dist. The
# root knip.config.ts is the kit's, read by knip, not the project's source. When
# git cannot answer, the answer is yes: the check then applies, as it always did.
# CI's `check-types` job asks the same question the same way.
has_typescript_sources() {
    local files own
    files=$(git ls-files --cached --others --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts' 2>/dev/null) || return 0
    own=$(printf '%s\n' "$files" | grep -vE '(^|/)(node_modules|\.claude|dist)/' | grep -vxF 'knip.config.ts')
    [ -n "$own" ]
}

# pyright_pin — the pyright version the stack manifest pins, or nothing.
pyright_pin() {
    [ -f .claude/stack-manifest.json ] || return 0
    jq -r '.packages.pyright.version // "" | strings' .claude/stack-manifest.json 2>/dev/null
}

# run_typecheck_gate <skip 0|1> <action>
#
# Node and Python are independent: a repo with both checks both.
#
# A root package.json applies when it declares a `check-types` script or the
# repository has TypeScript sources; then a missing script FAILS, as CI's
# `check-types` job does — passing here would only move that failure to the open
# PR. With neither, the check does not apply, and the gate says so.
#
# A root pyproject.toml or pyrightconfig.json runs pyright, else mypy — the second
# is the root config of a repo whose Python lives in services/*/ (python-rules.md).
# With neither checker installed it FAILS,
# like the biome and semgrep gates below: this gate is the only Python typecheck
# gitflow has, and a gate that cannot run must not report success. An installed
# pyright other than the stack manifest's pin warns, naming both: CI runs the pin,
# so the two can disagree about the same code.
run_typecheck_gate() {
    local skip="$1" action="$2" ran=0 check_types pin installed
    if [ "$skip" -eq 1 ]; then
        echo "gitflow: typecheck: skipped — --skip-typecheck was passed." >&2
        return 0
    fi

    if [ -f "package.json" ]; then
        if ! check_types=$(jq -r '.scripts["check-types"] // "" | strings' package.json 2>&1); then
            echo "" >&2
            echo "gitflow: typecheck cannot read package.json: $check_types" >&2
            echo "  A gate that cannot run must not report success, so this is a failure." >&2
            return 4
        fi
        if [ -z "$check_types" ] && ! has_typescript_sources; then
            echo "gitflow: check-types does not apply: no TypeScript sources." >&2
        elif [ -z "$check_types" ]; then
            echo "" >&2
            echo "gitflow: package.json has no \"check-types\" script, and CI runs \`npm run check-types\`" >&2
            echo "  on every repository with a root package.json — the PR would fail there." >&2
            echo "  Fix: add a \"check-types\" script to package.json (for TypeScript: \"tsc --noEmit\")." >&2
            return 4
        else
            echo "gitflow: running npm run check-types..." >&2
            if ! npm run check-types >/dev/null 2>&1; then
                echo "" >&2
                echo "gitflow: TypeScript errors detected. Fix before $action." >&2
                echo "  Run: npm run check-types" >&2
                return 4
            fi
        fi
        ran=1
    fi

    if [ -f "pyproject.toml" ] || [ -f "pyrightconfig.json" ]; then
        if command -v pyright >/dev/null 2>&1; then
            pin=$(pyright_pin)
            installed=$(pyright --version 2>/dev/null | sed -nE 's/.*pyright ([0-9][^ ]*).*/\1/p' | head -1)
            if [ -n "$pin" ] && [ "$installed" != "$pin" ]; then
                echo "gitflow: warning: pyright ${installed:-of unknown version} is installed, but the stack manifest pins $pin, which CI runs." >&2
                echo "  The two can report different errors on the same code. Install the pin: pip install pyright==$pin" >&2
            fi
            echo "gitflow: running pyright..." >&2
            if ! pyright >/dev/null 2>&1; then
                echo "" >&2
                echo "gitflow: Python type errors. Fix before $action." >&2
                echo "  Run: pyright" >&2
                return 4
            fi
        elif command -v mypy >/dev/null 2>&1; then
            echo "gitflow: running mypy..." >&2
            if ! mypy . >/dev/null 2>&1; then
                echo "" >&2
                echo "gitflow: Python type errors. Fix before $action." >&2
                echo "  Run: mypy ." >&2
                return 4
            fi
        else
            echo "" >&2
            echo "gitflow: Python is configured (pyproject.toml or pyrightconfig.json), but neither pyright nor mypy is installed." >&2
            echo "  A gate that cannot run must not report success, so this is a failure." >&2
            echo "  Fix: npm install -g pyright   (or: pip install pyright)" >&2
            return 4
        fi
        ran=1
    fi

    if [ "$ran" -eq 0 ]; then
        echo "gitflow: typecheck: skipped — no package.json, pyproject.toml or pyrightconfig.json at the repository root." >&2
    fi
    return 0
}

# run_biome_gate <action>
#
# Gated on biome.json presence AND a root package.json. Mirrors the CI `biome`
# job so lint failures fire locally in <1s instead of on the PR 30s later. CI
# runs that job only when a root package.json exists (its `node` detection), and
# Biome can only be installed as a devDependency of one — so a project with the
# kit's biome.json but no Node stack skips this gate, exactly as CI does, rather
# than failing on a linter it has no way to install.
#
# ALWAYS `@biomejs/biome`, NEVER a bare `biome`, and always `--no-install`.
# `npx biome` resolves to an UNRELATED package of that name on npm (an
# environment-variable manager) which accepts `lint` as an unknown command and
# EXITS 0 — so this gate reported success without linting anything. Without
# `--no-install`, npx silently downloads whatever is latest, which is how a
# project's pinned schema version and the binary actually running it drift
# apart with nothing to say so.
#
# The pinned version is the one in the kit-owned biome.base.json's `$schema` URL;
# a project not yet split into base + seed carries it in biome.json instead.
biome_pinned_version() {
    local f url
    for f in biome.base.json biome.json biome.jsonc; do
        [ -f "$f" ] || continue
        # shellcheck disable=SC2016 # \$schema is the JSON key matched literally, not a shell expansion
        url=$(sed -nE 's#.*"\$schema"[[:space:]]*:[[:space:]]*"[^"]*/schemas/([0-9][^/"]*)/schema\.json".*#\1#p' "$f" | head -1)
        if [ -n "$url" ]; then
            printf '%s' "$url"
            return 0
        fi
    done
}

run_biome_gate() {
    local action="$1"
    if ! { [ -f "biome.json" ] || [ -f "biome.jsonc" ]; } || [ ! -f "package.json" ]; then
        echo "gitflow: biome: skipped — no biome.json with a root package.json." >&2
        return 0
    fi
    echo "gitflow: running biome lint..." >&2
    if ! npx --no-install @biomejs/biome --version >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: biome.json is present but @biomejs/biome is not installed." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        local pinned
        pinned=$(biome_pinned_version)
        if [ -n "$pinned" ]; then
            echo "  Fix: npm i -D @biomejs/biome@$pinned   (the version biome.base.json's \$schema names)" >&2
        else
            echo "  Fix: npm i -D @biomejs/biome@<the version biome.base.json's \$schema names>" >&2
        fi
        return 4
    fi
    if ! npx --no-install @biomejs/biome lint >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: Biome lint errors detected. Fix before $action." >&2
        echo "  Run: npx --no-install @biomejs/biome lint" >&2
        return 4
    fi
}

# semgrep_include_pattern <path> — the `--include` pattern matching exactly that
# repository-relative path. The leading `/` anchors it to the scan root, so
# `a.js` does not also select `src/a.js`; gitignore-syntax metacharacters and
# spaces are escaped so the path matches only itself.
semgrep_include_pattern() {
    printf '/%s' "$1" | sed 's/[][*?\\ ]/\\&/g'
}

# run_semgrep_gate <fold_base> <action>
#
# Mirrors the CI `semgrep` job, scoped to the files this commit touches.
#
# It is here because semgrep was the ONE CI gate with no local mirror, and that
# gap has a shape: every other check fires here in about a second, so a push is
# expected to reach CI green — which leaves semgrep as the only thing that can
# surprise you, after the PR is already open and a review has been triggered
# against a HEAD that is about to be replaced.
#
# Gated on CI actually declaring the job, so the local gate and the remote one can
# never disagree about whether this repo is scanned at all.
#
# CHANGED FILES ONLY, and that limit is real: a rule that fires on a file this
# commit does not touch still surfaces only in CI, which scans everything. This
# catches what you are about to INTRODUCE — the case that costs the round trip —
# and keeps the gate at seconds rather than the minute a full scan takes.
#
# The files are measured from <fold_base>, so content saved in checkpoints — which
# skipped every gate — is scanned too: tracked modifications plus untracked
# additions, minus deletions.
#
# Each file becomes an `--include` over a scan of the repository root, never a
# target named on the command line: semgrep scans a named target even when
# `.semgrepignore` excludes it, so naming files fails this gate on paths CI never
# scans. `--include` is applied after `.semgrepignore`, so the two agree.
run_semgrep_gate() {
    local base="$1" action="$2" list err f out scanned
    if [ ! -f ".github/workflows/ci.yml" ] || ! grep -qE '^[[:space:]]*semgrep:[[:space:]]*$' .github/workflows/ci.yml 2>/dev/null; then
        echo "gitflow: semgrep: skipped — CI declares no semgrep job." >&2
        return 0
    fi
    if ! command -v semgrep >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: CI runs semgrep, but semgrep is not installed here." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        echo "  Fix: brew install semgrep   (or: pipx install semgrep)" >&2
        return 4
    fi

    # NUL-separated, so a path git would quote is read as itself rather than
    # silently dropped. `mapfile` is deliberately not used: macOS ships bash 3.2
    # as /bin/bash and does not have it.
    list=$(mktemp)
    err=$(mktemp)
    if ! { git diff -z --name-only --diff-filter=d "$base" \
            && git ls-files -z --others --exclude-standard; } >"$list" 2>"$err"; then
        echo "" >&2
        echo "gitflow: semgrep cannot list the changed files (git diff against $base failed):" >&2
        sed 's/^/  /' "$err" >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        rm -f "$list" "$err"
        return 4
    fi
    local includes=() count=0
    while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        includes+=(--include "$(semgrep_include_pattern "$f")")
        count=$((count + 1))
    done < <(sort -zu "$list")
    rm -f "$list" "$err"

    if [ "$count" -eq 0 ]; then
        echo "gitflow: semgrep: no changed files." >&2
        return 0
    fi

    echo "gitflow: running semgrep on $count changed file(s)..." >&2
    # Output is captured and REPLAYED on failure rather than suppressed with a "run
    # it yourself" hint. A semgrep scan is tens of seconds; telling the user to pay
    # that twice to find out what was wrong is the kind of small tax that gets a
    # gate disabled.
    if ! out=$(semgrep scan --config auto --error "${includes[@]}" . 2>&1); then
        echo "" >&2
        echo "gitflow: Semgrep findings in the files this commit touches. Fix before $action." >&2
        echo "" >&2
        printf '%s\n' "$out" >&2
        return 4
    fi
    # semgrep's own summary says how many survived .semgrepignore; a file it
    # excludes is excluded in CI too.
    scanned=$(printf '%s\n' "$out" | sed -nE 's/.*Ran [0-9,]+ rules? on ([0-9,]+) files?.*/\1/p' | tail -1 | tr -d ,)
    if [ -n "$scanned" ] && [ "$scanned" -lt "$count" ]; then
        echo "gitflow: semgrep: $scanned of $count changed file(s) scanned — .semgrepignore excludes the rest — no findings." >&2
    elif [ -n "$scanned" ]; then
        echo "gitflow: semgrep: $scanned changed file(s) scanned, no findings." >&2
    else
        echo "gitflow: semgrep: $count changed file(s), no findings." >&2
    fi
}

# run_build_gate <repo_root>
#
# Builds every workspace that declares a `build` script — or, in a single-package
# repo, the root — and says how many that is. With none, it says so instead of
# reporting a build that never ran.
#
# `--workspaces` ERRORS with "No workspaces found!" on a single-package repo, so it
# is used only when the manifest actually declares them.
#
# jq, not grep: `grep '"workspaces"'` matches the substring ANYWHERE — a dependency
# of that name, a script, a description — and a false positive here blocks a merge
# that should have proceeded, which is how a gate ends up disabled. jq asks the exact
# question (top-level key, present or not) and handles both the array and object
# forms.
run_build_gate() {
    local root="$1" builds count scope
    if jq -e 'has("workspaces")' "$root/package.json" >/dev/null 2>&1; then
        scope="workspace"
        # `npm pkg get` answers per workspace: the script, or {} where there is none.
        if ! builds=$(cd "$root" && npm pkg get scripts.build --workspaces --json 2>&1) \
            || ! count=$(printf '%s' "$builds" | jq '[.[] | strings] | length' 2>/dev/null); then
            echo "merge.sh: could not read the workspaces' build scripts — nothing merged." >&2
            printf '%s\n' "$builds" | sed 's/^/  /' >&2
            return 15
        fi
        set -- --workspaces --if-present
    else
        scope="package"
        if ! count=$(jq '[.scripts.build? | strings] | length' "$root/package.json" 2>&1); then
            echo "merge.sh: could not read package.json — nothing merged: $count" >&2
            return 15
        fi
        set --
    fi

    if [ "$count" -eq 0 ]; then
        echo "gitflow: production build: no $scope declares a build script — nothing to build." >&2
        return 0
    fi

    echo "gitflow: running production build — $count $scope(s) declare a build script (npm run build $*)..." >&2
    if ! (cd "$root" && npm run build "$@"); then
        echo "merge.sh: production build FAILED — nothing merged." >&2
        echo "  Fix it on this branch and push; the PR is still open, so the fix lands" >&2
        echo "  in the PR that caused it rather than in a follow-up." >&2
        return 15
    fi
    echo "gitflow: production build OK — $count $scope(s) built." >&2
}
