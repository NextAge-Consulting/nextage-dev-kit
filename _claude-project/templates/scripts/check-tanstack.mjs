#!/usr/bin/env node
/**
 * TanStack standard gate (see .claude/skills/mfing-bible-of-tanstack/SKILL.md).
 *
 * WHY THIS EXISTS: TanStack publishes no LTS — no `lts` dist-tag on any package,
 * no support-window policy, just one rolling line per library. There is no
 * upstream stability signal to defer to, so the KIT is the LTS: one blessed
 * version per package in .claude/tanstack-manifest.json, and every project runs
 * it. Lockstep is absolute — a project that uses a TanStack library uses the
 * kit's version of it.
 *
 * FOUR INVARIANTS:
 *   1. Blessed versions are declared EXACTLY. A caret range lets a fresh install
 *      drift to a version the kit never blessed, silently defeating lockstep.
 *   2. Banned dependencies are absent. The live case: `npx shadcn add form`
 *      installs react-hook-form as a hard dependency, which would land a second
 *      form library in a repo that has standardised on TanStack Form — a
 *      divergence that type-checks, lints, builds, and surfaces months later.
 *   3. Every front-end app has ANSWERED the form-library question. Three states;
 *      the third is the failure: declares @tanstack/react-form (decided yes),
 *      listed in FORM_LIB_EXEMPT_APPS (decided no), or neither (never asked).
 *   4. Every vendored reference doc named by the manifest is actually present.
 *
 * SELF-GATING: a repo with no package.json, or no @tanstack/* dependency
 * anywhere, exits 0 in silence — same marker-file cascade the gitflow scripts
 * use for TypeScript vs Python. Nothing to configure, nothing to opt out of.
 *
 * HERMETIC BY DESIGN: reads package.json files, the lockfile, the manifest and
 * sync-substitutions.json. It never touches the network, so it is safe in CI and
 * fast enough for pre-commit. The manifest's `watch` block — which needs the npm
 * registry — is consumed by the kit's /review-tanstack maintainer command, not
 * here.
 *
 * Pure fs + JSON, no dependencies, safe to run pre-`npm ci`.
 *
 * Run: node scripts/check-tanstack.mjs   (exit 1 on violation, 0 when clean)
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const failures = [];
const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

// --- marker-file gate: is this even a Node repo? ---------------------------
const rootPkgPath = resolve(repoRoot, "package.json");
if (!existsSync(rootPkgPath)) process.exit(0);
const rootPkg = readJson(rootPkgPath);

// --- collect every workspace manifest (root included) ----------------------
const rawWorkspaces = Array.isArray(rootPkg.workspaces)
  ? rootPkg.workspaces
  : (rootPkg.workspaces?.packages ?? []);

const manifests = [{ dir: ".", pkg: rootPkg }];
for (const pattern of rawWorkspaces) {
  const dirs = [];
  if (pattern.endsWith("/*")) {
    const parent = pattern.slice(0, -2);
    let entries;
    try {
      entries = readdirSync(resolve(repoRoot, parent), { withFileTypes: true });
    } catch {
      continue; // parent dir absent — nothing to expand
    }
    for (const ent of entries) if (ent.isDirectory()) dirs.push(`${parent}/${ent.name}`);
  } else {
    dirs.push(pattern);
  }
  for (const dir of dirs) {
    const p = resolve(repoRoot, dir, "package.json");
    if (existsSync(p)) manifests.push({ dir, pkg: readJson(p) });
  }
}

const depsOf = (pkg) => ({ ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) });
const usesTanStack = manifests.some((m) =>
  Object.keys(depsOf(m.pkg)).some((d) => d.startsWith("@tanstack/")),
);
if (!usesTanStack) process.exit(0); // not a TanStack repo — nothing to enforce

// --- the manifest is required once TanStack is in play ---------------------
const manifestPath = resolve(repoRoot, ".claude/tanstack-manifest.json");
if (!existsSync(manifestPath)) {
  console.error(
    "✗ tanstack: this repo uses TanStack but .claude/tanstack-manifest.json is missing.\n" +
      "  The manifest ships with this script via /sync-dev-kit — run a sync.",
  );
  process.exit(1);
}
const manifest = readJson(manifestPath);
const blessed = manifest.packages ?? {};
const banned = manifest.banned ?? {};
const formLib = manifest.form_library ?? "@tanstack/react-form";

// --- 1. blessed versions, declared exactly ---------------------------------
for (const { dir, pkg } of manifests) {
  const deps = depsOf(pkg);
  for (const [name, want] of Object.entries(blessed)) {
    const got = deps[name];
    if (got === undefined) continue; // not used here — fine, lockstep is not "must use"
    if (got === want) continue;
    const where = `${dir === "." ? "" : `${dir}/`}package.json`;
    if (/^[\^~><=*]|\s|\|\|/.test(got)) {
      failures.push(
        `${where}: ${name} is "${got}" — declare the exact blessed version "${want}". ` +
          `A range lets a fresh install drift off the kit's version.`,
      );
    } else {
      failures.push(`${where}: ${name} is "${got}" — the kit blesses "${want}".`);
    }
  }
}

// --- 2. banned dependencies ------------------------------------------------
for (const { dir, pkg } of manifests) {
  const deps = depsOf(pkg);
  for (const [name, why] of Object.entries(banned)) {
    if (deps[name] === undefined) continue;
    const where = `${dir === "." ? "" : `${dir}/`}package.json`;
    failures.push(`${where}: "${name}" is banned. ${why}`);
  }
}

// --- 3. the form-library question is answered, per front-end app -----------
// A front-end app is an apps/* workspace that declares react. Headless apps
// (rest, worker, shared) declare none and are correctly out of scope — the
// workspace-tier rule is what keeps React out of them.
const subsPath = resolve(repoRoot, ".claude/sync-substitutions.json");
let exempt = [];
if (existsSync(subsPath)) {
  const raw = readJson(subsPath).FORM_LIB_EXEMPT_APPS ?? "";
  exempt = String(raw).split(/\s+/).filter(Boolean);
}

const frontEndApps = manifests.filter(
  (m) => m.dir.startsWith("apps/") && depsOf(m.pkg).react !== undefined,
);
const undecided = [];
for (const { dir, pkg } of frontEndApps) {
  const appName = dir.slice("apps/".length);
  if (depsOf(pkg)[formLib] !== undefined) continue; // decided: yes
  if (exempt.includes(appName)) continue; // decided: no
  undecided.push(appName);
}
if (undecided.length) {
  failures.push(
    `form-library question unanswered for: ${undecided.join(", ")}.\n` +
      `    Every front-end app decides ONCE, all-in for that app. Either:\n` +
      `      - add "${formLib}" to apps/<app>/package.json  (data-entry app), or\n` +
      `      - add the app to FORM_LIB_EXEMPT_APPS in .claude/sync-substitutions.json\n` +
      `        (space-separated list; suits apps with no real data entry —\n` +
      `         ecommerce/cart, marketing, or control-plane/service apps).\n` +
      `    Leaving it in neither state is what fails here — an unasked question,\n` +
      `    not a missing dependency.`,
  );
}

// --- 4. vendored reference docs are present --------------------------------
const refDir = resolve(repoRoot, ".claude/skills/mfing-bible-of-tanstack/references");
const missingRefs = (manifest.references ?? [])
  .map((r) => r.file)
  .filter((f) => !existsSync(resolve(refDir, f)));
if (missingRefs.length) {
  failures.push(
    `manifest names reference docs that are not present: ${missingRefs.join(", ")}.\n` +
      `    Expected under .claude/skills/mfing-bible-of-tanstack/references/ — run /sync-dev-kit.`,
  );
}

// --- 5. lockfile agrees with the declarations ------------------------------
// package.json can be right while the lockfile still resolves something else.
const lockPath = resolve(repoRoot, "package-lock.json");
if (existsSync(lockPath)) {
  const lock = readJson(lockPath);
  for (const [name, want] of Object.entries(blessed)) {
    const entry = lock.packages?.[`node_modules/${name}`];
    if (!entry?.version) continue; // not installed — declaration check already covers it
    if (entry.version !== want) {
      failures.push(
        `package-lock.json: ${name} resolves to ${entry.version}, blessed is ${want}. ` +
          `Reinstall so the lockfile matches.`,
      );
    }
  }
  for (const name of Object.keys(banned)) {
    if (lock.packages?.[`node_modules/${name}`]) {
      failures.push(
        `package-lock.json: banned package "${name}" is in the tree (possibly transitive). ` +
          `Find what pulls it: npm ls ${name}`,
      );
    }
  }
}

// --- report ----------------------------------------------------------------
if (failures.length) {
  console.error(`✗ tanstack standard violations:\n${failures.map((f) => `  ${f}`).join("\n")}`);
  process.exit(1);
}

// Say what was actually enforced, so a silent pass is never mistaken for
// coverage the repo did not have.
const used = Object.keys(blessed).filter((n) =>
  manifests.some(({ pkg }) => depsOf(pkg)[n] !== undefined),
);
const parts = [`${used.length} blessed package(s) pinned`];
parts.push(`${Object.keys(banned).length} banned dep(s) absent`);
if (frontEndApps.length)
  parts.push(
    `form question answered for ${frontEndApps.map((a) => a.dir.slice(5)).join(", ")}`,
  );
if ((manifest.references ?? []).length)
  parts.push(`${manifest.references.length} reference doc(s) present`);
console.log(`✓ tanstack: ${parts.join("; ")} (blessed ${manifest.blessed_at}).`);
