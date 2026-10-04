#!/usr/bin/env node
/**
 * Rewrites cross-workspace imports to package-name imports
 * (typescript-rules.md, Workspace Imports).
 *
 *   node codemod.mjs [repoRoot] [--dry-run]
 *
 * It reads everything it needs from the repository: workspace directories and
 * names from the package.json files, aliases from every tsconfig*.json at the
 * root and in each workspace. Three kinds of specifier are rewritten, in
 * .ts/.tsx/.mts/.cts/.js/.jsx/.mjs files under every workspace and the root
 * scripts/ folder:
 *
 *   alias      a tsconfig `paths` alias resolving into another workspace
 *              "@shared/billing/invoice"   -> "@acme/shared/billing/invoice"
 *   relative   a relative path leaving its workspace for another one
 *              "../../shared/src/billing"  -> "@acme/shared/billing"
 *   self       an alias a consumed package uses for its OWN source — Vite and
 *              Node compile that source from the consumer, where the package's
 *              own tsconfig paths do not apply
 *              "@ui/lib/utils" inside packages/ui -> "@acme/ui/lib/utils"
 *
 * A subpath is taken relative to the target package's src/ when the module is
 * under it, else relative to the package root — matching an exports map whose
 * patterns point into ./src. An alias mapping into its own workspace in a
 * package nothing else consumes (an app's "@/*") is left alone.
 *
 * It then prints what the rest of the migration needs: the workspace
 * dependencies each workspace must declare, every subpath imported from each
 * package (the exports map must resolve all of them), and anything it could not
 * rewrite. With --dry-run it writes nothing and prints the same report.
 */

import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";

const USAGE = "usage: node codemod.mjs [repoRoot] [--dry-run]";
const args = process.argv.slice(2);
if (args.includes("--help") || args.includes("-h")) {
  console.log(USAGE);
  process.exit(0);
}
// An argument it does not know stops the run before anything is written.
const unknown = args.filter((a) => a.startsWith("-") && a !== "--dry-run");
const positional = args.filter((a) => !a.startsWith("-"));
if (unknown.length || positional.length > 1) {
  console.error(`codemod: ${unknown.length ? `unknown option ${unknown.join(", ")}` : "more than one repository root"}\n${USAGE}`);
  process.exit(2);
}
const dryRun = args.includes("--dry-run");
const root = resolve(positional[0] ?? ".");
const toPosix = (p) => p.split(sep).join("/");

const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

// tsconfig is JSON with comments and trailing commas; strings are copied whole so
// the `/*` in every paths glob is never read as a comment.
function parseJsonc(text) {
  let out = "";
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
      out += text.slice(i, j + 1);
      i = j;
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      out += "\n";
    } else if (c === "/" && text[i + 1] === "*") {
      i = text.indexOf("*/", i + 2);
      if (i === -1) break;
      i++;
    } else out += c;
  }
  return JSON.parse(out.replace(/,(\s*[}\]])/g, "$1"));
}

// --- workspaces --------------------------------------------------------------
if (!existsSync(join(root, "package.json"))) {
  console.error(`codemod: no package.json at ${root}`);
  process.exit(2);
}
const rootManifest = readJson(join(root, "package.json"));
const globs = Array.isArray(rootManifest.workspaces) ? rootManifest.workspaces : (rootManifest.workspaces?.packages ?? []);
const workspaces = [];
for (const glob of globs) {
  const dirs = glob.endsWith("/*")
    ? existsSync(join(root, glob.slice(0, -2)))
      ? readdirSync(join(root, glob.slice(0, -2))).map((n) => `${glob.slice(0, -2)}/${n}`)
      : []
    : [glob.replace(/\/+$/, "")];
  for (const dir of dirs) {
    const manifest = join(root, dir, "package.json");
    if (!existsSync(manifest)) continue;
    const name = readJson(manifest).name;
    if (!name) {
      console.error(`codemod: ${dir}/package.json has no name — every workspace needs one before it can be imported by it`);
      process.exit(2);
    }
    workspaces.push({ dir, abs: join(root, dir), name });
  }
}
if (workspaces.length < 2) {
  console.log(`codemod: ${workspaces.length} workspace(s) — nothing crosses a workspace boundary, nothing to rewrite.`);
  process.exit(0);
}
const within = (abs, dir) => abs === dir || abs.startsWith(dir + sep);
const ownerOf = (abs) =>
  workspaces.filter((w) => within(abs, w.abs)).sort((a, b) => b.abs.length - a.abs.length)[0] ?? null;

// --- aliases -----------------------------------------------------------------
// [{prefix, target (absolute dir), from (dir whose tsconfig declares it)}]
function aliasesIn(dir) {
  const out = [];
  for (const name of readdirSync(dir).filter((n) => /^tsconfig.*\.json$/.test(n))) {
    let config;
    try {
      config = parseJsonc(readFileSync(join(dir, name), "utf8"));
    } catch (e) {
      console.error(`codemod: cannot parse ${toPosix(relative(root, join(dir, name)))}: ${e.message}`);
      process.exit(2);
    }
    const opts = config.compilerOptions ?? {};
    const base = resolve(dir, opts.baseUrl ?? ".");
    for (const [key, targets] of Object.entries(opts.paths ?? {})) {
      if (!key.endsWith("/*") || !targets[0]?.endsWith("/*")) continue; // exact-file aliases: reported below
      out.push({ prefix: key.slice(0, -1), target: resolve(base, targets[0].slice(0, -2)) });
    }
  }
  return out;
}
const rootAliases = aliasesIn(root);
const aliasesOf = new Map(workspaces.map((w) => [w.dir, [...aliasesIn(w.abs), ...rootAliases]]));

// A package is consumed when another workspace reaches it — by alias, by name,
// or by relative path. Its own aliases must become self-references.
const consumed = new Set();
for (const w of workspaces) {
  for (const a of aliasesOf.get(w.dir)) {
    const t = ownerOf(a.target);
    if (t && t !== w) consumed.add(t.dir);
  }
  const m = readJson(join(w.abs, "package.json"));
  for (const dep of Object.keys({ ...m.dependencies, ...m.devDependencies, ...m.peerDependencies })) {
    const t = workspaces.find((x) => x.name === dep);
    if (t && t !== w) consumed.add(t.dir);
  }
}

// --- rewrite -----------------------------------------------------------------
const SKIP = new Set(["node_modules", "dist", "build", ".git", ".output", ".tanstack", ".turbo"]);
const CODE = /\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$/;
function* walk(dir) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    if (SKIP.has(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else yield p;
  }
}

// The subpath an exports map resolves: relative to src/ when the module is under it,
// with no file extension (`"./*": "./src/*.ts"` adds it).
const packageSpecifier = (target, abs) => {
  const src = join(target.abs, "src");
  const sub = (within(abs, src) ? relative(src, abs) : relative(target.abs, abs)).replace(CODE, "");
  return sub ? `${target.name}/${toPosix(sub)}` : target.name;
};
// The repository root, for code at the top level that belongs to no workspace
// (a root drizzle.config.ts): its imports are rewritten and its dependencies reported.
const ROOT = { dir: ".", abs: root, name: rootManifest.name };

// Module-specifier positions: from '…', import '…', import('…'), require('…'),
// vi.mock('…') / vi.importActual('…'), export … from '…'.
const SPEC = /(\bfrom\s*|\bimport\s*\(\s*|\bimport\s+|\b(?:mock|doMock|importActual|importMock)\s*\(\s*|\brequire\s*\(\s*)(['"])([^'"\n]+)\2/g;

const counts = { alias: 0, relative: 0, self: 0, src: 0, files: 0 };
const needs = new Map(); // workspace dir -> Set(package names it imports)
const subpaths = new Map(); // package name -> Set(subpaths)
const leftover = [];
const record = (from, spec) => {
  const target = workspaces.find((w) => spec === w.name || spec.startsWith(`${w.name}/`));
  if (!target) return;
  if (target !== from) (needs.get(from.dir) ?? needs.set(from.dir, new Set()).get(from.dir)).add(target.name);
  (subpaths.get(target.name) ?? subpaths.set(target.name, new Set()).get(target.name)).add(
    spec === target.name ? "." : `./${spec.slice(target.name.length + 1)}`,
  );
};

const scanRoots = [...workspaces.map((w) => w.abs), join(root, "scripts")];
const rootFiles = readdirSync(root).map((n) => join(root, n)).filter((p) => CODE.test(p) && statSync(p).isFile());
for (const top of [...scanRoots, ...rootFiles]) {
  for (const file of top === root || rootFiles.includes(top) ? [top] : walk(top)) {
    const rel = toPosix(relative(root, file));
    if (!CODE.test(file)) {
      if (/\.css$/.test(file)) {
        const own = ownerOf(file);
        for (const m of readFileSync(file, "utf8").matchAll(/@(import)\s+["'](\.[^"']+)["']/g)) {
          const t = ownerOf(resolve(dirname(file), m[2]));
          if (t && t !== own) leftover.push(`${rel}: @${m[1]} "${m[2]}" reaches into ${t.dir} — rewrite by hand`);
        }
      }
      continue;
    }
    const own = ownerOf(file);
    const aliases = own ? aliasesOf.get(own.dir) : rootAliases;
    // A bundler alias duplicates a tsconfig one; it goes when the imports stop using it.
    if (/(^|\/)vite(st)?(\.[\w-]+)?\.config\.[cm]?[jt]s$/.test(rel)) {
      for (const m of readFileSync(file, "utf8").matchAll(/["']?(@[\w-]+)["']?\s*:\s*(?:path\.)?resolve\(/g))
        leftover.push(`${rel}: resolve.alias "${m[1]}" — remove it once nothing imports through it`);
    }
    const src = readFileSync(file, "utf8");
    const out = src.replace(SPEC, (whole, lead, q, spec) => {
      let next = null;
      const alias = aliases.filter((a) => spec.startsWith(a.prefix)).sort((a, b) => b.prefix.length - a.prefix.length)[0];
      if (alias) {
        const abs = join(alias.target, spec.slice(alias.prefix.length));
        const target = ownerOf(abs);
        if (target && target !== own) {
          next = packageSpecifier(target, abs);
          counts.alias++;
        } else if (target && target === own && consumed.has(own.dir)) {
          next = packageSpecifier(target, abs);
          counts.self++;
        }
      } else if (workspaces.some((w) => spec.startsWith(`${w.name}/src/`))) {
        // A package-name import that reaches into src/ takes the exports-map form.
        const target = workspaces.find((w) => spec.startsWith(`${w.name}/src/`));
        next = packageSpecifier(target, join(target.abs, spec.slice(target.name.length + 1)));
        counts.src++;
      } else if (spec.startsWith(".")) {
        const abs = resolve(dirname(file), spec);
        const target = ownerOf(abs);
        if (target && target !== own) {
          next = packageSpecifier(target, abs);
          counts.relative++;
        } else if (!target && own) {
          leftover.push(`${rel}: "${spec}" leaves ${own.dir} for a folder no workspace owns — move the code into a package, or the import into that folder`);
        }
      }
      record(own ?? ROOT, next ?? spec);
      return next === null ? whole : `${lead}${q}${next}${q}`;
    });
    if (out !== src) {
      counts.files++;
      if (!dryRun) writeFileSync(file, out);
    }
  }
}

// --- report ------------------------------------------------------------------
const verb = dryRun ? "would rewrite" : "rewrote";
console.log(
  `codemod: ${verb} ${counts.alias + counts.relative + counts.self} specifier(s) in ${counts.files} file(s) — ` +
    `${counts.alias} alias, ${counts.relative} relative, ${counts.self} self-reference, ${counts.src} into src/${dryRun ? " (dry run: nothing written)" : ""}`,
);

const missing = [];
for (const [dir, names] of needs) {
  const m = readJson(join(root, dir, "package.json"));
  const declared = { ...m.dependencies, ...m.devDependencies, ...m.peerDependencies };
  const absent = [...names].filter((n) => !(n in declared)).sort();
  if (absent.length) missing.push(`  ${dir}: ${absent.map((n) => `"${n}": "*"`).join(", ")}`);
}
console.log(
  missing.length
    ? `workspace dependencies to declare (${missing.length} workspace(s)):\n${missing.join("\n")}`
    : "workspace dependencies: every workspace already declares the packages it imports",
);
for (const [name, subs] of [...subpaths].sort()) {
  console.log(`subpaths imported from ${name} (${subs.size}) — its exports map must resolve each:`);
  for (const s of [...subs].sort()) console.log(`  ${s}`);
}
const exactAliases = [];
for (const dir of [root, ...workspaces.map((w) => w.abs)]) {
  for (const name of readdirSync(dir).filter((n) => /^tsconfig.*\.json$/.test(n))) {
    const paths = parseJsonc(readFileSync(join(dir, name), "utf8")).compilerOptions?.paths ?? {};
    for (const key of Object.keys(paths))
      if (!key.endsWith("/*")) exactAliases.push(`${toPosix(relative(root, join(dir, name)))}: "${key}"`);
  }
}
if (exactAliases.length) leftover.push(...exactAliases.map((a) => `${a} is an exact-path alias — rewrite its imports by hand`));
if (leftover.length) console.log(`left for hand review (${leftover.length}):\n  ${leftover.join("\n  ")}`);
