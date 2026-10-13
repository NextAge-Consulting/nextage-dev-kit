# Custom Themes

For anyone adding user theme settings to a kit project: accent colours, a colour-blind mode, text size or letter spacing. Read it to understand how they work. To start, hand it to Claude and say *"I want to support custom themes in this project — read this, analyse the project and recommend"*.

## What the kit supports

**The kit's design system has two themes: light and dark.** They live in the project's token stylesheet. The kit checks them and publishes them to Claude Design, every colour exactly as the browser computes it, `color-mix()` formulas included.

Values the token stylesheet holds but Claude Design should not show, such as raw palette colours or the sizes the text styles use, sit between two comments:

```css
/* publish: off — raw palette */
--ink: #172321;
--blue: #1b6fe8;
/* publish: on */
```

Everything else a user can change is a setting in the running app, built on top of light and dark. Accent colour, colour-blind mode, text size, letter spacing and word spacing are all settings. Settings exist only in the app. Claude Design shows light and dark.

## How a setting works

A setting is ordinary CSS overriding. The app's colours and sizes are already CSS variables. A theme file redefines some of them when an attribute is set on `<html>`:

```css
/* themes.css */
html[data-accent="green"]                    { --primary: #1f8a4c; }
html[data-theme="dark"][data-accent="green"] { --primary: #4cc27f; }
```

The settings screen sets `data-accent="green"` on `<html>` and saves the choice. Every button that uses `--primary` turns green. No screen code changes, because screens already use the variables.

## The requirements

1. **Every setting lives in one theme file,** for example `themes.css`, imported after the token stylesheet. Each setting is an attribute on `<html>`: `data-accent`, `data-colorblind`, `data-font-size`, `data-letter-spacing`.

2. **The theme file stays out of the kit's checker settings.** The kit's design-token checker reads only the stylesheets named in three kit settings in `.claude/sync-substitutions.json`: `DESIGN_TOKEN_FILES`, `DESIGN_TYPE_FILE` and `DESIGN_STYLES_FILE`. The theme file is never added to them. The token stylesheet holds the light block and the dark block, and nothing else.

3. **Every colour a setting changes gets a light and a dark value,** even when the two are the same:

   ```css
   html[data-colorblind="protanopia"]                    { --status-danger: #d97a00; }
   html[data-theme="dark"][data-colorblind="protanopia"] { --status-danger: #f0a040; }
   ```

4. **Sizes and spacing come from a short list of plain variables.** A setting can only change what a variable controls. So text styles take their size from `--step-*` variables, their letter spacing from `--tracking-*` and their word spacing from `--word-spacing-*`. The token stylesheet holds plain values such as `--step-12: 12px`, never formulas. This applies only to a project that offers the setting.

   ```css
   /* tokens.css */
   --step-12: 12px;
   --step-14: 14px;

   /* type.css */
   .type-label { font-size: var(--step-12); }
   .type-body  { font-size: var(--step-14); }
   ```

5. **Pick one text-size method when the project starts:**
   - **Text sizes in `rem`.** The setting changes the root font size, one line per choice: `html[data-font-size="large"] { font-size: 112.5%; }`. Spacing and control heights scale with the text, the way browser zoom does.
   - **A list per choice.** The theme file restates each `--step-*` for each choice. Only the text grows; spacing stays put.

     ```css
     html[data-font-size="large"] { --step-12: 14px; --step-14: 16px; }
     ```

   Each choice's sizes are whole pixels, rounded by whoever writes them.

6. **A free colour picker writes one variable,** the chosen colour, on `<html>`. The theme file works out the shades from it:

   ```js
   document.documentElement.style.setProperty('--accent-base', picked)
   ```

   ```css
   html[data-accent="custom"]                    { --primary: var(--accent-base); }
   html[data-theme="dark"][data-accent="custom"] { --primary: color-mix(in oklab, var(--accent-base), white 25%); }
   ```

   How the picker looks and works is up to the app.

7. **Settings are applied before the page first draws.** A small script in `<head>` reads the saved choices and sets the attributes, and the picker's variable, before the stylesheet renders. Without it, every page load flashes the default colours.

## Check it

Run the kit's theme-file check after each change:

```bash
node .claude/skills/design-system/scripts/check-theme-file.mjs src/styles/themes.css
```

It names every variable the theme file sets that is not in the token stylesheet, and every colour missing its dark value. It is a command you run when you choose, never a gate.

## What your screens need

Nothing new. A screen that already uses the app's text styles and colour variables follows every setting by itself. The settings panel is one more screen, built from the app's components like any other.

## For Claude: analyse and recommend

When handed this document with a request to support custom themes, analyse the project and recommend. Change nothing until the human agrees.

1. **Read what exists:**
   - the token, type and styles stylesheets the kit settings name;
   - every other stylesheet the app imports;
   - the settings screen, if there is one;
   - any script in `<head>`;
   - the design-system config.
2. **Ask what the human wants to offer,** if they haven't said: which settings, which choices each has, and whether there is a free colour picker.
3. **Measure the project against each requirement above,** one line each: fits as it is, fits with changes (name the changes), or not covered (say what is missing).
4. **Flag anything in the token stylesheet** other than the light block and the dark block. A theme block there moves to the theme file.
5. **Recommend the text-size method,** with what each would change in this project.
6. **List the work in order,** as small steps, each one leaving the app working, and finish with the theme-file check passing.
