#!/bin/bash
# gitflow gates: the local checks /commit, /ship-main, /merge and /deploy run before
# they act. Sourced by commit.sh, ship-main.sh, merge.sh and deploy.sh.
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
# CI's `check-types` step asks the same question the same way.
has_typescript_sources() {
    local files own
    files=$(git ls-files --cached --others --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts' 2>/dev/null) || return 0
    # An empty list needs no early return: $(…) strips the lone newline, so own is empty.
    own=$(printf '%s\n' "$files" | grep -vE '(^|/)(node_modules|\.claude|dist)/' | grep -vxF 'knip.config.ts')
    [ -n "$own" ]
}

# ─── Skipping a gate whose code has not changed ────────────────────────────────
#
# A gate that passed records the code fingerprint it passed on (code-fingerprint.mjs:
# one hash of the tree, comments and whitespace left out of TypeScript and JavaScript,
# every other file byte for byte). The next run on the same fingerprint skips the gate,
# saying so: nothing a check can see has changed since it passed. Only a pass is
# recorded, so a failure runs again every time. The record is the last pass of each
# gate, kept under the worktree's git dir (gitflow-pass/typecheck, …/integration,
# …/production-build), never in the tree.
#
# Everything a gate's answer depends on is in the tree — its configuration, the kit's
# own scripts, the lockfile — so it is in the fingerprint too. Without node, or when the
# fingerprint cannot be computed, the gate runs, saying why.

# gate_fingerprint <dir> <gate> — prints the fingerprint of the working tree at <dir>,
# or says why there is none and fails.
gate_fingerprint() {
    local dir="$1" gate="$2" script err fp note
    script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/code-fingerprint.mjs"
    if ! command -v node >/dev/null 2>&1; then
        echo "gitflow: $gate: no code fingerprint (node is not installed) — it runs every time." >&2
        return 1
    fi
    if [ ! -f "$script" ]; then
        echo "gitflow: $gate: no code fingerprint ($script is missing) — it runs every time." >&2
        return 1
    fi
    if ! err=$(mktemp); then
        echo "gitflow: $gate: no code fingerprint (no temporary file) — it runs every time." >&2
        return 1
    fi
    if ! fp=$(node "$script" -C "$dir" 2>"$err"); then
        echo "gitflow: $gate: no code fingerprint — it runs every time:" >&2
        sed 's/^/  /' "$err" >&2
        rm -f "$err"
        return 1
    fi
    note=$(cat "$err")
    rm -f "$err"
    if ! printf '%s' "$fp" | grep -qxE '[0-9a-f]{32}'; then
        echo "gitflow: $gate: no code fingerprint (code-fingerprint.mjs printed none) — it runs every time." >&2
        return 1
    fi
    case "$note" in *"could not be loaded"*) printf 'gitflow: %s: %s\n' "$gate" "${note#code-fingerprint: }" >&2 ;; esac
    printf '%s\n' "$fp"
}

# gate_pass_path <dir> <gate> — prints the record's absolute path.
gate_pass_path() {
    (cd "$1" && git rev-parse --path-format=absolute --git-path "gitflow-pass/${2// /-}")
}

# gate_unchanged <dir> <gate> <key> — succeeds, saying so, when the last pass of <gate>
# had <key>.
gate_unchanged() {
    local path
    [ -n "$3" ] || return 1
    path=$(gate_pass_path "$1" "$2" 2>/dev/null) || return 1
    [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$3" ] || return 1
    echo "gitflow: $2: code unchanged since the last pass (comments and whitespace only) — $2 skipped." >&2
}

# gate_record_pass <dir> <gate> <key> — records a pass. A record that cannot be written
# costs only the next run's skip, so it warns and the gate still passes.
gate_record_pass() {
    local path
    [ -n "$3" ] || return 0
    if path=$(gate_pass_path "$1" "$2" 2>/dev/null) \
        && mkdir -p "$(dirname "$path")" 2>/dev/null && printf '%s\n' "$3" >"$path" 2>/dev/null; then
        return 0
    fi
    echo "gitflow: $2 passed, but the pass could not be recorded under the git dir — the next run checks again." >&2
    return 0
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
# `check-types` step does — passing here would only move that failure to the open
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
    local skip="$1" action="$2" ran=0 check_types pin installed fp=""
    if [ "$skip" -eq 1 ]; then
        echo "gitflow: typecheck: skipped — --skip-typecheck was passed." >&2
        return 0
    fi
    if [ -f "package.json" ] || [ -f "pyproject.toml" ] || [ -f "pyrightconfig.json" ]; then
        if fp=$(gate_fingerprint . typecheck) && gate_unchanged . typecheck "$fp"; then
            return 0
        fi
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
        return 0
    fi
    gate_record_pass . typecheck "$fp"
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

# knip_pin — the knip version the stack manifest pins, or nothing.
knip_pin() {
    [ -f .claude/stack-manifest.json ] || return 0
    jq -r '.packages.knip.version // "" | strings' .claude/stack-manifest.json 2>/dev/null
}

# run_knip_gate <action>
#
# Unused code — the CI `knip` step, run before the push rather than after it. It
# applies exactly where that job does: a root package.json, and KNIP_GATE set to
# "true" in .claude/sync-substitutions.json. A repository that has not reached
# zero findings leaves KNIP_GATE unset, and the gate says so and passes, as CI
# does.
#
# The version is the stack manifest's — the one CI runs — because another knip
# reads the kit's knip.config.ts differently. knip exits 1 on any finding and 2
# when it cannot run; both fail.
run_knip_gate() {
    local action="$1" gate version
    if [ ! -f "package.json" ]; then
        echo "gitflow: knip: skipped — no root package.json." >&2
        return 0
    fi
    gate=""
    if [ -f .claude/sync-substitutions.json ]; then
        gate=$(jq -r '.KNIP_GATE // "" | strings' .claude/sync-substitutions.json 2>/dev/null)
    fi
    if [ "$gate" != "true" ]; then
        echo "gitflow: knip: skipped — KNIP_GATE is not \"true\" in .claude/sync-substitutions.json." >&2
        return 0
    fi
    version=$(knip_pin)
    if [ -z "$version" ]; then
        echo "" >&2
        echo "gitflow: KNIP_GATE is on but .claude/stack-manifest.json pins no knip version." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        return 4
    fi
    echo "gitflow: running knip $version..." >&2
    local out rc=0
    out=$(npx --yes "knip@$version" --no-progress --no-config-hints --reporter symbols 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "" >&2
        printf '%s\n' "$out" | grep -v 'injected env' >&2
        echo "" >&2
        if [ "$rc" -eq 1 ]; then
            echo "gitflow: knip found unused code. Fix before $action." >&2
        else
            echo "gitflow: knip could not run (exit $rc). Fix before $action." >&2
        fi
        echo "  Run: npx --yes knip@$version --no-progress --no-config-hints --reporter symbols" >&2
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

# run_terraform_gate <fold_base> <action>
#
# Mirrors the fmt step of CI's `terraform` job, scoped to the .tf and .tfvars
# files this change touches. Formatting needs no credentials, no providers and no
# network, so it is the part of that job worth paying for on every commit;
# `validate` downloads providers and stays in CI.
run_terraform_gate() {
    local base="$1" action="$2" list err f out
    list=$(mktemp)
    err=$(mktemp)
    if ! { git diff -z --name-only --diff-filter=d "$base" \
            && git ls-files -z --others --exclude-standard; } >"$list" 2>"$err"; then
        echo "" >&2
        echo "gitflow: terraform fmt cannot list the changed files (git diff against $base failed):" >&2
        sed 's/^/  /' "$err" >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        rm -f "$list" "$err"
        return 4
    fi
    local files=()
    while IFS= read -r -d '' f; do
        case "$f" in
            */.terraform/*|.terraform/*) continue ;;
            *.tf|*.tfvars) [ -f "$f" ] && files+=("$f") ;;
        esac
    done < <(sort -zu "$list")
    rm -f "$list" "$err"

    if [ "${#files[@]}" -eq 0 ]; then
        echo "gitflow: terraform fmt: no changed .tf files." >&2
        return 0
    fi
    if ! command -v terraform >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: ${#files[@]} changed Terraform file(s), but terraform is not installed here." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        echo "  Fix: brew install hashicorp/tap/terraform" >&2
        return 4
    fi
    if ! out=$(terraform fmt -check -diff "${files[@]}" 2>&1); then
        echo "" >&2
        echo "gitflow: Terraform files are not formatted. Fix before $action." >&2
        printf '%s\n' "$out" | sed 's/^/  /' >&2
        echo "  Run: terraform fmt ${files[*]}" >&2
        return 4
    fi
    echo "gitflow: terraform fmt: ${#files[@]} changed file(s) formatted." >&2
}

# run_terraform_lock_gate <fold_base> <action>
#
# A .terraform.lock.hcl this change touches must be locked for every platform that
# runs Terraform here — CI's linux_amd64 and the developers' darwin_arm64 and
# darwin_amd64 — or CI's `init -lockfile=readonly` fails on Linux. A provider locked
# for all three carries an h1: hash for each; an init on one Mac leaves one. Reads the
# files only; needs no terraform.
run_terraform_lock_gate() {
    local base="$1" action="$2" list err f short bad="" count=0
    list=$(mktemp)
    err=$(mktemp)
    if ! { git diff -z --name-only --diff-filter=d "$base" \
            && git ls-files -z --others --exclude-standard; } >"$list" 2>"$err"; then
        echo "" >&2
        echo "gitflow: the lock-file check cannot list the changed files (git diff against $base failed):" >&2
        sed 's/^/  /' "$err" >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        rm -f "$list" "$err"
        return 4
    fi
    while IFS= read -r -d '' f; do
        case "$f" in
            */.terraform/*|.terraform/*) continue ;;
            .terraform.lock.hcl|*/.terraform.lock.hcl) ;;
            *) continue ;;
        esac
        [ -f "$f" ] || continue
        count=$((count + 1))
        if ! short=$(awk '
            /^provider "/ { name = $2; gsub(/"/, "", name); h1 = 0; next }
            /"h1:/        { h1++ }
            /^}/          { if (name != "" && h1 < 3) print name; name = "" }
        ' "$f" 2>&1); then
            echo "" >&2
            echo "gitflow: could not read $f to check its platforms: $short" >&2
            echo "  A gate that cannot run must not report success, so this is a failure." >&2
            return 4
        fi
        if [ -n "$short" ]; then bad="$bad $f"; fi
    done < <(sort -zu "$list")
    rm -f "$list" "$err"

    if [ "$count" -eq 0 ]; then
        echo "gitflow: terraform lock: no changed .terraform.lock.hcl." >&2
        return 0
    fi
    if [ -n "$bad" ]; then
        echo "" >&2
        echo "gitflow: these lock files are not locked for every platform, so CI on Linux cannot verify them:$bad" >&2
        for f in $bad; do
            echo "  Run: terraform -chdir=$(dirname "$f") providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64" >&2
        done
        echo "  Fix before $action." >&2
        return 4
    fi
    echo "gitflow: terraform lock: $count changed lock file(s), locked for every platform." >&2
}

# run_integration_preflight <off_key> <action>
#
# Whether the integration tests' database is ready, asked FIRST by /deploy, while the
# person who ran it is still there. A database that needs a migration applied, or is not
# set up for tests at all, then stops the release at its first step instead of halfway
# through a deploy left running unattended. /commit and /ship-main do not call it: their
# integration gate's own vitest run reports the same refusal. It runs the root
# package.json's `test:preflight` script; what that checks belongs to the project's
# integration harness (the engine rule says what). It applies where the integration tests
# will run: a root package.json, DB_ENGINE not None, <off_key> not declared, and
# integration tests in the repository. A project that declares no `test:preflight`
# passes, saying so.
run_integration_preflight() {
    local off_key="$1" action="$2" engine="" off="" tests out
    if [ ! -f "package.json" ]; then
        echo "gitflow: integration preflight: skipped — no root package.json." >&2
        return 0
    fi
    if [ -f .claude/sync-substitutions.json ]; then
        engine=$(jq -r '.DB_ENGINE // "" | strings' .claude/sync-substitutions.json 2>/dev/null)
        off=$(jq -r --arg k "$off_key" '.[$k] // "" | strings' .claude/sync-substitutions.json 2>/dev/null)
    fi
    if [ "$engine" = "None" ]; then
        echo "gitflow: integration preflight: does not apply — DB_ENGINE is None." >&2
        return 0
    fi
    if [ -n "$off" ]; then
        echo "gitflow: integration preflight: declared off ($off_key) — $off" >&2
        return 0
    fi
    tests=$(git ls-files --cached --others --exclude-standard -- '*.integration.test.ts' '*.integration.test.tsx' '*.integration.test.mts' 2>/dev/null | { grep -vE '(^|/)node_modules/' || true; })
    if [ -z "$tests" ]; then
        echo "gitflow: integration preflight: the repository has no integration tests yet — no database to check." >&2
        return 0
    fi
    if ! jq -e '.scripts["test:preflight"] | strings' package.json >/dev/null 2>&1; then
        echo "gitflow: integration preflight: the project declares none (no \"test:preflight\" script)." >&2
        return 0
    fi
    if ! command -v npm >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: the integration preflight runs npm run test:preflight, and npm is not installed here." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        return 4
    fi
    echo "gitflow: integration preflight: running npm run test:preflight..." >&2
    if ! out=$(npm run --silent test:preflight 2>&1); then
        echo "" >&2
        printf '%s\n' "$out" >&2
        echo "gitflow: the integration tests' database is not ready. Fix before $action." >&2
        return 4
    fi
    echo "gitflow: integration preflight: the integration tests' database is ready." >&2
}

# run_integration_gate <fold_base> <action>
#
# The integration tier at the commit (testing-verification.md). The coverage check
# judges the exported functions this change touched (scripts/check-integration-coverage.mjs),
# then the integration tests whose import graph reaches a changed file run, through
# `vitest related`. It applies to a repository with a root package.json; DB_ENGINE
# "None" and a declared INTEGRATION_COMMIT_OFF stand it down, saying why. A repository
# with integration tests whose integration project does not run here fails: the tests
# exist, so a pass would be one they never earned. A database the tests cannot use is
# reported by this run: the harness's globalSetup refuses before any test connects,
# naming the fix, and the gate prints that output whole. When no integration test
# reaches the change, vitest starts no globalSetup and nothing touches the database.
run_integration_gate() {
    local base="$1" action="$2" engine="" off="" shared="" out rc=0 list err f tests fp key=""
    if [ ! -f "package.json" ]; then
        echo "gitflow: integration: skipped — no root package.json." >&2
        return 0
    fi
    if [ -f .claude/sync-substitutions.json ]; then
        engine=$(jq -r '.DB_ENGINE // "" | strings' .claude/sync-substitutions.json 2>/dev/null)
        off=$(jq -r '.INTEGRATION_COMMIT_OFF // "" | strings' .claude/sync-substitutions.json 2>/dev/null)
        shared=$(jq -r '.SHARED_MODULE_DIR // "" | strings' .claude/sync-substitutions.json 2>/dev/null)
    fi
    if [ "$engine" = "None" ]; then
        echo "gitflow: integration: does not apply — DB_ENGINE is None." >&2
        return 0
    fi
    if [ -n "$off" ]; then
        echo "gitflow: integration: declared off at commit (INTEGRATION_COMMIT_OFF) — $off" >&2
        return 0
    fi
    if [ ! -f "scripts/check-integration-coverage.mjs" ]; then
        echo "" >&2
        echo "gitflow: scripts/check-integration-coverage.mjs is missing, so the integration tier cannot be checked." >&2
        echo "  A gate that cannot run must not report success, so this is a failure. Run /sync-dev-kit." >&2
        return 4
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: the integration coverage check needs node, which is not installed here." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        return 4
    fi
    # The coverage check and the tests both measure from <fold_base>, so a pass holds for
    # this code measured from this base.
    if fp=$(gate_fingerprint . integration) && key="$fp $(git rev-parse "$base" 2>/dev/null)" \
        && gate_unchanged . integration "$key"; then
        return 0
    fi
    if ! out=$(node scripts/check-integration-coverage.mjs --base "$base" 2>&1); then
        echo "" >&2
        printf '%s\n' "$out" >&2
        echo "gitflow: integration coverage. Fix before $action." >&2
        return 4
    fi
    printf 'gitflow: %s\n' "$out" >&2

    tests=$(git ls-files --cached --others --exclude-standard -- '*.integration.test.ts' '*.integration.test.tsx' '*.integration.test.mts' 2>/dev/null | { grep -vE '(^|/)node_modules/' || true; })
    if [ -z "$tests" ]; then
        echo "gitflow: integration: the repository has no integration tests yet — none to run." >&2
        gate_record_pass . integration "$key"
        return 0
    fi

    list=$(mktemp)
    err=$(mktemp)
    if ! { git diff -z --name-only --diff-filter=d "$base" -- '*.ts' '*.tsx' '*.mts' '*.cts' \
            && git ls-files -z --others --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts'; } >"$list" 2>"$err"; then
        echo "" >&2
        echo "gitflow: the integration gate cannot list the changed files (git diff against $base failed):" >&2
        sed 's/^/  /' "$err" >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        rm -f "$list" "$err"
        return 4
    fi
    local files=()
    while IFS= read -r -d '' f; do
        case "$f" in node_modules/*|*/node_modules/*) continue ;; esac
        [ -f "$f" ] && files+=("$f")
    done < <(sort -zu "$list")
    rm -f "$list" "$err"
    if [ "${#files[@]}" -eq 0 ]; then
        echo "gitflow: integration: no TypeScript changed — no integration test to run." >&2
        gate_record_pass . integration "$key"
        return 0
    fi

    local config=()
    if [ -n "$shared" ] && [ -f "${shared%/}/vitest.config.ts" ]; then
        config=(-c "${shared%/}/vitest.config.ts")
    fi
    echo "gitflow: running the integration tests that reach ${#files[@]} changed file(s)..." >&2
    # INTEGRATION_DEV_TESTS=1 brings the development tests (*.dev.integration.test.ts) into
    # this run, the one place they run outside a developer naming them (vitest.config.ts).
    out=$(INTEGRATION_DEV_TESTS=1 npx --no-install vitest related --run --project integration ${config[@]+"${config[@]}"} "${files[@]}" 2>&1) || rc=$?
    if printf '%s\n' "$out" | grep -qF 'No projects matched the filter "integration"'; then
        echo "" >&2
        echo "gitflow: the repository has integration tests, but no integration project runs here, so they cannot." >&2
        echo "  On PostgreSQL: set NEON_API_KEY and NEON_PROJECT_ID in .env (testing.md §1)." >&2
        echo "  On another engine: register the project's integration project in test/project.ts (the engine rule says how)." >&2
        echo "  Fix before $action." >&2
        return 4
    fi
    if [ "$rc" -ne 0 ]; then
        echo "" >&2
        printf '%s\n' "$out" >&2
        echo "gitflow: the integration tests failed, or their database is not ready — the output above says which. Fix before $action." >&2
        return 4
    fi
    # "No affected test files found" when tests exist but none reaches the change, and
    # "No test files found" from a vitest that does not draw that distinction.
    if printf '%s\n' "$out" | grep -qE 'No (affected )?test files found'; then
        echo "gitflow: integration: no integration test reaches the ${#files[@]} changed file(s)." >&2
    else
        echo "gitflow: integration: the tests reaching the ${#files[@]} changed file(s) pass." >&2
    fi
    gate_record_pass . integration "$key"
}

# run_project_gate <fold_base> <action>
#
# The repository's own checks, beyond the ones every project shares: when
# .claude/project-gate.sh exists, it runs from the repository root with <fold_base>,
# the commit the change is measured from, and a non-zero exit fails the gate. A
# repository without one passes, saying so.
run_project_gate() {
    local base="$1" action="$2"
    if [ ! -f ".claude/project-gate.sh" ]; then
        echo "gitflow: project gate: none (.claude/project-gate.sh does not exist)." >&2
        return 0
    fi
    echo "gitflow: running the project gate (.claude/project-gate.sh)..." >&2
    if ! bash .claude/project-gate.sh "$base"; then
        echo "" >&2
        echo "gitflow: the project gate failed (.claude/project-gate.sh). Fix before $action." >&2
        return 4
    fi
}

# run_fit_check_gate <action>
#
# Every pending component carries, on its inventory line, the fit check that approved
# it as it stands (the design-system skill's references/fit-check.md). A component
# added or changed without one stops the commit here, while it is still one change
# away, not at the approval review.
run_fit_check_gate() {
    local action="$1" check=".claude/skills/ui-patterns/scripts/check-ui-status.mjs"
    if [ ! -f "$check" ]; then
        echo "gitflow: fit checks: not checked ($check does not exist)." >&2
        return 0
    fi
    if ! command -v node >/dev/null 2>&1; then
        echo "gitflow: fit checks cannot run: node is not installed. A gate that cannot run fails." >&2
        return 4
    fi
    if ! node "$check" --fit-only; then
        echo "" >&2
        echo "gitflow: a pending component has no fit check, or changed after it. Run the fit check before $action." >&2
        return 4
    fi
}

# run_headless_reviews <fold_base> <action>
#
# The five headless reviews — rule prose (rule-review.sh), new parts (part-review.sh), the
# design system (design-review.sh), hand-written SQL (sql-review.sh) and the tests of
# changed TypeScript (test-review.sh) — each measured from <fold_base>. Each makes one
# `claude -p` call only when its kind of file changed, and reuses its own earlier pass
# when its input is unchanged (review-cache.sh), so they run side by side: the gate takes
# as long as the slowest, not the sum.
#
# Each review's output is captured on its own and printed whole, in this fixed order,
# once all five have finished. Any review that fails fails the gate, and every review's
# output is still shown, so one run reports every finding. Each review's SKIP_*_REVIEW
# override reaches it through the environment.
run_headless_reviews() {
    local base="$1" action="$2" dir work name rc i=0 failed=""
    local names=(rule-review part-review design-review sql-review test-review) pids=()
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if ! work=$(mktemp -d); then
        echo "gitflow: the headless reviews cannot run: no temporary directory. Fix before $action." >&2
        return 4
    fi
    echo "gitflow: running the rule, part, design, SQL and test reviews side by side..." >&2
    for name in "${names[@]}"; do
        "$dir/$name.sh" "$base" >"$work/$name.out" 2>&1 &
        pids+=("$!")
    done
    for name in "${names[@]}"; do
        if wait "${pids[$i]}"; then rc=0; else rc=$?; fi
        i=$((i + 1))
        cat "$work/$name.out" >&2
        [ "$rc" -eq 0 ] || failed="$failed $name"
    done
    rm -rf "$work"
    if [ -n "$failed" ]; then
        echo "gitflow: headless review failed:$failed (output above). Fix before $action." >&2
        return 4
    fi
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
    local root="$1" builds count scope fp=""
    if jq -e 'has("workspaces")' "$root/package.json" >/dev/null 2>&1; then
        scope="workspace"
        # `npm pkg get` answers per workspace, {} where there is none. npm 11 and earlier
        # give the script as a string; npm 12 gives an object keyed "scripts.build".
        if ! builds=$(cd "$root" && npm pkg get scripts.build --workspaces --json 2>&1) \
            || ! count=$(printf '%s' "$builds" \
                | jq '[.[] | if type == "object" then .[] else . end | strings] | length' 2>/dev/null); then
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

    # Fingerprinted before the build, which may write files of its own.
    if fp=$(gate_fingerprint "$root" "production build") && gate_unchanged "$root" "production build" "$fp"; then
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
    gate_record_pass "$root" "production build" "$fp"
}
