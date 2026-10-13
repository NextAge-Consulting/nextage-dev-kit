# Custom themes

Read when asked to add or change a user theme setting: an accent colour, a colour-blind mode, a text size, letter or word spacing.

The design system has two themes, light and dark. A user setting is an app-level override on top of them, and Claude Design shows light and dark only.

## Build a setting this way

**Put every setting in one theme file**, imported after the token stylesheet, each switched by an attribute on `<html>`:

```css
html[data-accent="green"]                    { --primary: #1f8a4c; }
html[data-theme="dark"][data-accent="green"] { --primary: #4cc27f; }
```

**Never name the theme file in `DESIGN_TOKEN_FILES`, `DESIGN_TYPE_FILE` or `DESIGN_STYLES_FILE`.** The token stylesheet holds the light block and the dark block only.

**Override only tokens the token stylesheet declares**, and give every colour you override a dark line for the same setting, even when the value is equal.

**Change sizes and spacing through plain variables the text styles read**: `--step-*` for text sizes, `--tracking-*` for letter spacing, `--word-spacing-*` for word spacing. The token stylesheet holds plain values such as `--step-12: 12px`. Name tracking tokens for their use (`--tracking-caps`), never a size word. Give each choice its own list, in whole pixels:

```css
html[data-font-size="large"] { --step-12: 14px; --step-14: 16px; }
```

A project whose text sizes are in `rem` changes the root font size instead, one line per choice. Ask which method the project uses when it is not already settled.

**A free colour picker writes one variable on `<html>`**, `--accent-base`, from JS. The theme file derives the shades from it with `color-mix()`, with a light and a dark rule.

**Apply the saved choices before the page first draws**: a small script in `<head>` sets the attributes, and `--accent-base`, before the stylesheet renders.

**Leave screen code alone.** A screen built from the text styles and colour tokens follows every setting. The settings panel is a screen like any other.

## Check it

Run `node .claude/skills/design-system/scripts/check-theme-file.mjs <theme file>` after each change. It names every variable that is not a token and every colour missing its dark line.
