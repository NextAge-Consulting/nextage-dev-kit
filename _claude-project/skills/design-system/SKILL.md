---
name: design-system
description: Project-agnostic UI/design-system discipline backed by a per-project `design.md` (google-labs-code spec). Use when creating or styling UI components, pages, forms, or any frontend work in any kit-enabled project. The skill enforces "read the project's design.md for tokens, ground the work in the project's real components for look-and-feel, then apply universal styling discipline" and refuses to proceed if `design.md` is missing at the project root.
---

# Design System

This skill is the universal layer of the design-system discipline shared across all kit-enabled projects. It is paired with a **per-project `design.md`** at the project root that defines the actual tokens, atom styling, and brand voice. The skill itself contains zero project-specific tokens — every concrete value comes from the project's `design.md`.

## The spec this skill depends on

The project's `design.md` MUST conform to the **google-labs-code `design.md` spec** (https://github.com/google-labs-code/design.md). The spec defines:

- An optional YAML frontmatter block of machine-readable design tokens: `colors`, `typography`, `rounded`, `spacing`, `components`
- A markdown body with required-order sections: Overview, Colors, Typography, Layout, Elevation & Depth, Shapes, Components, Do's and Don'ts
- Component definitions scoped to **atoms only** (buttons, chips, lists, tooltips, checkboxes, radios, input fields) with property tokens: `backgroundColor`, `textColor`, `typography`, `rounded`, `padding`, `size`, `height`, `width`
- Token reference syntax: `{colors.primary}`, `{rounded.md}`, etc.

**This skill does not define those things.** It defines the workflow and discipline that uses them.

## Procedure — apply on every UI task

### Step 1: Read the project's `design.md`

Before writing or editing ANY UI / styling code, **read `design.md` at the project root**:

```
<project-root>/design.md
```

If `design.md` is absent, **HARD STOP**:

- Do not proceed with the UI task
- Surface to the user verbatim: *"This project has no `design.md` at the project root. Per the kit-canonical design-system discipline, UI work cannot proceed without a project-level design system spec. Either (a) generate one from the codebase first, or (b) explicitly authorize ad-hoc styling for this task (rare; treat as tech debt)."*
- Wait for direction

Why hard-stop: ad-hoc styling without a design system spec is how token drift starts. The skill exists to prevent that.

### Step 2: Ground in the existing implementation (MANDATORY — this is where look-and-feel comes from)

`design.md` gives you tokens and atom specs. It does **NOT** give you the project's *look and feel* — elevation, shadows, motion, hover behavior, border treatments, density, polish level. That lives **only in the real components.** A prose description of "the vibe" cannot be executed reliably; a real component can. So before writing ANY composite UI (a card, a row, a panel, a form, a dashboard, a whole screen), **find the closest existing analog in THIS repo and build from it.** Not a fallback — the primary source of fidelity.

This is a search you run every time. No hardcoded paths, no per-project list — it works in any repo because it keys off the project's own structure:

1. **Name the role** of what you're building — card / table / list-row / form field / dashboard / modal / nav / status chip / empty-state, etc.
2. **Find the nearest existing instance in the repo.** Glob the component and route trees; grep for the role and for the distinctive utilities it would use — e.g. `Grep "rounded-2xl" --glob "**/components/**/*.tsx"` for the card treatment, `Grep "border-l-" ...` / `Grep "hover:scale" ...` / `Grep "shadow-" ...` to see how the project *actually* does elevation and motion, `Glob "**/routes/**"` for the closest whole screen. **Do not ask the user for the path — find it yourself.**
3. **Read the top 1–3 matches in full.** Extract the *real* patterns: every class they use for elevation, hover, transition/animation, borders, and spacing — not just the color tokens. This is the step that carries the feel.
4. **Build from those patterns for _vocabulary_** — the tokens, the construction (how a card/row/chip is assembled), the status language, the motion idioms. Pick the **most-polished** existing exemplar as your baseline, never the average or the oldest. Then **level the execution UP toward the polish bar in `design.md`'s guideline** (the target feel — layered depth, real motion, hover / micro-interaction). The components are concrete *examples of the vocabulary, not a ceiling on quality.*

If **no analog exists**, say so explicitly — it's a genuinely new pattern. Research primary-source design systems, propose the approach, and get sign-off (the same bar the `ui-patterns` skill sets for new interaction patterns). **Never** fill the gap by inventing from `design.md` prose alone — that is exactly what produces on-spec-but-off-brand, ho-hum output.

**Strive up, never average down (critical).** `design.md` is the *guideline* — the intended bar, deliberately ahead of the current code. The components are *examples* of the vocabulary, and they will often be less polished than the bar. That is expected and fine. Match their vocabulary (tokens, structure, brand language) but **raise the execution toward the guideline** — depth, motion, hover, tactile feedback. **NEVER downgrade a new, more-polished component to match a plainer existing one, or to match sparse prose.** Grounding in components exists to carry brand *fidelity*, not to clamp *quality* to the least-common-denominator. When in doubt, build richer, not plainer. If you deliberately raised the bar above your exemplar, say so in the build-from citation.

Why this step is mandatory and first-class (not a footnote): `design.md`'s "feel" prose is unenforceable on its own — every generator interprets it differently. Grounding in real components carries the *vocabulary* faithfully; striving toward the guideline carries the *quality*. Skipping the grounding produces off-brand output; averaging down to the components produces on-brand-but-mediocre output. You need both halves.

### Step 3: Identify the right tokens for the task

`design.md`'s YAML frontmatter is the normative source. From it:

- **Colors**: identify the semantic color tokens the task needs (e.g. for a primary CTA, `colors.primary` + `colors.primary-foreground`; for a form error, the error-feedback group)
- **Typography**: identify the typography level (e.g. `typography.body-md` for default body, `typography.h2` for a section header)
- **Rounded**: identify the radius (`rounded.lg` is the most common; pill-shaped only when the design.md prose calls it out as a distinct shape token)
- **Spacing**: use the project's spacing scale; never reach for raw px values when a scale token fits
- **Component atoms**: if the task is adding/editing a button, card, input, alert, etc., copy the property tokens from the relevant `components.<name>` entry as your starting point

**Never invent token values.** Every color, radius, padding number must trace back to a token in `design.md` or a Tailwind utility that maps to one of those tokens. If a needed value doesn't exist, surface that as a design-system gap (add a Known Gaps entry; don't ad-hoc it).

### Step 4: Apply universal styling discipline

These rules are project-agnostic and apply on top of the project's tokens:

- **Semantic over primitive.** When a semantic token exists for the role (`primary`, `card-title`, `action-primary-bg`), use it. Reach for primitive tokens (raw brand colors like `lg-navy`) only for one-off accents that have no semantic mapping. The token architecture is typically: primitive → semantic → shadcn → Tailwind utility — always grab the highest-level abstraction that fits the role.
- **No inline `style={{}}` for colors.** All color comes from Tailwind utility classes mapped to the `@theme` tokens. Inline styles bypass the design system and are forbidden. The only common exception is SVG `fill="var(--color-...)"` because Tailwind cannot target SVG attributes.
- **No raw hex values in components.** Every color reference in component code must resolve to a token. If a hex appears in a JSX/CSS file, it's a smell — either map it to a semantic token or add the token to `design.md`.
- **No `space-y-*` / `space-x-*`.** Use `flex flex-col gap-N` or `flex gap-N`. Reason: predictable, no margin-collapse edge cases, plays well with conditional rendering.
- **Use `size-N` when width equals height.** `size-8` not `w-8 h-8`. Smaller, clearer intent.
- **Use Tailwind `hover:` variants for hover state.** Never JS event handlers (`onMouseEnter`/`onMouseLeave`) for hover-only color changes — that's reinventing CSS in JavaScript and breaks under SSR.
- **Use the `cn()` utility for conditional class joins.** Import from `@/lib/utils` (or the project's equivalent). `clsx`/`classnames`-style string concatenation is forbidden when conditionals are involved.
- **Accessibility lives in `a11y-baseline.md`.** Icon-only buttons need accessible names; SVGs need `<title>` or `aria-hidden`; labels need `htmlFor` + `id`. That rule auto-loads on JSX/TSX edits and is the authoritative source for a11y patterns — don't duplicate its content here.

### Step 5: Validate the result

After making changes that affect tokens (added a color, added an atom variant, etc.), validate `design.md` is still spec-compliant:

```bash
npm run lint:design
```

This runs the `@google/design.md` spec linter. It must be wired as a project dev tool — `@google/design.md` in `devDependencies` plus a `"lint:design": "design.md lint design.md"` script (see kit HANDBOOK §12a.4). Use the declared script, **not** an ad-hoc `npx @google/design.md …`: declaring it keeps the lint reproducible and avoids agent sandboxes blocking an undeclared external download. If the script is missing, add the devDependency + script first, then run it.

If `design.md` was not modified, skip this step. If it was, the lint MUST pass before changes are committed. Fix lint findings before declaring the task done.

If the lint fails for a reason that isn't your edit (pre-existing issue), surface it explicitly — per the project constitution's "Own All Errors" rule, you fix it or document it; you don't step over it.

**Stateful atoms and computed tokens go in prose, not the YAML.** The `components:` YAML accepts only the spec's fixed property set (`backgroundColor`, `textColor`, `typography`, `rounded`, `padding`, `size`, `height`, `width`). Stateful atoms (tone maps, rings, variant escalation) and computed tokens don't fit those and will fail `lint:design` — describe them in `design.md` prose instead.

**Don't run checks during pre-approval UI iteration.** While iterating on layout, don't run tsc / biome / screenshots / `lint:design` after each tweak — the human inspects live via HMR. Do the reconciliation pass (tokenize raw values, document new patterns in `design.md`) and run the checks once, after the design is approved.

## The build-from gate (non-negotiable)

Before delivering any composite UI, state — in your response to the user — the reference you built from:

```
Built from: <path(s) to the existing component(s)/screen(s) you matched in Step 2>
```

- Matched an analog → cite the exact path(s).
- Raised the execution above the exemplar (strove up toward the guideline per Step 2) → note it: `Built from: <path> (leveled up: <what you added — depth, motion, etc.>)`. This is encouraged, not an exception.
- Genuinely new pattern → write `Built from: none — new pattern` and confirm you researched primary sources + got sign-off per Step 2.

No citation means Step 2 didn't happen and the work is **incomplete** — the same standard as shipping a signature change without the caller scan. This gate exists because "ground in the real components" only sticks when it's *cited*, not merely encouraged: the constitution's caller-scan attestation (§XIV) works for exactly this reason. An uncited UI change is presumed to have been invented from prose, and prose produces off-brand output.

## What `design.md` covers vs what it doesn't

`design.md` is scoped to **atoms and tokens**, per the google spec. It does NOT cover:

- Composite layout patterns (modal scaffold, dashboard widget composition)
- Interaction patterns (loading states, optimistic UI, error recovery)
- User flow patterns (auth flows, multi-step wizards)
- Code organization (shared constants, file structure)

Everything on that list is exactly what **Step 2 (Ground in the existing implementation)** handles: the project's own codebase is the authoritative cookbook for composites, interaction, flows, and look-and-feel. That is not an optional fallback for "harder" tasks — it is the mandatory, cited step for *every* composite UI task (see the build-from gate above). `design.md` owns tokens and atoms; the real components own everything else. Do not invent compositions that don't already exist in the project; find the analog and build from it, or raise a genuinely-new pattern with the user first.

## Brand voice and tone

`design.md`'s **Overview** section captures the brand voice (e.g. "trade-focused, utility-first" vs "playful and approachable"). Use it for **copy/wording tone** — the words in the UI — and as high-level interpretive context. Do **not** use it to resolve *visual* feel (density, elevation, emphasis, polish): prose cannot faithfully specify those, and reading them out of prose is what produces off-brand output. Visual feel comes from Step 2 (the real components), never from the Overview paragraph. The Overview is also the human-facing brand summary (marketing, onboarding) — so keep its prose accurate to the shipped product, but treat the components as the source of truth for how anything actually looks.

## Common file locations

These vary per project; check `design.md`'s prose for the actual paths. Typical layout:

- `<project-root>/design.md` — the design system spec (this skill's authority)
- `<project-root>/<ui-home>/src/styles.css` — Tailwind v4 `@theme` block where tokens are declared as CSS variables
- `<project-root>/<ui-home>/src/components/ui/` — shadcn atoms (button, input, label, dialog, etc.)
- `<project-root>/<ui-home>/src/lib/utils.ts` — `cn()` utility

`<ui-home>` is where the project keeps its **client-clean** UI — either **per-app** (`apps/<app>/`) or a **dedicated client-only UI workspace** (`packages/ui/`) consumed by every front-end app. Which one is a project choice; check `design.md` / the project's rules. Either way the client/server wall in `ui-design.md` is a hard rule: the UI home holds no server/DB code.

The CSS `@theme` block is the **runtime source of truth for tokens** — what the browser actually sees. `design.md` documents intent; the CSS implements it. If they diverge, the CSS wins (and `design.md` should be updated to match).

For **look-and-feel** (elevation, motion, composition, density) there is a second source of truth: the **real components** under `src/components/**` and the route tree. `design.md`'s prose about feel is descriptive only — if it disagrees with the components, the components win, and the prose should be corrected. This is why Step 2 reads components, not paragraphs.

## When this skill applies

- Creating any new UI component
- Editing styling on an existing component
- Adding a new page or route with visible UI
- Refactoring to use the design system (replacing ad-hoc styles with semantic tokens)
- Reviewing UI work for token compliance

## When this skill does NOT apply

- Backend / server function work
- Build / config / CI changes
- Documentation edits outside of `design.md` itself
- Code with no user-visible surface

## Adjacent skills and rules

This skill cooperates with — and never duplicates — the following:

- **`a11y-baseline.md` rule** — auto-loaded on every JSX/TSX edit; authoritative for accessibility patterns
- **`typescript-rules.md` rule** — auto-loaded on TS/TSX; authoritative for TS quality discipline, frontend conventions, no-toast policy
- **`shadcn` skill** — invoked when adding new shadcn components or working with the registry
