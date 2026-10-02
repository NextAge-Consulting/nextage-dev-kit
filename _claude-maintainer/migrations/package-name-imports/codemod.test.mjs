// node --test _claude-maintainer/migrations/package-name-imports/codemod.test.mjs
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { after, test } from "node:test";
import { fileURLToPath } from "node:url";

const codemod = join(dirname(fileURLToPath(import.meta.url)), "codemod.mjs");
const dirs = [];
after(() => {
  for (const d of dirs) rmSync(d, { recursive: true, force: true });
});

function repo() {
  const root = mkdtempSync(join(tmpdir(), "codemod-"));
  dirs.push(root);
  const put = (path, text) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), typeof text === "string" ? text : `${JSON.stringify(text, null, 2)}\n`);
  };
  put("package.json", { name: "acme", private: true, workspaces: ["apps/*", "packages/*"] });
  put("apps/web/package.json", { name: "@acme/web", dependencies: { react: "19", "@acme/ui": "*" } });
  put(
    "apps/web/tsconfig.json",
    `{
  // the app's own alias, plus two that cross into other workspaces
  "compilerOptions": {
    "baseUrl": ".",
    "paths": { "@/*": ["./src/*"], "@ui/*": ["../../packages/ui/src/*"], "@shared/*": ["../shared/src/*"], },
  },
}
`,
  );
  put(
    "apps/web/src/screen.ts",
    [
      `import { invoice } from "@shared/billing/invoice";`,
      `import { Button } from '@ui/components/button';`,
      `import { local } from "@/local";`,
      `import { again } from "../../shared/src/billing/invoice";`,
      `export { total } from "../../shared/src/billing";`,
      `const lazy = () => import("@shared/billing/invoice");`,
      `vi.mock("@shared/billing/invoice");`,
      `export const all = [invoice, Button, local, again, lazy];`,
      "",
    ].join("\n"),
  );
  put("apps/web/src/local.ts", "export const local = 1;\n");
  put("apps/web/vite.config.ts", `import { base } from "../shared/viteApp";\nexport default base;\n`);
  put("apps/web/src/styles.css", `@import "tailwindcss";\n@import "../../../packages/ui/src/styles.css";\n@source "../../../packages/ui/src";\n`);
  put("apps/shared/package.json", { name: "@acme/shared" });
  put("apps/shared/viteApp.ts", "export const base = {};\n");
  put("apps/shared/src/billing/invoice.ts", "export const invoice = 1;\n");
  put("apps/shared/src/billing/index.ts", `export const total = 1;\n`);
  put("packages/ui/package.json", { name: "@acme/ui" });
  put("packages/ui/tsconfig.json", { compilerOptions: { paths: { "@ui/*": ["./src/*"] } } });
  put("packages/ui/src/lib/utils.ts", "export const cn = 1;\n");
  put("packages/ui/src/styles.css", "\n");
  put("packages/ui/src/components/button.tsx", `import { cn } from "@ui/lib/utils";\nexport const Button = cn;\n`);
  return root;
}
const run = (root, ...args) => execFileSync("node", [codemod, root, ...args], { encoding: "utf8" });
const read = (root, path) => readFileSync(join(root, path), "utf8");

test("rewrites alias, relative and self-reference specifiers to package names", () => {
  const root = repo();
  const out = run(root);
  assert.match(out, /rewrote 8 specifier\(s\) in 3 file\(s\) — 4 alias, 3 relative, 1 self-reference/);
  assert.equal(
    read(root, "apps/web/src/screen.ts"),
    [
      `import { invoice } from "@acme/shared/billing/invoice";`,
      `import { Button } from '@acme/ui/components/button';`,
      `import { local } from "@/local";`,
      `import { again } from "@acme/shared/billing/invoice";`,
      `export { total } from "@acme/shared/billing";`,
      `const lazy = () => import("@acme/shared/billing/invoice");`,
      `vi.mock("@acme/shared/billing/invoice");`,
      `export const all = [invoice, Button, local, again, lazy];`,
      "",
    ].join("\n"),
  );
  assert.match(read(root, "apps/web/vite.config.ts"), /from "@acme\/shared\/viteApp"/);
  assert.match(read(root, "packages/ui/src/components/button.tsx"), /from "@acme\/ui\/lib\/utils"/);
});

test("names the workspace dependencies still to declare and every imported subpath", () => {
  const out = run(repo(), "--dry-run");
  assert.match(out, /apps\/web: "@acme\/shared": "\*"\n/);
  assert.doesNotMatch(out, /apps\/web: .*"@acme\/ui"/, "@acme/ui is already declared");
  assert.match(out, /subpaths imported from @acme\/shared \(3\)[^\n]*\n {2}\.\/billing\n {2}\.\/billing\/invoice\n {2}\.\/viteApp\n/);
  assert.match(out, /subpaths imported from @acme\/ui \(2\)[^\n]*\n {2}\.\/components\/button\n {2}\.\/lib\/utils\n/);
});

test("reports a cross-workspace CSS @import for hand review, never a Tailwind @source", () => {
  const out = run(repo(), "--dry-run");
  assert.match(out, /apps\/web\/src\/styles\.css: @import "\.\.\/\.\.\/\.\.\/packages\/ui\/src\/styles\.css" reaches into packages\/ui/);
  assert.doesNotMatch(out, /@source/);
});

test("--dry-run writes nothing and reports the same counts", () => {
  const root = repo();
  const before = read(root, "apps/web/src/screen.ts");
  const out = run(root, "--dry-run");
  assert.match(out, /would rewrite 8 specifier\(s\) in 3 file\(s\) — 4 alias, 3 relative, 1 self-reference \(dry run: nothing written\)/);
  assert.equal(read(root, "apps/web/src/screen.ts"), before);
});

test("a second run finds nothing left to rewrite", () => {
  const root = repo();
  run(root);
  assert.match(run(root), /rewrote 0 specifier\(s\) in 0 file\(s\)/);
});

test("a workspace without a name stops the run before anything is written", () => {
  const root = repo();
  writeFileSync(join(root, "packages/ui/package.json"), "{}\n");
  assert.throws(() => run(root), /packages\/ui\/package\.json has no name/);
  assert.match(read(root, "apps/web/src/screen.ts"), /"@shared\/billing\/invoice"/);
});
