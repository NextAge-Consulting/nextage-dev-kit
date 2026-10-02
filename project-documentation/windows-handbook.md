# Windows

For a developer working in a kit-enabled project on Windows: what the machine needs
before the kit's hooks can run, and why. Read it once, before your first session; then
`developer-handbook.md` is your guide like everyone else's.

## Why Windows needs setup

The kit's hooks are bash scripts that read Claude Code's tool calls with `jq` and
`python3`. **A hook that cannot run those tools refuses every action it guards** rather
than letting it through unchecked, so on a machine without them Claude can barely edit a
file. Each step below exists to make those three things — bash, `jq`, `python3` — work in
the shell Claude Code starts its hooks in.

## 1. Git for Windows

Install Git for Windows (`winget install Git.Git`). It brings Git Bash, which Claude Code
uses on Windows to run every command and hook. Work from Git Bash.

## 2. jq 1.7 or later

```bash
winget install jqlang.jq
```

On Windows `jq` writes Windows line endings unless told otherwise; the hooks run it in
its `--binary` mode, which needs jq 1.7 or later. An older `jq` is reported as missing.

## 3. A real Python answering `python3`

Windows ships a `python3` that only prints a pointer to the Microsoft Store, and the
python.org installer creates `python.exe` but no `python3.exe`. The hooks call
`python3`, so both need fixing:

1. Install Python: `winget install Python.Python.3.12` (any current 3.x works). Let it
   add Python to `PATH`.
2. Turn off the Store stubs: **Settings → Apps → Advanced app settings → App execution
   aliases**, and switch off **App Installer — python.exe** and **App Installer —
   python3.exe**. Git Bash cannot run those alias files at all, so leaving them on
   shadows the real Python.
3. Give the installed Python a `python3` name, in a new Git Bash window:

   ```bash
   cd "$(dirname "$(command -v python)")" && cp python.exe python3.exe
   python3 -c 'print(1)'    # prints 1
   ```

   The copy sits beside `python.exe`, so it is on `PATH` everywhere, including the
   shell hooks run in. It runs the same interpreter. A new minor version installs to a
   new folder; repeat the copy there.

## 4. Restart Claude Code

Hooks run with the `PATH` Claude Code started with. After installing anything above,
quit Claude Code and start it again from a new Git Bash window, or it keeps reporting
the tool as missing.

## What the session-start check tells you

The first hook of every session checks this machine and stays silent when everything
works. Otherwise it shows a warning at the top of the session, and Claude repeats it in
its first reply:

- **A tool is missing or does not run** — named, with its install line and a reminder to
  restart. Until it is fixed, every guard that needs it refuses the actions it covers.
- **The commit gate cannot typecheck** — no `check-types` script in `package.json`, or a
  `pyproject.toml` or `pyrightconfig.json` with neither pyright nor mypy installed. `/commit` and `/ship-main`
  fail until it is fixed.
- **Line endings** — see below.

## Line endings

Every kit-enabled project's `.gitattributes` keeps text files on LF line endings in the
working tree, whatever Git's `core.autocrlf` says. A checkout made before that file
arrived can still have CRLF copies on disk. The session-start check fixes that by itself,
once each time `.gitattributes` changes: every file whose only difference from Git's copy
is CRLF is rewritten from Git. A CRLF file you have really edited is listed and left
alone. Once that edit is committed, `git checkout -- <file>` in your own terminal
rewrites the file with LF.

## Microsoft Defender

Real-time scanning inspects every file a hook, a build or `npm` touches, and slows each
of them noticeably. Exclude the folder your projects live in:

**Windows Security → Virus & threat protection → Manage settings → Exclusions → Add or
remove exclusions → Add an exclusion → Folder**, then pick the projects folder.

Or, from an administrator PowerShell:

```powershell
Add-MpPreference -ExclusionPath "$env:USERPROFILE\projects"
```

Exclude only the folder of code you trust; downloads and everything else stay scanned.
