#!/usr/bin/env node
/**
 * Integration-test coverage check (see .claude/rules/testing-verification.md, "The
 * integration tier", and .claude/rules/drizzle.md §I).
 *
 *   node scripts/check-integration-coverage.mjs [--base <ref>] [--report-untested]
 *   node scripts/check-integration-coverage.mjs --sql-templates [--base <ref>]
 *
 * TWO RULES, both judged only on code changed since the base — the ratchet:
 *
 *   coverage  An exported function whose body queries the database has an
 *             integration test (*.integration.test.ts) that calls it, or carries
 *             `// integration-exempt: <reason>` above it.
 *   raw SQL   A `.execute(…)` on a database handle carries `// raw-sql: <reason>` on
 *             its line or above its statement.
 *
 * "Queries the database" means the body reads a property of a database handle —
 * `db.select`, `tx.execute`, `pool.query` — whether the handle is a parameter, an
 * import or a call's result. A function that only passes a handle along does not
 * query, so a request wrapper around a tested data function is not judged. Handles
 * are recognised by TYPE, through TypeScript's checker: a Drizzle database or
 * transaction, or a driver's pool, client, connection or request.
 *
 * The base is --base, else INTEGRATION_COVERAGE_BASE, else where HEAD left
 * origin/main. Without one, every function is judged.
 *
 * --report-untested also counts the untouched exported functions that query the
 * database with no test. The count never fails the check; it falls as each one is
 * changed and therefore judged.
 *
 * --sql-templates prints, as JSON, every `sql` template on a changed line, for the
 * /commit SQL review. It applies wherever the code uses Drizzle.
 *
 * Stands down, saying why: DB_ENGINE "None", or no TypeScript in the repository. Whether
 * a place runs it at all is that place's switch (INTEGRATION_COMMIT_OFF in gates.sh,
 * INTEGRATION_CI_OFF in ci.yml).
 *
 * Exit 0: clean, or does not apply. Exit 1: findings. Exit 2: the check cannot run.
 */

import { execFileSync, spawnSync } from "node:child_process";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Real path: TypeScript reports file names with symlinks resolved, and they are compared with it.
const repo = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), ".."));
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(name);
const option = (name) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const NAME = "check-integration-coverage";

function fail(message) {
  console.error(`✗ ${NAME}: ${message}`);
  process.exit(2);
}

function git(...args) {
  return execFileSync("git", ["-C", repo, ...args], { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
}

// --- configuration ----------------------------------------------------------------

function substitutions() {
  const file = join(repo, ".claude/sync-substitutions.json");
  if (!existsSync(file)) return {};
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    fail(`.claude/sync-substitutions.json is not valid JSON (${error.message})`);
  }
}

let typescript = null;
/** TypeScript, from the repository, else the global npm root. */
function loadTypeScript() {
  if (typescript) return typescript;
  const usable = (from) => {
    try {
      const ts = createRequire(from)("typescript");
      return typeof ts?.createProgram === "function" ? ts : null;
    } catch {
      return null;
    }
  };
  typescript = usable(join(repo, "package.json"));
  if (typescript) return typescript;
  let root = "";
  try {
    root = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
  } catch {}
  typescript = root ? usable(join(root, "noop.js")) : null;
  if (!typescript) fail("TypeScript is not installed in the repository or globally — this check reads source with it (npm i -D typescript)");
  return typescript;
}

// --- which files ------------------------------------------------------------------

const TS = ["*.ts", "*.tsx", "*.mts", "*.cts"];
const OUTSIDE = /(^|\/)(node_modules|\.claude|dist|build|coverage)\//;
const TEST_DIR = /(^|\/)(test|tests|__tests__|e2e)\//;
const INTEGRATION_TEST = /\.integration\.test\.[cm]?tsx?$/;

function trackedTypeScript() {
  return git("ls-files", "--cached", "--others", "--exclude-standard", "--", ...TS)
    .split("\n")
    .filter((f) => f && !OUTSIDE.test(f) && existsSync(join(repo, f)));
}

const isSource = (f) => !f.endsWith(".d.ts") && !/\.(test|spec)\.[cm]?tsx?$/.test(f) && !TEST_DIR.test(f);

/** Every file and line changed since `base`, tracked or not: a Map of file to its changed
 * line numbers, or to ALL for a file git does not track yet. A moved file is judged by its
 * edits, not as new. */
const ALL = "all";
function changedLines(base) {
  const out = new Map();
  let file = null;
  const addHunks = (diff, as) => {
    for (const line of diff.split("\n")) {
      if (line.startsWith("+++ ")) file = as ?? line.slice(4).replace(/^b\//, "");
      const m = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/);
      if (!m || !file || file === "/dev/null") continue;
      if (!out.has(file)) out.set(file, new Set());
      for (let n = Number(m[1]), end = n + Number(m[2] ?? 1); n < end; n++) out.get(file).add(n);
    }
  };
  addHunks(git("diff", "-M", "-U0", "--no-color", base, "--", ...TS));
  const deleted = git("diff", "-M", "--name-only", "--diff-filter=D", base, "--", ...TS).split("\n").filter(Boolean);
  const claimed = new Set();
  for (const f of git("ls-files", "--others", "--exclude-standard", "--", ...TS).split("\n")) {
    if (!f) continue;
    const from = deleted.find((d) => !claimed.has(d) && d.split("/").pop() === f.split("/").pop());
    if (!from) {
      out.set(f, ALL);
      continue;
    }
    claimed.add(from);
    const r = spawnSync("git", ["-C", repo, "diff", "--no-index", "-U0", "--no-color", "-", f], {
      input: git("show", `${base}:${from}`),
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
    });
    if (r.status !== 0 && r.status !== 1) throw new Error(`git diff --no-index ${from} ${f}: ${r.stderr.trim()}`);
    out.set(f, new Set());
    addHunks(r.stdout, f);
  }
  return out;
}

/** The ref changes are measured from, or null when there is none to measure from. */
function baseRef() {
  const given = option("--base") ?? (process.env.INTEGRATION_COVERAGE_BASE || undefined);
  try {
    const ref = given ?? execFileSync("git", ["-C", repo, "merge-base", "HEAD", "origin/main"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    execFileSync("git", ["-C", repo, "rev-parse", "--verify", "--quiet", `${ref}^{commit}`], { stdio: "ignore" });
    return ref;
  } catch {
    if (given) fail(`${given}: not a commit this repository has — the check needs it to know what changed`);
    return null;
  }
}

// --- programs ---------------------------------------------------------------------

/** The nearest tsconfig.json above a file, inside the repository, or null. */
function tsconfigFor(file) {
  for (let dir = dirname(join(repo, file)); ; dir = dirname(dir)) {
    const candidate = join(dir, "tsconfig.json");
    if (existsSync(candidate)) return candidate;
    if (dir === repo || dir === dirname(dir)) return null;
  }
}

const DEFAULT_OPTIONS = { target: 9, module: 99, moduleResolution: 100, jsx: 1, strict: true, skipLibCheck: true, noEmit: true, allowImportingTsExtensions: true };

/** One program per tsconfig, each rooted at the files it governs. */
function programs(files) {
  const ts = loadTypeScript();
  const groups = new Map();
  for (const f of files) {
    const config = tsconfigFor(f);
    if (!groups.has(config)) groups.set(config, []);
    groups.get(config).push(realpathSync(join(repo, f)));
  }
  const out = [];
  for (const [config, roots] of groups) {
    let options = DEFAULT_OPTIONS;
    if (config) {
      const read = ts.readConfigFile(config, ts.sys.readFile);
      if (read.error) fail(`${relative(repo, config)}: ${ts.flattenDiagnosticMessageText(read.error.messageText, " ")}`);
      options = ts.parseJsonConfigFileContent(read.config, ts.sys, dirname(config)).options;
    }
    out.push(ts.createProgram(roots, { ...options, noEmit: true }));
  }
  return out;
}

// --- reading source ---------------------------------------------------------------

// Drivers and query layers whose objects are database handles.
const DB_LIBRARY =
  /\/node_modules\/(drizzle-orm|pg|@types\/pg|postgres|mssql|@types\/mssql|tedious|@neondatabase\/serverless|mysql2|better-sqlite3|@types\/better-sqlite3|@libsql\/client|kysely|knex|@prisma\/client|\.prisma)\//;
// The handle types those libraries declare: a database, transaction or session; a driver's
// pool, client, connection or request. A table, column or SQL fragment is not a handle.
const HANDLE_NAME = /(Database|Transaction|Session|Pool|PoolClient|Client|Connection|ConnectionPool|Request|Kysely|Knex|PrismaClient)$|^Sql$/;

function isHandleType(ts, type, seen = new Set()) {
  if (!type || seen.has(type)) return false;
  seen.add(type);
  if (type.isUnionOrIntersection?.()) return type.types.some((t) => isHandleType(ts, t, seen));
  for (const symbol of [type.getSymbol?.(), type.aliasSymbol]) {
    if (!symbol || !HANDLE_NAME.test(symbol.getName())) continue;
    if ((symbol.getDeclarations() ?? []).some((d) => DB_LIBRARY.test(d.getSourceFile().fileName.replaceAll("\\", "/")))) return true;
  }
  return false;
}

/** The function-like node an exported declaration carries, or null. */
function functionBody(ts, decl) {
  if (ts.isFunctionDeclaration(decl)) return decl.body ? decl : null;
  if (!ts.isVariableDeclaration(decl) || !decl.initializer) return null;
  let found = null;
  const visit = (n) => {
    if (found) return;
    if (ts.isArrowFunction(n) || ts.isFunctionExpression(n)) found = n;
    else ts.forEachChild(n, visit);
  };
  visit(decl.initializer);
  return found ? decl.initializer : null;
}

const statementOf = (ts, decl) => (ts.isVariableDeclaration(decl) ? decl.parent.parent : decl);
const realOr = (file) => {
  try {
    return realpathSync(file);
  } catch {
    return file;
  }
};
const keyOf = (decl) => `${realOr(decl.getSourceFile().fileName)}#${decl.getStart()}`;
const lineOf = (sf, pos) => sf.getLineAndCharacterOfPosition(pos).line + 1;

/** The text of the comments directly above a node. */
function leadingComments(ts, node) {
  const sf = node.getSourceFile();
  const text = sf.getFullText();
  return (ts.getLeadingCommentRanges(text, node.getFullStart()) ?? []).map((r) => text.slice(r.pos, r.end)).join("\n");
}

// The marker, then its reason: the rest of the comment line, up to a closing `*/`.
const MARKERS = {
  "integration-exempt": /integration-exempt:[ \t]*(\S[^\n*]*)?/,
  "raw-sql": /raw-sql:[ \t]*(\S[^\n*]*)?/,
};
const markerReason = (text, name) => {
  const m = text.match(MARKERS[name]);
  return m ? (m[1] ?? "").trim() : null;
};

/** Every exported function a source file declares, with whether its body queries the
 * database and every handle `.execute(…)` call in it. */
function exportedFunctions(ts, program, sf) {
  const checker = program.getTypeChecker();
  const module = checker.getSymbolAtLocation(sf);
  if (!module) return [];
  const out = [];
  for (let symbol of checker.getExportsOfModule(module)) {
    if (symbol.flags & ts.SymbolFlags.Alias) symbol = checker.getAliasedSymbol(symbol);
    for (const decl of symbol.getDeclarations() ?? []) {
      if (decl.getSourceFile() !== sf) continue;
      const body = functionBody(ts, decl);
      if (!body) continue;
      let queries = false;
      const executes = [];
      const visit = (n) => {
        if (ts.isPropertyAccessExpression(n) && isHandleType(ts, checker.getTypeAtLocation(n.expression))) {
          queries = true;
          if (n.name.text === "execute" && ts.isCallExpression(n.parent) && n.parent.expression === n) executes.push(n);
        }
        ts.forEachChild(n, visit);
      };
      visit(body);
      const statement = statementOf(ts, decl);
      out.push({
        name: decl.name?.getText() ?? "default",
        key: keyOf(decl),
        start: lineOf(sf, statement.getStart()),
        end: lineOf(sf, statement.getEnd()),
        queries,
        executes,
        exempt: markerReason(leadingComments(ts, statement), "integration-exempt"),
      });
    }
  }
  return out;
}

/** Keys of every exported function an integration test file calls. */
function calledFrom(ts, program, sf, into) {
  const checker = program.getTypeChecker();
  const visit = (n) => {
    if (ts.isCallExpression(n)) {
      let symbol = checker.getSymbolAtLocation(ts.isPropertyAccessExpression(n.expression) ? n.expression.name : n.expression);
      if (symbol && symbol.flags & ts.SymbolFlags.Alias) symbol = checker.getAliasedSymbol(symbol);
      for (const decl of symbol?.getDeclarations() ?? []) into.add(keyOf(decl));
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
}

/** A handle `.execute(…)`'s `raw-sql:` reason: in a comment on its line, in the comment
 * lines directly above that line, or above the statement holding it. */
function rawSqlReason(ts, call) {
  let statement = call;
  while (statement.parent && !ts.isBlock(statement.parent) && !ts.isSourceFile(statement.parent)) statement = statement.parent;
  const sf = call.getSourceFile();
  const text = sf.getFullText();
  const lines = text.split("\n");
  const at = sf.getLineAndCharacterOfPosition(call.name.getStart()).line;
  const above = [];
  for (let n = at - 1; n >= 0 && /^\s*(\/\/|\/\*|\*)/.test(lines[n]); n--) above.push(lines[n]);
  const lineEnd = text.indexOf("\n", call.name.getEnd());
  const span = [leadingComments(ts, statement), ...above, text.slice(statement.getStart(), lineEnd < 0 ? undefined : lineEnd)].join("\n");
  const comments = (span.match(/\/\/[^\n]*|\/\*[\s\S]*?\*\//g) ?? []).join("\n");
  return markerReason(comments, "raw-sql");
}

// --- the check --------------------------------------------------------------------

const subs = substitutions();
const sqlTemplates = flag("--sql-templates");

if (!sqlTemplates) {
  if (subs.DB_ENGINE === "None") {
    console.log(`✓ ${NAME}: does not apply — DB_ENGINE is None, so the project has no database.`);
    process.exit(0);
  }
}

const all = trackedTypeScript();
const sources = all.filter((f) => isSource(f) && !INTEGRATION_TEST.test(f));
if (sources.length === 0) {
  if (sqlTemplates) console.log("[]");
  else console.log(`✓ ${NAME}: does not apply — the repository has no TypeScript source.`);
  process.exit(0);
}

const base = baseRef();
let changed;
try {
  changed = base ? changedLines(base) : new Map(sources.map((f) => [f, ALL]));
} catch (error) {
  fail(`cannot list what changed since ${base}: ${error.message}`);
}
const touches = (file, from, to) => {
  const lines = changed.get(file);
  if (!lines) return false;
  if (lines === ALL) return true;
  for (let n = from; n <= to; n++) if (lines.has(n)) return true;
  return false;
};
const since = base ? `since ${base.slice(0, 12)}` : "(no base to measure from — every function judged)";
const changedSources = sources.filter((f) => changed.has(f));

if (sqlTemplates) {
  const ts = loadTypeScript();
  const found = [];
  for (const program of changedSources.length ? programs(changedSources) : []) {
    const checker = program.getTypeChecker();
    for (const sf of program.getRootFileNames().map((f) => program.getSourceFile(f))) {
      if (!sf) continue;
      const file = relative(repo, sf.fileName).replaceAll("\\", "/");
      const visit = (n) => {
        if (ts.isTaggedTemplateExpression(n)) {
          let symbol = checker.getSymbolAtLocation(ts.isPropertyAccessExpression(n.tag) ? n.tag.expression : n.tag);
          if (symbol && symbol.flags & ts.SymbolFlags.Alias) symbol = checker.getAliasedSymbol(symbol);
          const fromDrizzle = (symbol?.getDeclarations() ?? []).some((d) => /\/node_modules\/drizzle-orm\//.test(d.getSourceFile().fileName.replaceAll("\\", "/")));
          const line = lineOf(sf, n.getStart());
          if (fromDrizzle && touches(file, line, lineOf(sf, n.getEnd()))) found.push({ file, line, text: n.getText() });
        }
        ts.forEachChild(n, visit);
      };
      visit(sf);
    }
  }
  console.log(JSON.stringify(found, null, 2));
  process.exit(0);
}

const tests = all.filter((f) => INTEGRATION_TEST.test(f));
const judged = flag("--report-untested") ? sources : changedSources;
if (changedSources.length === 0 && !flag("--report-untested")) {
  console.log(`✓ ${NAME}: no TypeScript source changed ${since} — nothing to judge (${sources.length} source file(s) in the repository).`);
  process.exit(0);
}

const ts = loadTypeScript();
const called = new Set();
const functions = [];
for (const program of programs([...judged, ...tests])) {
  for (const root of program.getRootFileNames()) {
    const sf = program.getSourceFile(root);
    if (!sf) continue;
    const file = relative(repo, sf.fileName).replaceAll("\\", "/");
    if (INTEGRATION_TEST.test(file)) calledFrom(ts, program, sf, called);
    else for (const fn of exportedFunctions(ts, program, sf)) functions.push({ ...fn, file, sf });
  }
}

const problems = [];
let inspected = 0;
let querying = 0;
let covered = 0;
let exempt = 0;
let executes = 0;
let untested = 0;
for (const fn of functions) {
  const isChanged = touches(fn.file, fn.start, fn.end);
  if (!isChanged) {
    if (fn.queries && fn.exempt === null && !called.has(fn.key)) untested++;
    continue;
  }
  inspected++;
  if (!fn.queries) continue;
  querying++;
  for (const call of fn.executes) {
    const line = lineOf(fn.sf, call.name.getStart());
    if (!touches(fn.file, line, line)) continue;
    executes++;
    if (!rawSqlReason(ts, call))
      problems.push(`${fn.file}:${line}  ${fn.name} — a whole query through .execute() with no reason — add \`// raw-sql: <what the query builder cannot express>\` above it, or write it with the query builder (drizzle.md §I)`);
  }
  if (fn.exempt !== null) {
    if (fn.exempt) exempt++;
    else problems.push(`${fn.file}:${fn.start}  ${fn.name} — \`integration-exempt:\` gives no reason — say why no integration test can call it`);
    continue;
  }
  if (called.has(fn.key)) covered++;
  else
    problems.push(`${fn.file}:${fn.start}  ${fn.name} — queries the database and no integration test calls it — call it from a *.integration.test.ts, or mark it \`// integration-exempt: <reason>\` (testing-verification.md)`);
}

const summary = `${inspected} changed exported function(s) in ${changedSources.length} changed file(s) inspected ${since}; ${querying} query the database — ${covered} called by an integration test, ${exempt} exempt; ${executes} changed .execute() call(s); ${tests.length} integration test file(s) read`;
if (flag("--report-untested"))
  console.log(`${NAME}: untouched code — ${untested} exported function(s) query the database with no integration test. Each is judged when it next changes.`);
if (problems.length) {
  console.error(`✗ ${NAME}: ${summary}.\n${problems.map((p) => `  ${p}`).join("\n")}`);
  process.exit(1);
}
console.log(`✓ ${NAME}: ${summary}.`);
