#!/usr/bin/env node
// Type-check every workspace concurrently — the root `check-types` of a repository that
// declares npm workspaces.
//
// Each workspace's own `check-types` script runs side by side rather than in turn, up to
// one per CPU. A workspace that fails has its output printed whole; the run says how many
// workspaces it checked and exits 1 when any failed.
//
// A workspace without a `check-types` script is counted and skipped. A declared workspace
// whose package.json cannot be read, a workspace glob that matches nothing, a repository
// with no workspaces and one where no workspace declares the script all fail: each leaves
// types unchecked while the gate would otherwise pass.
//
// Run: npm run check-types   (or node scripts/check-types.mjs; exit 1 on any failure)

import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function fail(message) {
  console.error(`✗ check-types: ${message}`);
  process.exit(1);
}

if (!existsSync(resolve(repoRoot, "package.json"))) {
  console.log("✓ check-types: no package.json — not a Node repo, so it does not apply.");
  process.exit(0);
}
const rootPkg = JSON.parse(readFileSync(resolve(repoRoot, "package.json"), "utf8"));

// npm workspaces is either an array of patterns or `{ packages: [...] }`.
const patterns = Array.isArray(rootPkg.workspaces) ? rootPkg.workspaces : (rootPkg.workspaces?.packages ?? []);
if (patterns.length === 0) {
  fail('package.json declares no "workspaces", so there is nothing to run — a single-package repository type-checks with its own tsc in "check-types".');
}

// Literal dirs ("apps/shop") and a trailing glob ("apps/*"), as check-dep-alignment.mjs
// reads them. A globbed folder without a package.json is not a workspace.
const workspaceDirs = [];
const emptyGlobs = [];
for (const pattern of patterns) {
  if (!pattern.endsWith("/*")) {
    workspaceDirs.push(pattern);
    continue;
  }
  const parent = pattern.slice(0, -2);
  const before = workspaceDirs.length;
  let entries = [];
  try {
    entries = readdirSync(resolve(repoRoot, parent), { withFileTypes: true });
  } catch {
    // parent folder absent — reported below with every other empty glob
  }
  for (const ent of entries) {
    if (ent.isDirectory() && existsSync(resolve(repoRoot, parent, ent.name, "package.json"))) {
      workspaceDirs.push(`${parent}/${ent.name}`);
    }
  }
  if (workspaceDirs.length === before) emptyGlobs.push(pattern);
}
if (emptyGlobs.length > 0) {
  fail(`declared workspace pattern(s) match no package, so nothing under them is type-checked: ${emptyGlobs.join(", ")}`);
}

const targets = [];
for (const dir of workspaceDirs) {
  let pkg;
  try {
    pkg = JSON.parse(readFileSync(resolve(repoRoot, dir, "package.json"), "utf8"));
  } catch (err) {
    fail(`cannot read or parse ${dir}/package.json: ${err instanceof Error ? err.message : String(err)}`);
  }
  if (pkg.scripts?.["check-types"]) targets.push({ dir, name: pkg.name ?? dir });
}
if (targets.length === 0) {
  fail(`none of the ${workspaceDirs.length} workspace(s) declares a "check-types" script, so nothing was checked.`);
}

// npm sets npm_execpath to its own CLI script when it runs this one, and running that
// script under this Node needs no shell on any platform. Windows has no `npm` executable
// to spawn without one — only npm.cmd.
const npmCli = process.env.npm_execpath;
if (!npmCli && process.platform === "win32") fail("run it through npm: npm run check-types");
const [command, prefix] = npmCli ? [process.execPath, [npmCli]] : ["npm", []];

const run = ({ dir, name }) =>
  new Promise((done) => {
    const child = spawn(command, [...prefix, "run", "check-types", "--silent"], { cwd: resolve(repoRoot, dir) });
    let output = "";
    child.stdout.on("data", (chunk) => (output += chunk));
    child.stderr.on("data", (chunk) => (output += chunk));
    child.on("error", (err) => done({ name, code: 1, output: `could not start npm: ${err.message}` }));
    child.on("close", (code) => done({ name, code, output }));
  });

const results = [];
let next = 0;
const lane = async () => {
  while (next < targets.length) results.push(await run(targets[next++]));
};
await Promise.all(Array.from({ length: Math.min(availableParallelism(), targets.length) }, lane));

const failed = results.filter((r) => r.code !== 0).sort((a, b) => a.name.localeCompare(b.name));
for (const r of failed) console.error(`\n✗ ${r.name}\n${r.output.trim()}`);
const skipped = workspaceDirs.length - targets.length;
const scope = `${targets.length} workspace(s)${skipped > 0 ? ` (${skipped} without a check-types script skipped)` : ""}`;
if (failed.length > 0) {
  console.error(`\n✗ check-types: ${failed.length} of ${scope} failed`);
  process.exit(1);
}
console.log(`✓ check-types: ${scope} type-checked clean`);
