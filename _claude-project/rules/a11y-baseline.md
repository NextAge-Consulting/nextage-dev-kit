---
paths: "**/*.{tsx,jsx}"
---

# Accessibility Baseline

Auto-loaded whenever Claude edits a JSX/TSX file. Apply these rules at
composition time. `biome lint` is the safety net — it runs in the gitflow
pre-commit hook and on every PR via `ci.yml` — but the goal is to write
a11y-correct code on the first try so the safety net stays quiet.

AI-generated JSX skips a11y by default because training-data examples omit
it. The list below covers every a11y rule that actually fires on this
codebase plus the two rules (`suspicious/noArrayIndexKey`,
`suspicious/noExplicitAny`) that disable the type information a11y rules
depend on.

## Buttons — always set `type=`

Native `<button>` defaults to `type="submit"`. Inside a `<form>` that
auto-submits on any click. Action buttons need `type="button"`; form
submit buttons need `type="submit"`.

The shared shadcn `Button` primitive (`components/ui/button.tsx`) defaults
to `type="button"`. Raw `<button>` elements MUST set `type=` explicitly.

## Icon-only buttons — always provide an accessible name

A button whose only visible content is an icon (no visible text) has no
accessible name by default. Screen readers announce "button" with no
context. Keyboard users see focus indicator but don't know what the
action does. **Three valid patterns:**

```tsx
// 1. aria-label — simplest; preferred when no tooltip is needed
<Button variant="ghost" size="icon" aria-label="Close dialog">
  <X className="size-4" />
</Button>

// 2. Tooltip wrapper — best UX when the action benefits from a hover hint
<Tooltip>
  <TooltipTrigger asChild>
    <Button variant="ghost" size="icon" aria-label="Delete row">
      <Trash2 className="size-4" />
    </Button>
  </TooltipTrigger>
  <TooltipContent>Delete row</TooltipContent>
</Tooltip>

// 3. Visually-hidden span — when the icon already conveys meaning to
//    sighted users and only screen readers need text
<Button variant="ghost" size="icon">
  <Settings className="size-4" />
  <span className="sr-only">Open settings</span>
</Button>
```

**Note:** Pattern 2 still includes `aria-label` on the button itself
because the `TooltipContent` is not the button's accessible name —
it's the tooltip's content. The button needs its own name.

**Label wording.** Describe the action, not the icon. The accessible
name is announced verbatim by screen readers and shown on focus.

| ✅ Good | ❌ Bad |
|---------|--------|
| "Close dialog" | "X" |
| "Delete row" | "Trash icon" |
| "Open settings" | "Settings" (ambiguous without context) |
| "View order details" | "Click here" |

**Combination with SVG `<title>`.** If the icon is an inline `<svg>`,
the SVG still needs a `<title>` OR `aria-hidden="true"` per the next
section. When the parent button has an accessible name (any of the three
patterns above), the SVG should be `aria-hidden="true"` — putting names
on both creates double-announcement.

## SVG icons — add `<title>` or hide from assistive tech

Every inline `<svg>` must have ONE of:

1. A `<title>` child with non-empty text (screen readers announce it as
   the element's accessible name). Prefer this.
2. `aria-hidden="true"` — only valid when the parent already has an
   accessible name (e.g., an `<a>` or `<button>` with `aria-label`).

```tsx
<svg viewBox="0 0 24 24">
  <title>Close</title>
  <path d="…" />
</svg>
```

Biome's `noSvgWithoutTitle` rule is finicky: if the SVG is written on
a single line with the `<title>` inline, the rule may still fire. Break
the SVG across lines with `<title>` as the first child.

## Labels — always link to a control

Two valid patterns:

```tsx
// 1. htmlFor + id (preferred for layout flexibility)
<label htmlFor="email">Email</label>
<input id="email" type="email" />

// 2. Wrapping
<label>
  Email
  <input type="email" />
</label>
```

For reusable form components, generate the id via `useId()`:

```tsx
function FormField({ label, value, onChange }: Props) {
  const id = useId()
  return (
    <>
      <label htmlFor={id}>{label}</label>
      <input id={id} value={value} onChange={(e) => onChange(e.target.value)} />
    </>
  )
}
```

In shadcn-heavy files, prefer the `Field` + `FieldLabel` pattern from
the shadcn skill's `forms.md` — it handles the association for you.

## Click-handler on non-button elements — make it a `<button>`

If a `<div>` or `<span>` has `onClick`, the default move is to convert
it to a `<button type="button">`. Exceptions (modal backdrop, table row
with keyboard navigation through cell content, card-level enhancement
where primary interaction is inside) must be documented with an inline
`// biome-ignore` comment explaining why.

## Groups of controls — `<fieldset>` + `<legend>`

Radio groups, checkbox groups, and button-groups acting as a picker use
`<fieldset>` + `<legend>` — NOT `<div>` + `<label>`. Example:

```tsx
<fieldset>
  <legend className="block text-sm font-medium mb-2">Export Format</legend>
  <div className="flex gap-2">
    <button type="button" onClick={() => setFormat("pdf")}>PDF</button>
    <button type="button" onClick={() => setFormat("csv")}>CSV</button>
  </div>
</fieldset>
```

## List keys — never array index

`key={index}` breaks React's reconciliation on reorder or delete. Use a
stable id from the data. If the data has no unique id, build a composite
key from unique fields (e.g., `` `${item.type}-${item.imageId}` ``).

## Focus order is DOM order — never `tabIndex` to reorder

**Tab order follows the DOM. When it feels wrong, the markup is wrong — move the
element, don't renumber it.**

The recurring case: a "Forgot password?" link placed in the password label row,
which puts it BETWEEN the two credential fields in the tab sequence. Same shape
for a "clear" link above a search box, or a helper link beside a field's label.

**Decide the tab order first, then put the markup in that order and let the
layout follow.** On a sign-in form the order people want is
`email → password → submit → recovery`: the credentials and the action they feed
are not interrupted, and the uncommon path comes last.

```tsx
// ❌ Link sits in the label row, so it is before the input in the DOM
<div className="flex items-baseline justify-between">
  <Label htmlFor="password">Password</Label>
  <Link to="/forgot-password">Forgot password?</Link>
</div>
<Input id="password" type="password" />
<Button type="submit">Sign in</Button>

// ✅ Markup in the order it should be tabbed
<Label htmlFor="password">Password</Label>
<Input id="password" type="password" />
<Button type="submit">Sign in</Button>
<Link to="/forgot-password" className="self-center">Forgot password?</Link>
```

**Reach for CSS placement only when the visual position is genuinely
non-negotiable** — a two-column grid can hold an element in a label row while it
sits later in the DOM (`col-start-2 row-start-1` on the link, input spanning row
2). Prefer moving it: an absolute offset that pins an element to a row it is not
in shifts the moment a conditional error message renders above it.

**Both shortcuts are worse than the problem:**

- **`tabIndex={-1}` to skip it.** Removes the element from the keyboard path
  entirely. On the canonical example that strips the recovery link from the one
  user who cannot get past the password field.
- **A positive `tabIndex`.** Creates a SECOND tab sequence that runs ahead of
  every element on the page, so the first Tab from the address bar lands on
  whatever carries `tabIndex={1}`. It also breaks silently the moment anyone
  adds a field without renumbering. Treat any positive value as a defect —
  Biome's `a11y/noPositiveTabindex` catches it.

`tabIndex={0}` (put a non-interactive element in the natural order) and
`tabIndex={-1}` (make something focusable only programmatically, e.g. a heading
to move focus to after navigation) are both fine. It is *reordering* that is not.

## Never `autoFocus`

`autoFocus` hijacks screen-reader focus on page load with no warning.
Use `ref.current?.focus()` gated on user intent (click, submit, etc.).

## Types over `any`

`any` disables type checking AND the a11y rules that depend on inferred
element types. Use `unknown` + narrowing, or declare a proper type.
`catch (error: unknown)` then `error instanceof Error ? error.message : "…"`
is the standard pattern for error handlers.

## Suppression of last resort

When a rule genuinely doesn't apply to your site, suppress inline with
a written justification:

```tsx
// biome-ignore lint/a11y/useKeyWithClickEvents: <specific reason; not "FP">
```

Biome's inline suppression only applies to the IMMEDIATELY next line,
so the comment must be adjacent to the flagged code. Do NOT stack it
with other directive comments (`// nosemgrep`, etc.) between it and
the code — it will silently break.

## Reference

Biome rules enforcing this file's contents (all at `error` severity via
`"recommended": true` in `biome.json`):

- `a11y/useButtonType`
- `a11y/noSvgWithoutTitle`
- `a11y/noLabelWithoutControl`
- `a11y/useKeyWithClickEvents`
- `a11y/noStaticElementInteractions`
- `a11y/noAutofocus`
- `a11y/noPositiveTabindex`
- `suspicious/noArrayIndexKey`
- `suspicious/noExplicitAny`
