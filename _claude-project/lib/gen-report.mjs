// Shared HTML report generator (kit tool — invoked by skills, never imported).
//
// Renders a self-contained, theme-aware HTML document: charset + viewport meta,
// inlined CSS, base64-embedded images, and a true CSS lightbox (✕ close, ‹ › prev/
// next across every image, N/total counter). NO run-specific data lives here — a
// caller writes a JSON and this reads it. This is the ONE place the document shell
// (doctype/meta/self-contained/theme) is defined, so charset+viewport are never
// hand-rolled or forgotten.
//
// Invoke (subprocess, not import — the supported cross-skill sharing mechanism):
//   node <this> <repoRoot> <dataJsonPath> [outHtmlPath]
//
// Two input shapes are accepted:
//
//   E2E mode  — { title, subtitle, note?, extraStats?, flows: [
//                  { name, app, status:"pass|partial|fail", time, summary,
//                    steps: [ ["text","pass|fail|deferred","observation"], … ],
//                    shots: [ ["path/under/imageBase.png","caption"], … ] } ] }
//               imageBase defaults to "logs/e2e".
//
//   Analysis mode — { title, subtitle, note?, stats?: [{value,label,color?}],
//                     imageBase?: ".", sections: [
//                       { heading?, html?, images?: [["path","caption"], …] } ] }
//                     `html` is arbitrary self-contained HTML (prose, tables,
//                     inline SVG). `images` are embedded + lightboxed by this tool.
import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";

const root = resolve(process.argv[2] || ".");
const dataPath = resolve(process.argv[3] || resolve(root, "logs/e2e/results.json"));
if (!existsSync(dataPath)) {
  console.error("data JSON not found: " + dataPath);
  process.exit(1);
}
const data = JSON.parse(readFileSync(dataPath, "utf-8"));
const isE2e = Array.isArray(data.flows);
const imageBase = data.imageBase || (isE2e ? "logs/e2e" : ".");

const esc = (s) => String(s ?? "").replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]));
const mimeFor = (p) => {
  const e = p.toLowerCase().split(".").pop();
  return e === "png" ? "image/png" : e === "jpg" || e === "jpeg" ? "image/jpeg" : e === "gif" ? "image/gif" : e === "webp" ? "image/webp" : e === "svg" ? "image/svg+xml" : "application/octet-stream";
};
const embed = (p) => {
  const f = resolve(root, imageBase, p);
  if (!existsSync(f)) return null;
  const mime = mimeFor(p);
  if (mime === "image/svg+xml") return `data:image/svg+xml,${encodeURIComponent(readFileSync(f, "utf8"))}`;
  return `data:${mime};base64,${readFileSync(f).toString("base64")}`;
};

// One ordered gallery across the WHOLE document so lightbox arrows walk every image.
let _gi = 0;
const allShots = [];
const claimShots = (pairs) =>
  (pairs || []).map(([p, c]) => ({ d: embed(p), c })).filter((x) => x.d).map((x) => ({ ...x, i: ++_gi }));

let flows = [], sections = [];
if (isE2e) {
  flows = data.flows.map((f) => ({ ...f, _shots: claimShots(f.shots) }));
  flows.forEach((f) => f._shots.forEach((s) => allShots.push(s)));
} else {
  sections = (data.sections || []).map((s) => ({ ...s, _shots: claimShots(s.images) }));
  sections.forEach((s) => s._shots.forEach((x) => allShots.push(x)));
}
const N = _gi;
const wrapIdx = (i, delta) => ((i - 1 + delta + N) % N) + 1;
const renderShot = (s) => `<figure class="fig" id="shot${s.i}">
    <a class="open" href="#shot${s.i}"><img src="${s.d}" alt="${esc(s.c)}"></a>
    <figcaption>${esc(s.c)}</figcaption>
    <a class="lb-backdrop" href="#top" aria-label="Close"></a>
    <a class="lb-close" href="#top" title="Close">✕</a>
    <a class="lb-prev" href="#shot${wrapIdx(s.i, -1)}" title="Previous">‹</a>
    <a class="lb-next" href="#shot${wrapIdx(s.i, 1)}" title="Next">›</a>
    <span class="lb-count">${s.i} / ${N}</span>
  </figure>`;

const badge = (s) => `<span class="badge ${s}">${s === "pass" ? "✅ pass" : s === "partial" ? "⚠️ partial" : "❌ fail"}</span>`;
const stepBadge = (s) => (s === "pass" ? "✅" : s === "fail" ? "❌" : "⚠️");

const flowHtml = flows.map((f) => `
  <section class="flow ${f.status}">
    <h2>${esc(f.name)} ${badge(f.status)} <span class="time">${esc(f.time || "")}</span></h2>
    <p class="sum">${esc(f.summary || "")}</p>
    <div class="steps"><table><thead><tr><th></th><th>Step</th><th>Observation</th></tr></thead><tbody>
    ${(f.steps || []).map(([t, s, o]) => `<tr class="${s}"><td>${stepBadge(s)}</td><td>${esc(t)}</td><td>${esc(o)}</td></tr>`).join("")}
    </tbody></table></div>
    <div class="gallery">${f._shots.map(renderShot).join("")}</div>
  </section>`).join("");

// Analysis sections: `html` is trusted, self-contained content the caller built.
const sectionHtml = sections.map((s) => `
  <section class="sec">
    ${s.heading ? `<h2>${esc(s.heading)}</h2>` : ""}
    ${s.html ? `<div class="body">${s.html}</div>` : ""}
    ${s._shots.length ? `<div class="gallery">${s._shots.map(renderShot).join("")}</div>` : ""}
  </section>`).join("");

const tallyTiles = isE2e
  ? [
      { value: flows.filter((f) => f.status === "pass").length, label: "passed", color: "pass" },
      ...(flows.some((f) => f.status === "partial") ? [{ value: flows.filter((f) => f.status === "partial").length, label: "partial", color: "partial" }] : []),
      ...(flows.some((f) => f.status === "fail") ? [{ value: flows.filter((f) => f.status === "fail").length, label: "failed", color: "fail" }] : []),
      { value: flows.length, label: "flows total" },
      ...(data.extraStats || []),
    ]
  : data.stats || [];
const statHtml = tallyTiles.map((s) => `<div class="stat"><b${s.color ? ` style="color:var(--${s.color})"` : ""}>${esc(s.value)}</b><span>${esc(s.label)}</span></div>`).join("");

const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(data.title || "Report")}</title>
<style>
:root{--bg:#fff;--fg:#1a1a1a;--mut:#666;--line:#e2e2e2;--card:#f7f7f8;--pass:#0a7d33;--partial:#b8860b;--fail:#c0392b;--accent:#2563eb}
@media(prefers-color-scheme:dark){:root{--bg:#151517;--fg:#e8e8e8;--mut:#9a9a9a;--line:#2c2c30;--card:#1e1e22;--pass:#4ade80;--partial:#eab308;--fail:#f87171;--accent:#60a5fa}}
*{box-sizing:border-box}body{margin:0;font:15px/1.6 -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
.wrap{max-width:980px;margin:0 auto;padding:24px}
h1{font-size:22px;margin:0 0 4px}.meta{color:var(--mut);font-size:13px;margin:0 0 16px}
.tally{display:flex;gap:12px;flex-wrap:wrap;margin:16px 0 8px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 16px;min-width:104px}
.stat b{display:block;font-size:22px}.stat span{color:var(--mut);font-size:12px}
.note{background:var(--card);border-left:3px solid var(--partial);border-radius:6px;padding:12px 16px;margin:16px 0;font-size:14px}
.flow,.sec{border:1px solid var(--line);border-radius:12px;padding:16px 18px;margin:14px 0;background:var(--card)}
.flow.partial{border-color:var(--partial)}.flow.fail{border-color:var(--fail)}
h2{font-size:16px;margin:0 0 6px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.sec h2{display:block}
.time{color:var(--mut);font-size:12px;font-weight:400;margin-left:auto}
.sum{color:var(--mut);font-size:13px;margin:0 0 12px}
.body{font-size:14px}.body h3{font-size:14px;margin:14px 0 4px}.body p{margin:8px 0}.body code{background:var(--bg);border:1px solid var(--line);border-radius:4px;padding:1px 4px;font-size:12px}
.body pre{background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:12px;overflow-x:auto;font-size:12px}
.badge{font-size:12px;padding:2px 8px;border-radius:20px;font-weight:600}
.badge.pass{background:color-mix(in srgb,var(--pass) 18%,transparent);color:var(--pass)}
.badge.partial{background:color-mix(in srgb,var(--partial) 20%,transparent);color:var(--partial)}
.badge.fail{background:color-mix(in srgb,var(--fail) 20%,transparent);color:var(--fail)}
.steps,.body{overflow-x:auto}table{border-collapse:collapse;width:100%;font-size:13px}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line);vertical-align:top}
th{color:var(--mut);font-weight:600}tr.fail td{color:var(--fail)}
.gallery{display:flex;gap:12px;flex-wrap:wrap;margin-top:12px}
.fig{margin:0;max-width:260px}
.open{display:block}.open img{max-width:100%;border:1px solid var(--line);border-radius:8px;display:block;cursor:zoom-in}
figcaption{font-size:11px;color:var(--mut);margin-top:4px;text-align:center}
.lb-backdrop,.lb-close,.lb-prev,.lb-next,.lb-count{display:none}
.fig:target .open img{position:fixed;inset:0;margin:auto;max-width:92vw;max-height:86vh;width:auto;height:auto;z-index:1000;cursor:default;border-color:transparent;border-radius:6px;box-shadow:0 10px 50px rgba(0,0,0,.6)}
.fig:target .lb-backdrop{display:block;position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:999}
.fig:target .lb-close,.fig:target .lb-prev,.fig:target .lb-next{display:flex;align-items:center;justify-content:center;position:fixed;z-index:1001;color:#fff;text-decoration:none;background:rgba(255,255,255,.14);border-radius:50%;line-height:1;user-select:none}
.fig:target .lb-close{top:16px;right:20px;width:44px;height:44px;font-size:24px}
.fig:target .lb-prev,.fig:target .lb-next{top:50%;transform:translateY(-50%);width:54px;height:54px;font-size:40px;padding-bottom:6px}
.fig:target .lb-prev{left:16px}.fig:target .lb-next{right:16px}
.fig:target .lb-count{display:block;position:fixed;bottom:20px;left:50%;transform:translateX(-50%);z-index:1001;color:#fff;font-size:13px;background:rgba(0,0,0,.55);padding:4px 14px;border-radius:20px}
.lb-close:hover,.lb-prev:hover,.lb-next:hover{background:rgba(255,255,255,.3)}
.foot{font-size:12px;color:var(--mut);margin-top:24px;border-top:1px solid var(--line);padding-top:12px}
</style></head><body><div class="wrap" id="top">
<h1>${esc(data.title || "Report")}</h1>
<p class="meta">${data.subtitle || ""}</p>
${statHtml ? `<div class="tally">${statHtml}</div>` : ""}
${data.note ? `<div class="note">${data.note}</div>` : ""}
${isE2e ? flowHtml : sectionHtml}
${data.footer ? `<p class="foot">${data.footer}</p>` : ""}
</div></body></html>`;

const out = resolve(process.argv[4] || resolve(root, isE2e ? "logs/e2e/report.html" : "report.html"));
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, html);
console.log("wrote " + out + " (" + Math.round(html.length / 1024) + " KB, " + N + " images)");
