#!/usr/bin/env node
/**
 * The code fingerprint: one hash for the code of a tree, the same whenever nothing a
 * check can see has changed. The gitflow gates skip on an unchanged fingerprint
 * (gates.sh), and the full test suite is recorded against one (FULL_SUITE below).
 *
 *   node code-fingerprint.mjs [-C <dir>]                  the working tree
 *   node code-fingerprint.mjs [-C <dir>] --commit <rev>   a commit
 *   node code-fingerprint.mjs --status-context            the full-suite status's name
 *   node code-fingerprint.mjs --status-description <fp> [--from <sha>]
 *   node code-fingerprint.mjs --status-fp <description>   the fingerprint a description carries
 *
 * The working tree is every file git tracks or would add (untracked, not ignored) that
 * exists; a commit is every file in its tree. Both read the same bytes, so a commit and
 * a checkout of it have the same fingerprint.
 *
 * TypeScript and JavaScript (.ts .tsx .mts .cts .js .jsx .mjs .cjs) are read by
 * TypeScript's parser and hashed as their syntax tree and token text, so comments and
 * whitespace drop out. What stays:
 *   - every token's text, verbatim — strings, templates and regular expressions included;
 *   - the tree's shape, so a newline that changes the parse (`return` then a line break)
 *     changes the hash;
 *   - JSX text as JSX reads it (lines trimmed, blank lines dropped);
 *   - every comment that carries a tool directive (DIRECTIVE below), in place, and in a
 *     file holding one, the line distance between consecutive items, because several
 *     directives act on "the next line";
 *   - in JavaScript files, every JSDoc block, which carries types there.
 * A file the parser cannot read cleanly is hashed raw, as is every other file. When
 * TypeScript cannot be loaded, every file is hashed raw, so nothing is ever wrongly
 * skipped, and it says so.
 *
 * Prints the fingerprint on stdout, and on stderr how many files it read and how.
 * Exit 0 on success; 2 when it cannot run, or the tree holds no files.
 */

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { lstatSync, readFileSync, readlinkSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

/**
 * The commit status that records a full-suite pass, and its description. Every runner of
 * the full suite posts it (CI's vitest job, any other runner a project points the suite
 * at), and /deploy reads it: a `success` whose description carries a fingerprint means
 * the full suite passed on code with that fingerprint. The description is
 * "fp <fingerprint>", or "carried forward from <sha> · fp <fingerprint>" when the pass is
 * an earlier commit's, reused because the code is unchanged.
 */
export const FULL_SUITE = {
  context: "full-suite",
  describe: (fp, from) => (from ? `carried forward from ${from} · fp ${fp}` : `fp ${fp}`),
  fingerprintOf: (description) => /(?:^| )fp ([0-9a-f]{32})$/.exec(description ?? "")?.[1] ?? null,
};

// Bumped when what the fingerprint covers changes, so an old record never matches.
const ALGORITHM = "code-fingerprint/1";

const CODE = /\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$/;
const JS = /\.(js|jsx|mjs|cjs)$/;

/**
 * A comment carrying a tool directive counts as code: a type checker, linter, scanner,
 * bundler, coverage tool, formatter or test runner reads it.
 */
const DIRECTIVE = new RegExp(
  [
    "@ts-", // @ts-ignore, @ts-expect-error, @ts-nocheck, @ts-check
    "biome-ignore",
    "eslint", // eslint-disable…, /* eslint rule: … */
    "^\\s*globals?\\s", // eslint globals
    "nosemgrep",
    "@vite-ignore",
    "webpack[A-Z]", // webpackChunkName, webpackPrefetch, webpackIgnore, …
    "[#@]__[A-Z_]+__", // #__PURE__, @__PURE__, #__NO_SIDE_EFFECTS__
    "@license",
    "@preserve",
    "^/\\*!", // legal comments
    "^///\\s*<", // /// <reference …/>, /// <amd-module …/>
    "@jsx", // @jsx, @jsxFrag, @jsxImportSource, @jsxRuntime
    "prettier-ignore",
    "(c8|istanbul|v8) ignore",
    "@(vitest|jest)-environment",
    "@internal", // stripInternal drops it from declaration output
  ].join("|"),
  "m",
);

const argv = process.argv.slice(2);
const option = (name) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};

function fail(message) {
  console.error(`code-fingerprint: ${message}`);
  process.exit(2);
}

if (argv.includes("--status-context")) {
  console.log(FULL_SUITE.context);
  process.exit(0);
}
if (argv.includes("--status-description")) {
  const fp = option("--status-description");
  if (!fp || !/^[0-9a-f]{32}$/.test(fp)) fail("--status-description needs a fingerprint");
  console.log(FULL_SUITE.describe(fp, option("--from")));
  process.exit(0);
}
if (argv.includes("--status-fp")) {
  const fp = FULL_SUITE.fingerprintOf(option("--status-fp"));
  if (!fp) process.exit(1);
  console.log(fp);
  process.exit(0);
}

const dir = option("-C") ?? process.cwd();
const commit = option("--commit");
if (argv.includes("--commit") && !commit) fail("--commit needs a revision");

function git(args, input) {
  return execFileSync("git", ["-C", dir, ...args], {
    input,
    maxBuffer: 1024 * 1024 * 1024,
    stdio: ["pipe", "pipe", "pipe"],
  });
}

let repo;
try {
  repo = git(["rev-parse", "--show-toplevel"]).toString().trim();
} catch {
  fail(`${dir} is not inside a git repository`);
}

// --- TypeScript: the repository's, else the global one ---------------------------------

function loadTypeScript() {
  const usable = (from) => {
    try {
      const ts = createRequire(from)("typescript");
      return typeof ts?.createSourceFile === "function" && typeof ts?.getLeadingCommentRanges === "function"
        ? ts
        : null;
    } catch {
      return null;
    }
  };
  const local = usable(join(repo, "package.json"));
  if (local) return local;
  let root = "";
  try {
    // On Windows npm is npm.cmd, which Node runs only through a shell; the arguments are fixed.
    const windows = process.platform === "win32";
    root = execFileSync(windows ? "npm.cmd" : "npm", ["root", "-g"], {
      encoding: "utf8",
      shell: windows,
      stdio: ["ignore", "pipe", "ignore"],
    }).trim();
  } catch {}
  return root ? usable(join(root, "noop.js")) : null;
}

const ts = loadTypeScript();

// --- the files ---------------------------------------------------------------------

/** git's blob id for these bytes, in the repository's hash. */
function blobId(bytes, algorithm) {
  return createHash(algorithm).update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
}

/**
 * Every file, as { path, oid, read } — read() returns its bytes. A submodule is its
 * commit id and is never read.
 */
function treeFiles() {
  if (commit) {
    let sha;
    try {
      sha = git(["rev-parse", "--verify", `${commit}^{commit}`]).toString().trim();
    } catch {
      fail(`${commit} is not a commit`);
    }
    const listing = git(["ls-tree", "-r", "-z", "--full-tree", sha]).toString();
    const files = [];
    for (const entry of listing.split("\0")) {
      if (!entry) continue;
      const tab = entry.indexOf("\t");
      const [, type, oid] = entry.slice(0, tab).split(" ");
      files.push({ path: entry.slice(tab + 1), oid, type, read: null });
    }
    // One cat-file for every blob the parser reads.
    const wanted = files.filter((f) => f.type === "blob" && CODE.test(f.path));
    if (wanted.length) {
      const out = git(["cat-file", "--batch"], wanted.map((f) => f.oid).join("\n") + "\n");
      let at = 0;
      for (const f of wanted) {
        const header = out.subarray(at, out.indexOf(10, at)).toString();
        const size = Number(header.split(" ")[2]);
        const start = out.indexOf(10, at) + 1;
        const bytes = out.subarray(start, start + size);
        f.read = () => bytes;
        at = start + size + 1;
      }
    }
    return files;
  }

  const algorithm = git(["rev-parse", "--show-object-format"]).toString().trim() === "sha256" ? "sha256" : "sha1";
  const gitlinks = new Map();
  for (const entry of git(["ls-files", "-z", "-s"]).toString().split("\0")) {
    if (entry.startsWith("160000 ")) gitlinks.set(entry.slice(entry.indexOf("\t") + 1), entry.split(" ")[1]);
  }
  const paths = [
    ...new Set(
      git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        .toString()
        .split("\0")
        .filter(Boolean),
    ),
  ];
  const files = [];
  for (const path of paths) {
    if (gitlinks.has(path)) {
      let oid = gitlinks.get(path);
      try {
        oid = execFileSync("git", ["-C", join(repo, path), "rev-parse", "HEAD"], { stdio: ["ignore", "pipe", "ignore"] })
          .toString()
          .trim();
      } catch {}
      files.push({ path, oid, type: "commit", read: null });
      continue;
    }
    const full = join(repo, path);
    let stat;
    try {
      stat = lstatSync(full);
    } catch {
      continue; // tracked, deleted here: not part of this tree
    }
    let bytes;
    if (stat.isSymbolicLink()) bytes = Buffer.from(readlinkSync(full));
    else if (stat.isFile()) bytes = readFileSync(full);
    else continue;
    files.push({ path, oid: blobId(bytes, algorithm), type: stat.isSymbolicLink() ? "link" : "blob", read: () => bytes });
  }
  return files;
}

// --- reading code ------------------------------------------------------------------

/** JSX text as JSX reads it: lines trimmed at their joins, blank lines dropped. */
function jsxText(value) {
  const lines = value.split(/\r\n|\n|\r/);
  let last = -1;
  lines.forEach((line, i) => {
    if (/[^ \t]/.test(line)) last = i;
  });
  let out = "";
  lines.forEach((line, i) => {
    let text = line.replace(/\t/g, " ");
    if (i !== 0) text = text.replace(/^ +/, "");
    if (i !== lines.length - 1) text = text.replace(/ +$/, "");
    if (text) out += i === last ? text : `${text} `;
  });
  return out;
}

/** The code's token stream, or null when the parser could not read it cleanly. */
function codeStream(path, text) {
  const source = ts.createSourceFile(path, text, ts.ScriptTarget.Latest, false);
  if (source.parseDiagnostics?.length !== 0) return null;
  const isJs = JS.test(path);
  const firstJsDoc = ts.SyntaxKind.FirstJSDocNode;
  const lastJsDoc = ts.SyntaxKind.LastJSDocNode;
  const items = []; // [position, text]
  const kept = (comment) => DIRECTIVE.test(comment) || (isJs && comment.startsWith("/**"));
  let directives = false;
  let rebuilt = "";

  if (text.startsWith("#!")) items.push([0, text.slice(0, text.search(/\r?\n|$/))]);

  const visit = (node) => {
    if (node.kind >= firstJsDoc && node.kind <= lastJsDoc) return;
    const children = node.getChildren(source);
    if (children.length === 0) {
      rebuilt += text.slice(node.pos, node.end);
      if (node.kind !== ts.SyntaxKind.JsxText) {
        for (const range of ts.getLeadingCommentRanges(text, node.pos) ?? []) {
          const comment = text.slice(range.pos, range.end);
          if (!kept(comment)) continue;
          items.push([range.pos, comment]);
          if (DIRECTIVE.test(comment)) directives = true;
        }
      }
      const start = node.kind === ts.SyntaxKind.JsxText ? node.pos : node.getStart(source);
      items.push([start, node.kind === ts.SyntaxKind.JsxText ? jsxText(node.text) : text.slice(start, node.end)]);
      return;
    }
    items.push([-1, `(${node.kind}`]);
    for (const child of children) visit(child);
    items.push([-1, ")"]);
  };
  visit(source);
  // Every byte belongs to exactly one token, its trivia included; anything else means
  // the walk missed text, and the file is read raw instead.
  if (rebuilt !== text) return null;

  let out = "";
  let line = 0;
  for (const [pos, value] of items) {
    if (directives && pos >= 0) {
      const at = source.getLineAndCharacterOfPosition(pos).line;
      out += `\u0001${at - line}`;
      line = at;
    }
    out += `\0${value}`;
  }
  return out;
}

// --- the fingerprint ----------------------------------------------------------------

const files = treeFiles().sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
if (files.length === 0) fail("the tree holds no files, so there is no code to fingerprint");

const hash = createHash("sha256").update(`${ALGORITHM}\n`);
let tokens = 0;
let raw = 0;
let unreadable = 0;
for (const file of files) {
  let digest = null;
  if (ts && file.read && CODE.test(file.path)) {
    let stream = null;
    try {
      stream = codeStream(file.path, file.read().toString("utf8"));
    } catch {}
    if (stream === null) unreadable++;
    else digest = `t ${createHash("sha256").update(stream).digest("hex")}`;
  }
  if (digest) tokens++;
  else {
    raw++;
    digest = `r ${file.type} ${file.oid}`;
  }
  hash.update(`${file.path}\0${digest}\n`);
}

const fp = hash.digest("hex").slice(0, 32);
const what = commit ? `commit ${commit}` : "the working tree";
if (ts) {
  console.error(
    `code-fingerprint: ${what}: ${files.length} file(s) — ${tokens} read as code without comments or whitespace, ${raw} byte for byte` +
      (unreadable ? ` (${unreadable} code file(s) the parser could not read cleanly, among them)` : "") +
      ".",
  );
} else {
  console.error(
    `code-fingerprint: ${what}: ${files.length} file(s), all byte for byte — TypeScript could not be loaded, so a comment or whitespace change counts as a change.`,
  );
}
console.log(fp);
