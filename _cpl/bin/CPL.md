# CPL Launcher System (v2)

Spotlight-launchable app for opening Claude Code / Terminal / custom commands in managed iTerm2 windows, with display-aware placement that adapts automatically to whatever monitors are currently attached.

## Source of Truth

CPL source lives in `_cpl/` within the [claude-project-starter-kit](https://github.com/petehalsted/claude-project-starter-kit) repo. All changes are made there and synced via `sync-cpl.sh`.

```bash
./_cpl/sync-cpl.sh          # from the kit repo
/sync-cpl                   # from any project (Claude Code slash command)
./_cpl/sync-cpl.sh --force  # non-interactive
```

Version: `_cpl/VERSION` (repo) vs `~/.cpl-version` (installed). Sync installs only when they differ.

## Architecture

CPL splits into a **brain** and a **dumb executor**:

- **`cpl-picker` (Swift/AppKit) — the brain.** Loads `~/.cpl.json`, fingerprints the current display layout, resolves the active profile, renders the launch panel, and on an action click resolves placement → computes iTerm window bounds → claims a slot → emits a fully-resolved launch spec on stdout. Also hosts the config panel.
- **`CPL.app` (AppleScript) — the executor.** Runs the picker, parses the spec, handles the iTerm cold-launch dance, opens the window. No config parsing or geometry math.

Picker stdout contract (single tab-separated line):

```
L \t T \t R \t B \t itermProfile \t sessionName \t command
```

Non-zero picker exit (Cancel or config-save) → no output → CPL.app aborts cleanly.

## Components

| Source File | Installs To | Method |
|-------------|-------------|--------|
| `_cpl/bin/cpl-app.applescript` | `~/Applications/CPL.app` | `osacompile` |
| `_cpl/bin/cpl-picker.swift` | `~/bin/cpl-picker` | `swiftc -O` |
| `_cpl/bin/cpl-launch` | `~/bin/cpl-launch` | `cp` + `chmod +x` |
| `_cpl/bin/cpl-slot` | `~/bin/cpl-slot` | `cp` + `chmod +x` |
| `_cpl/bin/cpl-cleanup` | `~/bin/cpl-cleanup` | `cp` + `chmod +x` |
| `_cpl/bin/cpl` | `~/bin/cpl` | `cp` + `chmod +x` |
| `_cpl/bin/CPL.md` | `~/bin/CPL.md` | `cp` |
| `_cpl/iterm2/CPL.json` | `~/Library/Application Support/iTerm2/DynamicProfiles/` | `cp` |
| `_cpl/icon/CPL.icns` | `~/Applications/CPL.app/Contents/Resources/applet.icns` | `cp` (replaces default applet icon) |

The icon is a CPL wordmark; `_cpl/icon/make-icon.swift` regenerates the iconset/`.icns` if the design changes.

## Config — `~/.cpl.json`

Auto-created by `cpl-picker` on first launch (detects displays, fingerprints the layout, migrates `maxSlots` from any legacy `~/.cpl.conf`). Three layers; actions and pins are profile-agnostic, only display geometry varies per profile.

### Actions (global)

Every launch button is one entry. The five defaults:

| id | command | dir | iTerm profile |
|----|---------|-----|---------------|
| `claude` | claude | selected-project | CPL |
| `terminal` | terminal | selected-project | Default |
| `agents` | claude | projects-dir | CPL |
| `term-projects` | terminal | projects-dir | Default |

Custom commands (e.g. SSH) are added via the config panel — `command: "shell"`, `shell: "ssh box"`, `dir: "none"`.

| Field | Values |
|-------|--------|
| `command` | `claude` · `terminal` · `shell` (with `shell:` string) |
| `dir` | `selected-project` (uses the dropdown) · `projects-dir` · `none` · absolute path |
| `placement` | default placement (see below) |
| `onMissing` | `clamp` (default) · `prompt` |

Only `dir: selected-project` actions consume the project dropdown.

### Placement

`{ monitor, slotMode, slot?, width }`:

- `slotMode`: `slotted` (partial-width, full-height — claims a slot) · `fullscreen` (whole monitor, no slot)
- `slot`: optional fixed slot (pin)
- `width`: reserved; `> 1` (span multiple slots) is **not yet implemented** — defaults to 1

### Profiles (display-only)

Keyed by a display **fingerprint** = translation-normalized set of monitor rects (resolution + relative offset). Same layout = same profile (two ultrawides at home == at work); different layout = different profile (side-by-side ≠ stacked). Each profile holds:

- `monitors`: per-monitor `maxSlots`
- `overrides`: sparse per-action placement patches for this setup

### Pins (global)

`{ project → {monitor, slot} }` — e.g. project `xyz` always monitor 1, slot 2. Edited via the config panel's "Edit raw JSON".

## Placement resolution

For the chosen action, first candidate valid against the active profile's monitors wins:

1. per-project pin (selected-project actions only)
2. active-profile override for the action
3. action default placement
4. fallback — `clamp` (remap missing monitor N → highest existing ≤ N, e.g. mon2 → mon1, preserving slotMode) or `prompt`

`slotMode` never remaps — only the target monitor does.

## Display detection & seeding

On launch the picker fingerprints `NSScreen.screens` and matches a profile. **Unknown layout → seed and offer (never block):** auto-creates a profile (monitors numbered by X-then-Y; `maxSlots` seeded via `floor(width / 1150)`, min 1), runs immediately with action defaults, and the launch panel shows a "new layout detected — configure?" note. Plug in any setup and CPL adapts without reconfiguration.

## Monitor numbering & coordinates

- **Numbering**: screens sorted by **X ascending, then Y descending** (leftmost, ties topmost). Monitor N = the N-th in that order. No hardware identity needed.
- **Coordinates**: `NSScreen.frame` is bottom-left origin; iTerm AppleScript bounds are top-left. The picker flips Y around the primary screen height, so multi-monitor vertical placement (stacked / offset) is handled correctly.

## Slots

- **Files**: `~/.cpl-slots/mon<M>-<N>` — line 1 = session name, line 2 = owning PID.
- **maxSlots is per-monitor**, supplied to `cpl-slot` by the picker from the active profile. `cpl-slot` holds no config knowledge.
- **Claim**: first empty slot 1..maxSlots; stale (dead PID) and orphan (index > maxSlots) files cleaned on claim. At full capacity, cycles back to slot 1 (overwrite); ownership-checked release protects the new occupant.
- **Layout within a monitor**: equal-width slots, full monitor height, right-to-left (slot 1 = rightmost).
- **Fullscreen actions** claim no slot.

```bash
~/bin/cpl-slot status   # list claimed slots across all monitors
~/bin/cpl-slot clean    # clear all slot files
```

## UI

### Launch panel

Project dropdown, then one-click action buttons (project-bound actions first, a separator, then fixed-dir / custom actions), then `⚙ Config` / `Cancel`. Each button launches immediately — no mode toggle. The dropdown feeds only project-bound actions.

### Config panel (⚙)

- **Projects dir** — the root scanned for the project dropdown and resolved for `projects-dir` actions (default `~/projects`)
- Per-monitor `maxSlots` for the active profile
- Per-action placement override (monitor + slotMode) for the active profile
- **Identify Monitors** — flashes each display's CPL number + resolution on-screen for ~2.5s, so you can map numbering (X-then-Y) to physical screens
- "Add custom command…" (label + shell)
- "Edit raw JSON" — opens `~/.cpl.json` in the default text editor (pins / advanced)
- Save writes config and exits (re-launch CPL to act on it)

## Required macOS Permissions

Automation (System Settings > Privacy & Security > Automation): allow `osascript` / Script Editor to control **iTerm**. Prompted on first use.

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Not authorized to send Apple events" | Automation denied | Enable for iTerm |
| Window at wrong position | Profile geometry doesn't match displays | Open ⚙ Config and adjust, or delete `~/.cpl.json` to re-seed |
| Picker won't open / JSON error dialog | Malformed `~/.cpl.json` | Fix via "Edit raw JSON", or delete the file to regenerate |
| Cold launch opens an extra empty iTerm window | iTerm pref race | Auto-handled; file an issue if reproducible |

## Migration from v1.x

v2.0.0 is a clean break (no compatibility layer):

- **Config**: flat `~/.cpl.conf` → structured `~/.cpl.json`. First launch migrates `maxSlots` and seeds a profile for the current layout. Delete `~/.cpl.conf` afterward.
- **Slot files**: flat `~/.cpl-slots/<N>` → `mon<M>-<N>`. `sync-cpl.sh` removes the legacy flat files.
- **Picker**: NSAlert (dropdown + radio + Launch) → NSPanel with one-click actions + config panel.
- **Geometry**: moved out of AppleScript into the Swift picker.

## Key Design Decisions

### iTerm Cold Launch

iTerm creates a default window on cold launch. CPL.app sets `OpenNoWindowsAtStartup = true` via `defaults write` **before** `activate`, waits for responsiveness, restores the pref, and closes any stray startup windows. Ordering matters — iTerm reads prefs during launch.

### Window Title

Claude Code emits escape sequences that override iTerm tab titles. The CPL profile sets `Title Components: 1`, `Allow Title Setting: false`.

### Brain/executor split

All config and geometry logic lives in `cpl-picker` (Swift). This removed the previous duplication where both the AppleScript (`readConf`) and `cpl-slot` parsed config independently. One resolver, one executor.
