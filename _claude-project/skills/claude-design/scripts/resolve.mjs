/* Pure functions that turn the UI package's token CSS into a Claude Design
 * "Design System" artifact's tokens.json. No filesystem — build.mjs does I/O.
 *
 * The artifact reads a narrower colour language than a browser: literals and
 * aliases only — no var(), no color-mix(), no named colours. The source keeps its
 * references (a dark token defined as a mix of another follows that token when
 * it changes); this module resolves them per theme at sync time, with Color.js
 * doing the colour arithmetic exactly as the browser does. Anything it does not
 * recognise throws, so a new construct fails the sync instead of dropping a token
 * silently — the artifact would otherwise fill a missing dark value with the
 * light one.
 *
 * Color.js is passed in, never imported: the token checker imports this module's
 * parser and has no use for colour arithmetic. */

const HEADER = /─/;

/** The comment pair that keeps declarations out of the published system. */
const PUBLISH_OFF = /^\/\*\s*publish:\s*off\b/;
const PUBLISH_ON = /^\/\*\s*publish:\s*on\b/;

/** The selectors a token file may use for its light and dark themes, unless the
 * project's config names its own. */
export const DEFAULT_THEME_SELECTORS = {
  light: [':root', 'html'],
  dark: ['.dark', ':root.dark', 'html.dark', '[data-theme="dark"]', ':root[data-theme="dark"]', 'html[data-theme="dark"]'],
};

const normalizeSelector = (s) => s.replace(/\s+/g, '').replace(/['"]/g, '');

/** Parse the top-level blocks that declare custom properties into declarations
 * with their usage comment: the comment directly above a declaration, or trailing
 * it on the same line. A comment containing `─` is a group header and belongs to
 * no token. A declaration between `/* publish: off *\/` and `/* publish: on *\/`
 * is marked `publish: false` — the pair may wrap declarations inside a block, or
 * whole blocks. Each block is `light` or `dark`; a block declaring
 * tokens under any other selector throws, because skipping it would silently give
 * its tokens the light values. A light block holding only `@variant dark { … }` —
 * Tailwind's way of writing dark values once for both the OS preference and a
 * class — is a dark block. A block may sit on one line. */
export function parseTokenBlocks(css, selectors = DEFAULT_THEME_SELECTORS) {
  const light = new Set(selectors.light.map(normalizeSelector));
  const dark = new Set(selectors.dark.map(normalizeSelector));
  const blocks = [];
  for (const { selector, body, off } of topLevelBlocks(css)) {
    const variant = /^\s*@variant\s+([\w-]+)\s*\{([\s\S]*)\}\s*$/.exec(body);
    if (variant) {
      if (!light.has(normalizeSelector(selector)) || variant[1] !== 'dark')
        throw new Error(`token block under an unrecognised variant: ${selector} @variant ${variant[1]}`);
      if (/(^|[\s;{])--[\w-]+\s*:/.test(variant[2])) blocks.push({ selector: `${selector} @variant dark`, theme: 'dark', decls: parseDecls(variant[2], !off) });
      continue;
    }
    if (!/(^|[\s;{])--[\w-]+\s*:/.test(body)) continue;
    const key = normalizeSelector(selector);
    const theme = light.has(key) ? 'light' : dark.has(key) ? 'dark' : null;
    if (!theme) throw new Error(`token block under an unrecognised selector: ${selector}`);
    blocks.push({ selector, theme, decls: parseDecls(body, !off) });
  }
  return blocks;
}

/** Every top-level `selector { body }`, braces matched and comments skipped, so a
 * block on one line is found the same as one spread over several. `off` is true
 * for a block between top-level publish: off and publish: on comments. At-rules
 * that wrap other rules (`@layer`, `@media`) are not token blocks and are passed over. */
function topLevelBlocks(css) {
  const out = [];
  let depth = 0;
  let start = 0;
  let open = -1;
  let off = false;
  for (let i = 0; i < css.length; i++) {
    if (css.startsWith('/*', i)) {
      const end = css.indexOf('*/', i + 2);
      const comment = css.slice(i, end < 0 ? css.length : end + 2);
      if (depth === 0 && PUBLISH_OFF.test(comment)) off = true;
      if (depth === 0 && PUBLISH_ON.test(comment)) off = false;
      i = end < 0 ? css.length : end + 1;
      continue;
    }
    const ch = css[i];
    if (ch === '{') {
      if (depth === 0) open = i;
      depth++;
    } else if (ch === '}') {
      depth--;
      if (depth === 0) {
        const selector = css.slice(start, open).replace(/\/\*[\s\S]*?\*\//g, '').trim();
        const body = css.slice(open + 1, i);
        // An at-rule wrapping rules (`@layer`, `@media`) is passed over; one declaring
        // tokens directly (`@theme`) is a block, and an unrecognised one.
        if (selector && (!selector.startsWith('@') || !body.includes('{'))) out.push({ selector, body, off });
        start = i + 1;
      }
    } else if (ch === ';' && depth === 0) start = i + 1;
  }
  return out;
}

function parseDecls(body, publishAtStart = true) {
  const decls = [];
  let pending = null;
  let open = null;
  let publish = publishAtStart;
  // A one-line block holds its declarations on one line; give each its own.
  const lines = body.includes('\n') ? body.split('\n') : body.split(/;(?![^(]*\))/).map((d) => (d.trim() ? `${d.trim()};` : ''));
  for (const raw of lines) {
    const line = raw.trim();
    if (open !== null) {
      open.push(line);
      if (line.endsWith('*/')) {
        pending = clean(open.join(' '));
        open = null;
      }
      continue;
    }
    if (line === '') {
      pending = null;
      continue;
    }
    if (PUBLISH_OFF.test(line) || PUBLISH_ON.test(line)) {
      publish = PUBLISH_ON.test(line);
      pending = null;
      continue;
    }
    if (line.startsWith('/*')) {
      if (line.endsWith('*/')) pending = clean(line);
      else open = [line];
      continue;
    }
    const d = /^--([\w-]+):\s*(.+?);\s*(\/\*(.*?)\*\/)?$/.exec(line);
    if (!d) throw new Error(`unparsed line in token block: ${line}`);
    const trailing = d[4] ? d[4].trim() : '';
    const above = pending && !HEADER.test(pending) ? pending : '';
    decls.push({ name: d[1], value: d[2].trim(), usage: trailing || above, ...(publish ? {} : { publish: false }) });
    pending = null;
  }
  return decls;
}

const clean = (s) =>
  s
    .replace(/^\/\*/, '')
    .replace(/\*\/$/, '')
    .replace(/\s+/g, ' ')
    .trim();

/** Literal forms the artifact accepts as written: plain numeric colour functions and hex. */
const ACCEPTED_LITERAL = /^(?:(?:oklch|oklab|rgba?|hsla?|lab|lch)\([^()]*\)|color\([^()]*\)|#[0-9a-f]{3,8})$/i;

/** Replace every var() with its value in this theme, innermost first, following
 * chains and fallbacks. A variable that resolves to nothing throws. */
export function substitute(raw, env, depth = 0) {
  if (depth > 32) throw new Error(`var() chain too deep or circular at ${raw}`);
  let out = raw;
  const ref = /var\(\s*--([\w-]+)\s*(?:,\s*((?:[^()]|\([^()]*\))*))?\)/;
  for (let m = ref.exec(out); m; m = ref.exec(out)) {
    const own = env.get(m[1]);
    const value = own !== undefined ? substitute(own, env, depth + 1) : m[2] !== undefined ? substitute(m[2].trim(), env, depth + 1) : null;
    if (value === null) throw new Error(`var(--${m[1]}) resolves to nothing`);
    out = out.slice(0, m.index) + value + out.slice(m.index + m[0].length);
  }
  return out.trim();
}

/** Is this token, resolved in its theme, a colour (as opposed to a number or length)? */
export function isColorToken(raw, env, Color) {
  let v;
  try {
    v = substitute(raw, env);
  } catch {
    return false;
  }
  if (/^color-mix\(/.test(v)) return true;
  if (/^-?[\d.]+[a-z%]*$/i.test(v)) return false;
  try {
    new Color(v);
    return true;
  } catch {
    return false;
  }
}

/**
 * Resolve one colour token's raw value in a theme.
 * @param {string} raw        the declared value
 * @param {Map<string,string>} env  every token's raw value in this theme
 * @param {Set<string>} published   the colour tokens the artifact carries (aliases allowed to these)
 * @param {Function} Color  Color.js (../vendor/color.cjs)
 * @returns {string} a literal the artifact accepts, or `{name}` for an alias
 */
export function resolveColor(raw, env, published, Color) {
  const alias = /^var\(--([\w-]+)\)$/.exec(raw.trim());
  if (alias && published.has(alias[1])) return `{${alias[1]}}`;
  const v = substitute(raw, env);
  if (v === 'transparent') return 'oklch(0 0 0 / 0)';
  if (ACCEPTED_LITERAL.test(v)) return v;
  if (v.startsWith('color-mix(')) return format(mix(v, Color), Color);
  let named;
  try {
    named = new Color(v);
  } catch {
    throw new Error(`unsupported colour value: ${raw}`);
  }
  // A named colour (`white`), which the artifact refuses, as hex.
  if (/^[a-z]+$/i.test(v)) return named.to('srgb').toString({ format: 'hex', collapse: false });
  throw new Error(`unsupported colour value: ${raw}`);
}

/** color-mix(in <space>, A p%, B q%) per CSS Color 5: percentages normalised, a
 * sum under 100% lowering alpha, premultiplied interpolation in the named space.
 * Returns the mixed Color, and the operand written as oklch when the other side
 * is fully transparent — so the result can be written in the token's own form. */
function mix(expr, Color) {
  const inner = /^color-mix\(\s*in\s+([\w-]+)(?:\s+(?:shorter|longer|increasing|decreasing)\s+hue)?\s*,(.*)\)$/s.exec(expr);
  if (!inner) throw new Error(`unsupported colour-mix: ${expr}`);
  const space = inner[1];
  const parts = splitTopLevel(inner[2]);
  if (parts.length !== 2) throw new Error(`unsupported colour-mix arguments: ${expr}`);
  const [a, b] = parts.map((p) => {
    const m = /^(.*?)(?:\s+([\d.]+)%)?$/s.exec(p.trim());
    const text = m[1].trim();
    return { text, color: operand(text, Color), pct: m[2] === undefined ? undefined : Number(m[2]) };
  });
  let pa = a.pct;
  let pb = b.pct;
  if (pa === undefined && pb === undefined) pa = pb = 50;
  else if (pa === undefined) pa = 100 - pb;
  else if (pb === undefined) pb = 100 - pa;
  const total = pa + pb;
  if (total === 0) throw new Error(`colour-mix percentages sum to zero: ${expr}`);
  let mixed;
  try {
    mixed = Color.mix(a.color, b.color, pb / total, { space, premultiplied: true, outputSpace: space });
  } catch (e) {
    throw new Error(`unsupported colour-mix space ${space}: ${expr} (${e.message})`);
  }
  mixed.alpha = mixed.alpha * (total < 100 ? total / 100 : 1);
  const keep = b.color.alpha === 0 ? a.text : a.color.alpha === 0 ? b.text : null;
  return { mixed, keep: keep && /^oklch\(/.test(keep) ? keep : null };
}

/** One colour-mix operand as a Color: a literal, a named colour, or a nested mix. */
function operand(text, Color) {
  if (text.startsWith('color-mix(')) return mix(text, Color).mixed;
  try {
    return new Color(text);
  } catch {
    throw new Error(`unsupported colour-mix operand: ${text}`);
  }
}

/** A mixed colour in a form the artifact accepts. Mixing with transparent keeps
 * the colour and only lowers alpha — written in the source colour's own oklch
 * form so it reads like the token it came from; anything else as oklab. */
function format({ mixed, keep }, Color) {
  const alpha = round(mixed.alpha);
  if (alpha === 0) return 'oklch(0 0 0 / 0)';
  if (keep) {
    const [L, C, H] = /^oklch\(\s*([\d.]+)\s+([\d.]+)\s+(-?[\d.]+)/.exec(keep).slice(1);
    return `oklch(${L} ${C} ${H}${alpha < 1 ? ` / ${alpha}` : ''})`;
  }
  const [L, A, B] = new Color(mixed).to('oklab').coords.map((n) => round(n ?? 0));
  return `oklab(${L} ${A} ${B}${alpha < 1 ? ` / ${alpha}` : ''})`;
}

function splitTopLevel(s) {
  const out = [];
  let depth = 0;
  let cur = '';
  for (const ch of s) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) {
      out.push(cur);
      cur = '';
    } else cur += ch;
  }
  out.push(cur);
  return out;
}

const round = (n) => Math.round(n * 10000) / 10000;
