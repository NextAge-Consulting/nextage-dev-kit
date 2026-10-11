#!/usr/bin/env node
// Turns Claude Code session logs into a readable "You said / Claude said" transcript.
//
//   node transcript.mjs list  [--project <dir>]
//   node transcript.mjs build [--project <dir>] [--out <file>] <sessionId>...
//
// The project is the current git repository's root unless --project names one.
// `list` prints every session recorded for the project, oldest first.
// `build` writes the named sessions, in the order given, as one Markdown file.
// Times are shown in this machine's local timezone, which the header names.

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";

const TZ = Intl.DateTimeFormat().resolvedOptions().timeZone;
const HOUSEKEEPING = new Set(["/exit", "/rename", "/clear", "/compact", "/resume", "/config", "/model"]);

function fail(msg) {
  console.error(`transcript: ${msg}`);
  process.exit(1);
}

// The project defaults to the repository root, so the script works from any subfolder.
function defaultProject() {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return process.cwd();
  }
}

function parseArgs(argv) {
  const opts = { project: defaultProject(), out: null, ids: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--project") opts.project = argv[++i];
    else if (a === "--out") opts.out = argv[++i];
    else opts.ids.push(a);
  }
  opts.project = resolve(opts.project);
  return opts;
}

// Claude Code stores a project's logs under ~/.claude/projects/<cwd with every
// non-alphanumeric character replaced by "-">. When that folder is absent, find
// the folder whose logs record this cwd.
function logDir(project) {
  const root = join(homedir(), ".claude", "projects");
  if (!existsSync(root)) fail(`no session logs at ${root}`);
  const direct = join(root, project.replace(/[^a-zA-Z0-9]/g, "-"));
  if (existsSync(direct)) return direct;
  for (const name of readdirSync(root)) {
    const dir = join(root, name);
    if (!statSync(dir).isDirectory()) continue;
    const log = readdirSync(dir).find((f) => f.endsWith(".jsonl"));
    if (!log) continue;
    const head = readFileSync(join(dir, log), "utf8").slice(0, 200_000);
    if (head.includes(`"cwd":${JSON.stringify(project)}`)) return dir;
  }
  fail(`no session logs found for ${project}`);
}

function records(file) {
  const out = [];
  for (const line of readFileSync(file, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      out.push(JSON.parse(line));
    } catch {
      // A session still being written can end on a partial line.
    }
  }
  return out;
}

function clock(ts, withDate = false) {
  const opts = { timeZone: TZ, hour: "numeric", minute: "2-digit" };
  if (withDate) Object.assign(opts, { month: "short", day: "numeric" });
  return new Intl.DateTimeFormat("en-US", opts).format(new Date(ts));
}

function localDate(ts) {
  return new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(new Date(ts));
}

function longDate(ts) {
  return new Intl.DateTimeFormat("en-US", { timeZone: TZ, dateStyle: "long" }).format(new Date(ts));
}

// What the human typed, or null when the record is not a typed prompt.
function userText(raw) {
  if (raw.startsWith("<command-name>")) {
    const name = raw.match(/<command-name>(.*?)<\/command-name>/)?.[1];
    const args = raw.match(/<command-args>([\s\S]*?)<\/command-args>/)?.[1]?.trim();
    if (!name || HOUSEKEEPING.has(name)) return null;
    return args ? `${name} ${args}` : name;
  }
  if (raw.startsWith("<") || raw.startsWith("Caveat:") || raw.startsWith("Another Claude session sent")) return null;
  const text = raw.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, "").trim();
  return text || null;
}

function turns(file) {
  const out = [];
  for (const r of records(file)) {
    if (r.type !== "user" && r.type !== "assistant") continue;
    if (r.isSidechain || r.isMeta || r.isCompactSummary || r.isApiErrorMessage) continue;
    const content = r.message?.content;
    if (r.type === "user") {
      const blocks = typeof content === "string" ? [{ type: "text", text: content }] : (content ?? []);
      const text = blocks
        .filter((b) => b.type === "text")
        .map((b) => userText(b.text))
        .filter(Boolean)
        .join("\n\n");
      const images = blocks.filter((b) => b.type === "image").length;
      const body = [text, images ? `*[${images} image(s) attached]*` : ""].filter(Boolean).join("\n\n");
      if (body) out.push({ who: "user", ts: r.timestamp, text: body });
    } else {
      if (!Array.isArray(content) || r.message?.model === "<synthetic>") continue;
      const text = content
        .filter((b) => b.type === "text" && b.text.trim())
        .map((b) => b.text.trim())
        .join("\n\n");
      if (!text || text === "No response requested.") continue;
      const prev = out.at(-1);
      if (prev?.who === "claude") prev.text += `\n\n${text}`;
      else out.push({ who: "claude", ts: r.timestamp, text });
    }
  }
  return out;
}

function summary(file) {
  const recs = records(file);
  const stamps = recs.map((r) => r.timestamp).filter(Boolean).sort();
  const title = recs.findLast((r) => r.type === "custom-title")?.customTitle ?? "";
  const t = turns(file);
  const first = t.find((x) => x.who === "user")?.text.replace(/\s+/g, " ").slice(0, 120) ?? "";
  return { id: basename(file, ".jsonl"), start: stamps[0], end: stamps.at(-1), title, prompts: t.filter((x) => x.who === "user").length, first };
}

function list(opts) {
  const dir = logDir(opts.project);
  const rows = readdirSync(dir)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => summary(join(dir, f)))
    .filter((s) => s.start)
    .sort((a, b) => a.start.localeCompare(b.start));
  console.log(`Sessions for ${opts.project} (times in ${TZ}):\n`);
  for (const s of rows) {
    console.log(`${s.id}  ${clock(s.start, true)} – ${clock(s.end, true)}  ${s.prompts} prompts  title: ${s.title || "-"}`);
    console.log(`    first prompt: ${s.first}\n`);
  }
}

function build(opts) {
  if (!opts.ids.length) fail("build needs at least one session id (run `list` to see them)");
  const dir = logDir(opts.project);
  const project = basename(opts.project);
  const parts = opts.ids.map((id) => {
    const file = join(dir, `${id}.jsonl`);
    if (!existsSync(file)) fail(`no session ${id} in ${dir}`);
    return { ...summary(file), turns: turns(file) };
  });
  const start = parts[0].start;
  const days = [...new Set(parts.map((p) => longDate(p.start)))].join(" – ");
  let md = `# ${project} — Session Transcript\n\n*${days} · Conversation turns only; tool calls and output omitted. Times are ${TZ}.*\n`;
  parts.forEach((p, i) => {
    if (parts.length > 1) {
      md += `\n\n## Part ${i + 1}${p.title ? ` — ${p.title}` : ""} (${clock(p.start, true)} – ${clock(p.end)})\n`;
    }
    for (const t of p.turns) {
      md += t.who === "user" ? `\n---\n\n**You said** · ${clock(t.ts)}\n\n${t.text}\n` : `\n**Claude said**\n\n${t.text}\n`;
    }
  });
  const out = opts.out ? resolve(opts.out) : join(homedir(), "Downloads", `${project}-transcript-${localDate(start)}.md`);
  writeFileSync(out, md);
  const prompts = parts.reduce((n, p) => n + p.turns.filter((t) => t.who === "user").length, 0);
  console.log(`Wrote ${out}: ${parts.length} session(s), ${prompts} prompts, ${md.split(/\s+/).length} words.`);
  if (!prompts) fail("no prompts found in those sessions — the transcript is empty");
}

const [cmd, ...rest] = process.argv.slice(2);
if (cmd === "list") list(parseArgs(rest));
else if (cmd === "build") build(parseArgs(rest));
else fail("usage: transcript.mjs list|build [--project <dir>] [--out <file>] [sessionId...]");
