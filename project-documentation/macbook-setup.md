# MacBook Setup

Everything a new developer installs on a fresh Apple Silicon MacBook to work in a
kit-enabled project, in the order it should be done.

Companion to `developer-onboarding.md`, which covers the per-project setup once the
machine itself is ready. This file stops at "the machine is ready".

**Read the whole ordering section before starting.** Steps 1–4 must be done in order and
by hand. From step 5 onward, Claude Code can do most of the work for you.

---

## The order, and where Claude takes over

| Steps | What | Who |
|---|---|---|
| 1–4 | Xcode CLT → Homebrew → shell → Claude Code | **You, by hand.** Nothing else works until Homebrew exists, and Claude Code cannot install itself. |
| 5–13 | Everything else | **Claude Code, driven by you.** Open a terminal, run `claude`, and paste the step you want. |

Once step 4 is done you can hand Claude the rest of this file and say *"work through the
remaining steps with me."* It can run every `brew install`, edit `~/.zshrc`, verify
versions and tell you what failed. It cannot click through GUI installers, sign you into
accounts, or configure a virtual machine's settings panel — those are called out below.

---

## 1. Xcode Command Line Tools

Homebrew needs them, and the kit's launcher compiles a small Swift binary, so this is
genuinely first.

```bash
xcode-select --install
```

Accept the dialog and wait. Verify:

```bash
xcode-select -p          # prints a developer dir
swiftc --version         # the launcher in step 12 needs this
```

The full Xcode app is not required.

## 2. Homebrew

The package manager everything else installs through.

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

<https://brew.sh>

On Apple Silicon it installs to `/opt/homebrew`. The installer prints two lines to add to
your shell profile — you can skip them, because step 3 sets this up properly.

## 3. Shell (`~/.zshrc`)

Copy the parts you need from **`zshrc.example`** in this directory. Read its comments; they
explain each block.

The two that matter most:

- **`eval "$(/opt/homebrew/bin/brew shellenv)"` first in the file.** Without it macOS only
  adds Homebrew via `path_helper`, which runs for login shells only and appends *last* — so
  Homebrew tools lose to Apple's older copies, and vanish entirely in a non-login shell,
  which is where hooks and scripts run.
- **Secrets in `~/.zshrc.secrets` at chmod 600**, sourced from `~/.zshrc`. Keeps the rc safe
  to paste, diff and back up.

```bash
umask 077 && touch ~/.zshrc.secrets && chmod 600 ~/.zshrc.secrets
```

Open a new terminal, then check: `which brew` should print `/opt/homebrew/bin/brew`.

## 4. Claude Code

The CLI this whole toolchain is built around.

```bash
brew install --cask claude-code
```

<https://code.claude.com/docs> · Run `claude` and sign in when prompted.

**From here, Claude can drive the rest.** `cd` to any directory, run `claude`, and paste the
steps you want done.

---

## 5. Core command-line tools

```bash
brew install git gh node@24 jq ripgrep shellcheck uv pipx libpq
brew link --overwrite node@24
```

| Tool | Why |
|---|---|
| `git` | Homebrew's is newer than Apple's. |
| `gh` | The gitflow commands use it for every PR, issue and review operation. Run `gh auth login` after installing. |
| `node@24` | **Install the versioned formula, never bare `brew install node`** — that tracks the latest Current release and moves you off LTS at the next cut. Confirm the Active LTS major from <https://raw.githubusercontent.com/nodejs/Release/main/schedule.json> before installing; a major is Active LTS when its `lts` date has passed and `maintenance` has not. |
| `jq` | Every kit hook parses its input with it. Non-negotiable. |
| `ripgrep` | Backs the editor's and Claude's text search. |
| `shellcheck` | Required before committing any shell change. |
| `uv`, `pipx` | Python tooling. Homebrew's Python is externally managed, so `pip install` outside a venv fails by design — use `pipx` for standalone CLI tools and `uv` for project environments. |
| `libpq` | `psql` and `pg_dump` for Postgres, without installing a local server. |

Python itself comes with Homebrew as a dependency; you should not need to install or manage
it directly.

Verify:

```bash
git --version && gh --version && node -v && npm -v && jq --version && shellcheck --version
```

## 6. iTerm2

The terminal Claude Code runs in. The kit's `/dev` command opens a new iTerm tab per dev
server and titles it, driven by `osascript` — this is not optional if you want `/dev` to work.

```bash
brew install --cask iterm2
```

<https://iterm2.com>

Make it your default terminal and enable **iTerm2 → Install Shell Integration** from the
menu; it is what makes tab titles and marks behave.

### The two dynamic profiles

The kit ships both — you never build one by hand — but they install differently, and
missing the second is a silent papercut rather than an error.

| Profile | Ships at | Installed by | `Allow Title Setting` |
|---|---|---|---|
| **CPL** | `_cpl/iterm2/CPL.json` | `sync-cpl.sh`, automatically (step 12) | `false` |
| **DevServer** | a project's `.claude/skills/dev-server/templates/DevServer.json` | **you, once per machine** | `true` |

Both inherit from your Default profile, so your own font and colours carry over.

They differ on purpose. `/dev` sets each tab's title with an escape sequence, which needs
`Allow Title Setting = true`. Your everyday profile keeps it `false`, because Claude Code
emits an OSC-0 title probe at startup to measure terminal width, and with titles settable
that probe overwrites the tab name.

Install the DevServer one from inside any kit-enabled project:

```bash
mkdir -p "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
cp .claude/skills/dev-server/templates/DevServer.json \
   "$HOME/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json"
```

iTerm hot-loads dynamic profiles, so no restart. Skip it and `/dev` tabs fall back to your
default profile and show the working directory instead of `<app> @ <project> (:<port>)`.

## 7. Zed

The editor.

```bash
brew install --cask zed@preview
```

<https://zed.dev> — the `@preview` channel is the one the team runs.

Set it as the shell's editor in `~/.zshrc`, which `zshrc.example` already shows:

```bash
export EDITOR="zed --wait"
```

`--wait` is load-bearing: git and `gh` open the editor for commit and PR messages, and a
non-blocking editor silently submits an empty one.

## 8. Docker

```bash
brew install --cask docker-desktop
```

<https://docs.docker.com/desktop/> — launch Docker Desktop once to finish setup, then
`docker --version`.

## 9. AWS CLI

Not a Homebrew formula — use the official installer, which keeps itself current.

```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "/tmp/AWSCLIV2.pkg"
sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
aws --version
```

<https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html>

Sign in with `aws login --profile <name>` — a browser console sign-in that manages temporary
credentials, one profile per AWS account, named for the account rather than the project.
Never create a profile from static access keys. A project records the profile, region and
account id it expects in its own `.claude/sync-substitutions.json`.

## 10. GUI applications

```bash
brew install --cask tableplus cleanshot coteditor
```

| App | What it is for |
|---|---|
| **TablePlus** <https://tableplus.com> | One GUI for every SQL database — Postgres, SQL Server, MySQL, SQLite. The SQL Server Management Studio replacement on macOS. |
| **CleanShot X** <https://cleanshot.com> | Screenshot and screen-recording tool. Its real value here is capture-to-clipboard: you will paste screenshots into Claude constantly when converting screens or debugging UI, and the built-in macOS tool makes that a multi-step chore. Expect to use it dozens of times a day. |
| **CotEditor** <https://coteditor.com> | The Notepad++ replacement. A plain-text scratchpad whose *unsaved* documents survive a reboot, which is what makes it useful for working notes you never intend to name or file. |

Both TablePlus and CleanShot are commercial with trials; buy licences before the trial ends.

### Tailscale — optional

```bash
brew install --cask tailscale-app
```

<https://tailscale.com> — a private mesh network. Useful when a project's development
database or server sits on a machine that is not on your network: Tailscale puts it on an
address you can reach directly, so no VPN client, port forwarding or jump host is needed.
Install it when a project tells you to; skip it otherwise.

## 11. Parallels Desktop — for legacy WINDEV work

Only needed on a project converting a legacy **WINDEV / WEBDEV** (PC SOFT) application.
Skip it otherwise.

```bash
brew install --cask parallels
```

<https://www.parallels.com/products/desktop/> — commercial, subscription.

Install Windows 11 through Parallels' own assistant, which downloads and configures it. Then
install **Parallels Tools** inside the guest when prompted; the folder sharing below depends
on it.

### VM settings

Open **Actions → Configure**. Reference configuration on an M-series MacBook Pro:

| Setting | Value | Where |
|---|---|---|
| Processors | **6** | Hardware → CPU & Memory → Manual |
| Memory | **6144 MB** | Hardware → CPU & Memory → Manual |
| Graphics | **Highest** 3D acceleration, automatic video memory | Hardware → Graphics |
| Disk | **256 GB**, expanding | Hardware → Hard Disk |

Manual rather than automatic: WINDEV is a heavy IDE, and letting Parallels rebalance under
it produces stalls that look like the IDE hanging. Six cores and 6 GB leaves the host
comfortable on a 14" machine — raise the memory if the host has 32 GB or more.

### The sharing setting that matters

**Configure → Options → Sharing → Share Windows → "Access Windows folders from Mac".**

Turn it on. This mounts the guest's drives under `/Volumes` on the Mac, at a path of the form:

```
/Volumes/[C] Windows 11.hidden/
```

**This is what makes legacy conversion work.** The WINDEV project on the Windows disk becomes
a normal macOS path, so `grep`, `rg` and Claude's own file tools read the live source at full
speed — the same working copy the IDE has open, including changes not yet committed. There is
no Mac-side clone and you should not create one; a clone raises a "is my mirror stale?"
question that the mount simply does not have.

While you are in that panel, also confirm **Share Mac → Share folders: Home directory**, and
under **Options → Sharing → Shared clipboard**, that clipboard sharing is on.

Working notes for conversion sessions:

- **The mount exists only while the VM is running.** Stopping the VM suspends it and the
  volume disappears. If the path does not resolve, run `ls /Volumes` first — Parallels names
  the volume from the VM and disk, so one command settles what it is actually called. Quote
  the path; it contains spaces and brackets.
- **Read-only.** WINDEV owns those files' structure, including encoded property blobs. A
  plain-text edit corrupts the project. Report a legacy defect with `file:line` and stop.
- **Reading while the IDE is open is safe.** Writing is not.
- **Search case-insensitively, always.** WLanguage is case-insensitive, so the same
  identifier is spelled differently in different places — in code and in filenames. Use
  `grep -rn -i` and `-iname`, and treat a zero-hit result on a name you know exists as a
  spelling variant rather than as absence.

To run a command inside the guest from the Mac:

```bash
prlctl exec "<vm name>" --current-user cmd.exe /c "<command>"
```

`--current-user` is load-bearing. Without it the command runs as `NT AUTHORITY\SYSTEM`, which
git rejects as dubious ownership and which leaves SYSTEM-owned files behind. Close the IDE
before any git write — it holds locks.

## 12. Launcher and statusline — from the kit

Both ship in the kit repo, so clone it somewhere permanent first. Run these from inside it.

### The project launcher (CPL)

A Spotlight-launchable app that opens Claude Code in managed, display-aware iTerm2 windows.

```bash
./_cpl/sync-cpl.sh
```

It installs helper scripts to `~/bin`, builds `CPL.app` into `~/Applications`, and drops its
iTerm2 dynamic profile into `~/Library/Application Support/iTerm2/DynamicProfiles/` — this is
the iTerm2 profile referenced in step 6, and where `swiftc` from step 1 is used. Afterwards
`CPL` launches from Spotlight.

Run it again any time to update; it reinstalls only when the kit's version differs from the
installed one.

### The statusline

Replaces Claude Code's default status line with one showing directory, branch, version and
model on the first line, and context usage, cost, duration and lines changed on the second.
Context headroom in particular is worth having in front of you.

```bash
/install-statusline
```

Run from inside the kit repo, in a Claude Code session. It copies `_statusline/statusline.sh`
to `~/.claude/statusline.sh` and makes it executable, skipping the copy when the two already
match. Re-run it after pulling the kit to pick up changes.

## 13. Exa API key — optional

Exa powers one tier of the `research` skill: non-English and primary or institutional
sources, and conceptual research with no single documentation page to find. **Documentation
lookup itself needs no key** — it runs on built-in tools.

If you want it: sign up at <https://exa.ai>, create an API key, and add it to your secrets
file.

```bash
echo 'export EXA_API_KEY="..."' >> ~/.zshrc.secrets
```

The free tier covers normal use. Keys are per developer; never share one.

---

## Then: the kit itself

The machine is ready. `developer-onboarding.md` in this directory covers what comes next —
installing the kit's global commands, pointing at the kit path, and syncing a project's
`.claude/` from it.

## Verification

Run this in a **new** terminal. Every line should print a version.

```bash
for c in brew git gh node npm jq rg shellcheck uv pipx psql aws docker claude; do
  printf '%-12s %s\n' "$c" "$(command -v $c || echo 'MISSING')"
done
echo "EDITOR=$EDITOR"
echo "secrets file: $(ls -l ~/.zshrc.secrets 2>/dev/null | awk '{print $1}' || echo 'not created')"
```

`psql` should resolve from Homebrew, and the secrets file should read `-rw-------`.
