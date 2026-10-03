// The kit's knip configuration: every project runs this one file, unedited.
//
// Knip reports unused files, exports, types and dependencies, plus imports of
// packages a workspace never declares. CI runs it when KNIP_GATE is "true" in
// .claude/sync-substitutions.json (pipeline.md §3.9).
//
// There is no per-project ignore list, by design. Every entry and exemption below
// is a kit convention or is read from the project's own declarations — its
// workspaces, its Drizzle configs, its package scripts, its substitutions. A
// finding that is not dead code is a gap in THIS file: raise it on the kit, never
// silence it locally.

import { execFileSync } from "node:child_process";
import { type Dirent, existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, join, posix, relative, resolve } from "node:path";

const root = process.cwd();

const substitutionsPath = resolve(root, ".claude/sync-substitutions.json");
if (!existsSync(substitutionsPath)) {
  throw new Error("knip.config.ts reads .claude/sync-substitutions.json, which is missing — run /sync-dev-kit.");
}
const substitutions: Record<string, unknown> = JSON.parse(readFileSync(substitutionsPath, "utf8"));
const setting = (key: string): string => {
  const value = substitutions[key];
  return typeof value === "string" ? value.trim().replace(/\/+$/, "") : "";
};
const uiPackage = setting("DESIGN_UI_PACKAGE");
const feedBarrel = setting("DESIGN_FEED_BARREL");
const vendoredDir = setting("DESIGN_VENDORED_DIR");
const sharedModule = setting("SHARED_MODULE_DIR");

const toPosix = (p: string) => p.split("\\").join("/");
const readJson = (p: string) => JSON.parse(readFileSync(resolve(root, p), "utf8"));

// Workspace directories, from the root manifest's own `workspaces` globs.
const rootManifest = readJson("package.json");
const workspaceGlobs: string[] = Array.isArray(rootManifest.workspaces)
  ? rootManifest.workspaces
  : (rootManifest.workspaces?.packages ?? []);
const workspaceDirs = workspaceGlobs.flatMap((glob: string): string[] => {
  if (!glob.endsWith("/*")) return existsSync(resolve(root, glob, "package.json")) ? [glob] : [];
  const parent = glob.slice(0, -2);
  if (!existsSync(resolve(root, parent))) return [];
  return readdirSync(resolve(root, parent), { withFileTypes: true })
    .filter((d: Dirent) => d.isDirectory() && existsSync(resolve(root, parent, d.name, "package.json")))
    .map((d: Dirent) => `${parent}/${d.name}`);
});
// A directory with its own package.json that is no root workspace — a test
// harness, a tool — is analysed as a package of its own, so its imports are
// attributed to the manifest that declares them. Candidates are the files git
// sees, so nothing gitignored (a virtualenv's site-packages) is mistaken for one.
const excludedDirs = /(^|\/)(node_modules|\.claude|dist|infra|project-documentation)\//;
const nestedPackageDirs = execFileSync(
  "git",
  ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", "*/package.json"],
  { cwd: root, encoding: "utf8" },
)
  .split("\0")
  .filter((f: string) => f !== "" && !excludedDirs.test(f) && existsSync(resolve(root, f)))
  .map((f: string) => posix.dirname(toPosix(f)))
  .filter((d: string) => !workspaceDirs.includes(d));
const packageDirs = [...workspaceDirs, ...nestedPackageDirs];
const workspaceOf = (file: string) =>
  packageDirs.filter((d: string) => file.startsWith(`${d}/`)).sort((a: string, b: string) => b.length - a.length)[0] ?? ".";

// Drizzle configs are READ, never executed: they throw when their database URL
// is unset, which is every CI run, and knip's drizzle plugin would execute them.
// drizzle-kit consumes every export of the schema a config names.
const drizzleConfigName = /^drizzle(\..+)?\.config\.(ts|js|mjs)$/;
const drizzleConfigs = ["", ...packageDirs].flatMap((dir: string): string[] =>
  existsSync(resolve(root, dir))
    ? readdirSync(resolve(root, dir))
        .filter((f: string) => drizzleConfigName.test(f))
        .map((f: string) => toPosix(join(dir, f)))
    : [],
);
const schemaPaths = drizzleConfigs.flatMap((config: string): string[] => {
  const declared = /\bschema\s*:\s*(\[[^\]]*\]|["'`][^"'`]+["'`])/.exec(readFileSync(resolve(root, config), "utf8"));
  if (!declared) return [];
  return [...(declared[1] ?? "").matchAll(/["'`]([^"'`]+)["'`]/g)].map((m: RegExpMatchArray) =>
    toPosix(relative(root, resolve(root, dirname(config), m[1] ?? ""))),
  );
});
// A schema named by its barrel is the folder that barrel re-exports.
const schemaGlobs = schemaPaths.map((p: string) => (/(^|\/)index\.(ts|js|mjs)$/.test(p) ? `${posix.dirname(p)}/**` : p));

const knipDefaults = "{index,cli,main}.{js,mjs,cjs,jsx,ts,mts,cts,tsx}";
// Browser scripts a non-JavaScript server reads by path and serves — a Python
// app's server-rendered pages — live in a `static/` directory (python-rules.md).
// Nothing knip can see imports them, and the page that loads one may call any of
// its exports.
const served = "**/static/**";
const appEntries = [
  knipDefaults,
  `src/${knipDefaults}`,
  "server-start.mjs",
  "src/server.ts",
  "src/{start,router}.{ts,tsx}",
  "design-system/**/*.{mjs,ts,css}",
  "public/**/*.js",
  served,
];
const packageEntries = [knipDefaults, `src/${knipDefaults}`, "design-system/**/*.{mjs,ts,css}", served];
const harness = "test/{globalSetup,integration-helpers,test-utils,auth-mocks}.ts";

// Packages nothing imports by name: pino resolves its transport from a string
// (typescript-rules.md, the logger), and the claude-design engine — whose code
// lives under .claude/ — drives esbuild and the Tailwind CLI (stack-manifest.json).
const ignoreDependencies = ["pino-pretty", ...(uiPackage ? ["esbuild", "@tailwindcss/cli"] : [])];
// commitlint.yml installs commitlint at run time (stack-manifest.json, installedBy ci).
const ignoreBinaries = ["commitlint"];

type Workspace = { entry: string[]; ignoreDependencies: string[]; ignoreBinaries: string[] };
const workspace = (entry: string[]): Workspace => ({ entry, ignoreDependencies: [...ignoreDependencies], ignoreBinaries });
const workspaces: Record<string, Workspace> = {
  ".": workspace([
    knipDefaults,
    `src/${knipDefaults}`,
    "scripts/*.{mjs,js,ts}",
    ...(workspaceDirs.length === 0 ? appEntries : [served]),
  ]),
  "apps/*": workspace(appEntries),
  "packages/*": workspace(packageEntries),
  ...Object.fromEntries(nestedPackageDirs.map((dir: string) => [dir, workspace(packageEntries)])),
};
// Knip takes the most specific workspace key and never merges, so a workspace
// that needs its own entries starts from the ones its glob would have given it.
const entriesOf = (dir: string): string[] => {
  const existing = workspaces[dir];
  if (existing) return existing.entry;
  const inherited = dir.startsWith("apps/") ? appEntries : dir.startsWith("packages/") ? packageEntries : [];
  const created = workspace([...inherited]);
  workspaces[dir] = created;
  return created.entry;
};
const inWorkspace = (file: string) => {
  const ws = workspaceOf(file);
  return { ws, path: ws === "." ? file : posix.relative(ws, file) };
};

for (const file of [...drizzleConfigs, ...schemaPaths]) {
  const { ws, path } = inWorkspace(file);
  entriesOf(ws).push(path);
}
// A stylesheet a package script hands to the Tailwind CLI is an entry: nothing
// imports it, the build reads it.
for (const dir of [".", ...packageDirs]) {
  const scripts: Record<string, string> = readJson(`${dir}/package.json`).scripts ?? {};
  for (const script of Object.values(scripts)) {
    for (const m of script.matchAll(/\btailwindcss\b[^&|;]*?(?:-i|--input)[ =]+([^\s&|;]+)/g)) {
      entriesOf(dir).push((m[1] ?? "").replace(/^\.\//, ""));
    }
  }
}
if (sharedModule) entriesOf(sharedModule).push(harness);

// A workspace that declares better-auth declares zod 4 beside it, imported by
// nothing: it is there so the bundled auth code resolves zod 4 from the app, not
// the zod 3 hoisted to the root (mfing-bible-of-tanstack, deployment.md).
for (const dir of [".", ...packageDirs]) {
  const manifest = readJson(`${dir}/package.json`);
  const declared: Record<string, string> = { ...manifest.dependencies, ...manifest.devDependencies };
  if (!("better-auth" in declared)) continue;
  entriesOf(dir);
  workspaces[dir]?.ignoreDependencies.push("zod");
}
if (uiPackage && feedBarrel) entriesOf(uiPackage).push(feedBarrel);

// Entries whose exports a tool or framework consumes, not an import.
const consumedExports = [
  "**/src/server.ts",
  "**/design-system/design-system.config.mjs",
  served,
  ...drizzleConfigs,
  ...schemaGlobs,
];
// The modules the Claude Design feed barrel re-exports: the claude-design build reads the
// barrel, so what it re-exports is consumed whether or not an app imports it.
const feedModules: string[] = [];
if (uiPackage && feedBarrel && existsSync(resolve(root, uiPackage, feedBarrel))) {
  const barrelDir = dirname(`${uiPackage}/${feedBarrel}`);
  for (const m of readFileSync(resolve(root, uiPackage, feedBarrel), "utf8").matchAll(/^\s*export\s[^;]*?\bfrom\s+["'](\.{1,2}\/[^"']+)["']/gm)) {
    const base = toPosix(join(barrelDir, m[1])).replace(/\.(?:[cm]?[jt]sx?)$/, "");
    feedModules.push(`${base}.{ts,tsx,js,jsx,mts}`, `${base}/index.{ts,tsx,js,jsx,mts}`);
  }
}

// API surfaces whose unused members are not dead code: the vendored shadcn atoms, the
// modules the feed barrel publishes, and the kit's test harness, which tests not yet
// written consume.
const apiSurfaces = [
  ...feedModules,
  "**/src/components/ui/**",
  ...(vendoredDir ? [`${vendoredDir}/**`] : []),
  ...(sharedModule ? [sharedModule === "." ? harness : `${sharedModule}/${harness}`] : []),
];

export default {
  $schema: "https://unpkg.com/knip@5/schema.json",
  // Every file a workspace's `exports` map names is an entry. Without this, an
  // unused export of shared code is never reported.
  includeEntryExports: true,
  // infra/ holds what the platform runs — buildspecs, handlers, images — under
  // its own runtime, never imported by a workspace. An ignored file still sits in
  // the import graph; only its own findings are dropped. The generated route tree
  // is the sole importer of every route's `Route` and of the router and start
  // entries, so it must be committed, as TanStack Router's FAQ says — gitignored,
  // knip never sees it and reports all of those as unused.
  ignore: [".claude/**", "project-documentation/**", "infra/**", "**/*.generated.*", "**/routeTree.gen.ts", "**/dist/**"],
  ignoreBinaries,
  ignoreDependencies,
  ignoreIssues: {
    ...Object.fromEntries(consumedExports.map((glob: string) => [glob, ["exports"]])),
    ...Object.fromEntries(apiSurfaces.map((glob: string) => [glob, ["exports", "types"]])),
  },
  drizzle: false,
  vitest: { config: ["vitest.config.{ts,mts,js,mjs}", "vitest.*.config.{ts,mts,js,mjs}"] },
  workspaces,
  // Tailwind v4 stylesheets name packages in `@import` and `@plugin`.
  compilers: {
    css: (text: string) =>
      [...text.matchAll(/@(?:import|plugin)\s+["']([^"']+)["']/g)].map((m: RegExpMatchArray) => `import "${m[1]}";`).join("\n"),
  },
};
