#!/usr/bin/env bash
set -euo pipefail

# sync-cpl.sh — All-or-nothing CPL install/update
# Source: _cpl/ in claude-project-starter-kit repo
# Target: ~/bin/, ~/Applications/, ~/Library/Application Support/iTerm2/DynamicProfiles/

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CPL_DIR="$SCRIPT_DIR"
BIN_DIR="$CPL_DIR/bin"

DEST_BIN="$HOME/bin"
DEST_APP="$HOME/Applications"
DEST_ITERM="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
VERSION_FILE="$CPL_DIR/VERSION"
INSTALLED_VERSION_FILE="$HOME/.cpl-version"

# Stable code-signing identity for CPL.app (see ensure_signing_identity). These
# values must remain CONSTANT across versions: macOS TCC binds the CPL→iTerm
# Automation grant to (bundle id + signing-cert leaf hash). Change either and
# every installed user must re-grant.
SIGN_IDENTITY_NAME="CPL Local Signing"
CPL_BUNDLE_ID="com.cpl.launcher"
# Dedicated keychain that holds ONLY CPL's local, self-signed signing cert. Kept
# separate from the login keychain so we can manage it with a known password and
# never touch the user's real credentials.
SIGN_KEYCHAIN="$HOME/Library/Keychains/cpl-signing.keychain-db"
# NOT a secret in the constitution-III sense: it guards a keychain whose only
# contents are a self-signed, machine-local code-signing cert with no value on any
# other system. A fixed local value is the standard pattern (cf. fastlane match's
# MATCH_KEYCHAIN_PASSWORD) and lets the unattended re-sign work on every sync.
SIGN_KEYCHAIN_PW="cpl-local-signing"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error() { echo -e "${RED}ERROR: $1${NC}" >&2; exit 1; }
info() { echo -e "${BLUE}$1${NC}"; }
success() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}$1${NC}"; }

# ensure_signing_identity NAME — idempotently provision a stable, per-machine,
# self-signed code-signing identity in the dedicated CPL keychain and echo its
# SHA-1 on stdout (empty + non-zero on failure). All progress goes to stderr so the
# caller can capture the hash cleanly.
#
# WHY THIS EXISTS: osacompile emits a bundle whose code hash changes on every
# rebuild (verified: ad-hoc cdhash is nondeterministic). macOS TCC binds the "CPL
# may control iTerm" Apple-events grant to the app's code identity, so each
# `sync-cpl` invalidated the grant and the user got "Not authorized to send Apple
# events to iTerm" with NO re-prompt. Signing with a STABLE cert pins TCC's
# designated requirement to (bundle id + cert leaf hash) — constant across rebuilds
# (verified: identical DR across distinct bundles) — so the grant survives forever
# after one first-launch "Allow". This is a local identity, not Gatekeeper
# distribution (a downloadable .app would need a paid Developer ID + notarization).
#
# The cert is generated locally, NEVER committed, and REUSED if already present —
# regenerating would mint a new leaf hash and re-break every installed user's grant.
#
# The recipe is order-sensitive and every step was validated empirically; the
# inline notes record why each is required (each was a distinct failure mode):
#   - keyUsage=digitalSignature is mandatory alongside extendedKeyUsage=codeSigning
#     ("Invalid Key Usage for policy" without it).
#   - p12 must use legacy PBE + a non-empty password (macOS `security import`
#     rejects modern-cipher / empty-password p12: "MAC verification failed").
#   - set-key-partition-list is the Sierra+ ACL gate; codesign can't reach the key
#     without it.
#   - add-trusted-cert (user domain, scoped to this keychain) is non-interactive
#     and required: codesign refuses an untrusted self-signed identity.
ensure_signing_identity() {
  local name="$1"
  local kc="$SIGN_KEYCHAIN" kcpw="$SIGN_KEYCHAIN_PW"
  local hash tmp

  # 1. Dedicated keychain. Create if absent; disable auto-lock so it stays usable;
  #    unlock for this run.
  if [ ! -f "$kc" ]; then
    security create-keychain -p "$kcpw" "$kc" >/dev/null 2>&1 || return 1
  fi
  security set-keychain-settings "$kc" >/dev/null 2>&1 || true
  security unlock-keychain -p "$kcpw" "$kc" >/dev/null 2>&1 || return 1

  # 2. Ensure the keychain is in the user search list — codesign needs it there to
  #    resolve the identity (verified: signing fails with "no identity found"
  #    otherwise). Rebuild the list from EXISTING keychain files only: malformed
  #    entries fail the `-f` test and are dropped (self-healing), and we never feed
  #    a readback value straight back to `-s`. This matters because macOS
  #    `security list-keychains -s` can accumulate a spurious "-db" suffix when fed
  #    its own quoted readback, eventually evicting the REAL login keychain from
  #    the search list — which silently breaks every keychain consumer (observed:
  #    it killed `gh`'s stored-token read → push/PR/merge 401).
  if ! security list-keychains -d user | grep -Fq "$kc"; then
    local kept line p
    kept=""
    while IFS= read -r line; do
      p=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
      if [ -f "$p" ] && [ "$p" != "$kc" ]; then kept="$kept $p"; fi
    done < <(security list-keychains -d user)
    # shellcheck disable=SC2086  # intentional word-split: each path is a separate arg
    security list-keychains -d user -s $kept "$kc" >/dev/null 2>&1 || true
  fi

  # 3. Reuse the identity if it already exists (the common case after first install).
  hash=$(security find-identity -p codesigning "$kc" 2>/dev/null \
    | grep -F "$name" | head -1 | awk '{print $2}') || true
  if [ -n "$hash" ]; then
    printf '%s\n' "$hash"
    return 0
  fi

  printf '  Provisioning self-signed signing identity "%s"...\n' "$name" >&2
  tmp=$(mktemp -d) || return 1
  # shellcheck disable=SC2064  # expand $tmp now so the trap removes the right dir
  trap "rm -rf '$tmp'" RETURN

  # 4. Self-signed cert. keyUsage + extendedKeyUsage BOTH required (see header).
  #    Config-file form (not -addext) for LibreSSL/OpenSSL portability.
  printf '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=%s\n[ext]\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nbasicConstraints=critical,CA:FALSE\n' \
    "$name" > "$tmp/openssl.cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -config "$tmp/openssl.cnf" >/dev/null 2>&1 || return 1

  # 5. PKCS#12 with legacy PBE + non-empty password (see header).
  openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -out "$tmp/cpl.p12" -passout pass:cpl-import >/dev/null 2>&1 || return 1

  # 6. Import into the dedicated keychain; -T authorizes codesign, -A skips the
  #    per-use access prompt.
  security import "$tmp/cpl.p12" -k "$kc" -P cpl-import -T /usr/bin/codesign -A \
    >/dev/null 2>&1 || return 1

  # 7. Partition list (Sierra+ ACL gate) and 8. code-signing trust (see header).
  #    Both best-effort: if either fails, the sign+verify gate in the caller falls
  #    back to ad-hoc and warns loudly.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kcpw" "$kc" \
    >/dev/null 2>&1 || true
  security add-trusted-cert -r trustRoot -p codeSign -k "$kc" "$tmp/cert.pem" \
    >/dev/null 2>&1 || true

  hash=$(security find-identity -p codesigning "$kc" 2>/dev/null \
    | grep -F "$name" | head -1 | awk '{print $2}') || true
  [ -n "$hash" ] || return 1
  printf '%s\n' "$hash"
}

# Parse flags
FORCE=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=true ;;
    *) error "Unknown flag: $arg" ;;
  esac
done

# Read versions
[[ -f "$VERSION_FILE" ]] || error "VERSION file not found: $VERSION_FILE"
REPO_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")

INSTALLED_VERSION=""
if [[ -f "$INSTALLED_VERSION_FILE" ]]; then
  INSTALLED_VERSION=$(tr -d '[:space:]' < "$INSTALLED_VERSION_FILE")
fi

# Compare versions
if [[ "$REPO_VERSION" == "$INSTALLED_VERSION" ]]; then
  success "CPL v${REPO_VERSION} is current. Nothing to do."
  exit 0
fi

if [[ -z "$INSTALLED_VERSION" ]]; then
  info "CPL not installed. Install v${REPO_VERSION}?"
else
  info "CPL update available: v${INSTALLED_VERSION} → v${REPO_VERSION}. Install?"
fi

# Confirm unless --force
if [[ "$FORCE" != true ]]; then
  read -r -p "Proceed? [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Cancelled."; exit 0 ;;
  esac
fi

echo ""
info "Installing CPL v${REPO_VERSION}..."
echo ""

# Kill any running CPL.app applet so the new compiled script is picked up on
# next Spotlight launch. macOS caches AppleScript bytecode in memory once the
# applet is running — without this, subsequent launches re-fire the OLD script
# against the NEW config, which silently breaks when keys change between
# versions (real failure mode observed during v1.4 → v1.5 cutover). Also kills
# any orphan cpl-picker waiting on a UI dialog.
#
# Targets are scoped to the CPL bundle path and the cpl-picker binary — does
# NOT touch cpl-launch (active Claude sessions) or unrelated processes.
APPLET_PIDS=$(pgrep -f "Applications/CPL.app/Contents/MacOS/applet" 2>/dev/null || true)
PICKER_PIDS=$(pgrep -f "${HOME}/bin/cpl-picker$" 2>/dev/null || true)
if [[ -n "$APPLET_PIDS" || -n "$PICKER_PIDS" ]]; then
  for pid in $APPLET_PIDS $PICKER_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  echo "  Stopped running CPL.app applet/picker (will reload from disk on next launch)"
fi

# Ensure target directories exist
mkdir -p "$DEST_BIN"
mkdir -p "$DEST_APP"
mkdir -p "$DEST_ITERM"

# 1. Copy bash scripts to ~/bin/ and chmod +x
BASH_SCRIPTS=(cpl cpl-launch cpl-slot cpl-cleanup)
for script in "${BASH_SCRIPTS[@]}"; do
  cp "$BIN_DIR/$script" "$DEST_BIN/$script"
  chmod +x "$DEST_BIN/$script"
  echo "  Installed $script → ~/bin/$script"
done

# 2. Copy CPL.md to ~/bin/
cp "$BIN_DIR/CPL.md" "$DEST_BIN/CPL.md"
echo "  Installed CPL.md → ~/bin/CPL.md"

# 3. Compile and install Swift binaries
echo ""
info "Compiling Swift sources..."

# cpl-picker
echo "  Compiling cpl-picker.swift..."
swiftc -O "$BIN_DIR/cpl-picker.swift" -o "$DEST_BIN/cpl-picker" 2>&1
chmod +x "$DEST_BIN/cpl-picker"
echo "  Installed cpl-picker → ~/bin/cpl-picker"

# 4. Compile AppleScript → CPL.app
echo ""
info "Compiling CPL.app..."
# Copy source to ~/bin/ for reference
cp "$BIN_DIR/cpl-app.applescript" "$DEST_BIN/cpl-app.applescript"
# Compile to .app bundle
osacompile -o "$DEST_APP/CPL.app" "$BIN_DIR/cpl-app.applescript" 2>&1
echo "  Installed CPL.app → ~/Applications/CPL.app"

APP="$DEST_APP/CPL.app"
PLIST="$APP/Contents/Info.plist"
ICON_INSTALLED=false

# ===== ALL bundle-content mutations (Info.plist, Resources) MUST happen in 4a,
# BEFORE code-signing in 4b. Signing seals Contents/; any edit afterward breaks the
# seal and re-triggers the TCC "Not authorized to send Apple events" failure. =====

# 4a-i. Stable bundle identifier. TCC keys the Automation grant on this id; pinning
# it (vs osacompile's generated default) keeps the grant stable and makes future
# scoped `tccutil reset AppleEvents com.cpl.launcher` possible.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $CPL_BUNDLE_ID" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $CPL_BUNDLE_ID" "$PLIST"

# 4a-ii. Install the CPL wordmark icon. osacompile regenerates a default applet.icns
# (CFBundleIconFile=applet) on every run; macOS aggressively caches icons keyed on
# the bundle + resource name, so simply overwriting applet.icns leaves the stale
# cached icon showing. Instead install under a NEW name (CPL.icns), repoint
# CFBundleIconFile, and remove the default — the changed resource name forces a
# cache miss.
ICON_SRC="$CPL_DIR/icon/CPL.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP/Contents/Resources/CPL.icns"
  rm -f "$APP/Contents/Resources/applet.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile CPL" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string CPL" "$PLIST"
  # macOS 26's osacompile ships an asset-catalog app icon referenced by
  # CFBundleIconName, which OVERRIDES CFBundleIconFile. Drop the key and the
  # catalog so the system falls back to our CPL.icns.
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true
  rm -f "$APP/Contents/Resources/Assets.car"
  ICON_INSTALLED=true
  echo "  Installed CPL app icon"
else
  warn "  CPL.icns not found at $ICON_SRC — keeping default applet icon"
fi

# 4b. Code-sign with the stable per-machine identity (Path A). MUST be the LAST
# bundle mutation. ensure_signing_identity() holds the full rationale; on any
# failure we fall back to ad-hoc + a loud warning so the result is never worse
# than the prior (ad-hoc-only) behavior.
echo ""
info "Signing CPL.app..."
SIGN_HASH=$(ensure_signing_identity "$SIGN_IDENTITY_NAME") || true
if [ -n "${SIGN_HASH:-}" ] \
   && codesign --keychain "$SIGN_KEYCHAIN" --force --identifier "$CPL_BUNDLE_ID" --sign "$SIGN_HASH" "$APP" 2>/dev/null \
   && codesign --verify --strict "$APP" 2>/dev/null; then
  success "  Signed with stable identity '$SIGN_IDENTITY_NAME' ($SIGN_HASH)"
  echo "  The CPL→iTerm Automation grant will now survive future rebuilds."
  echo "  (First launch after this install prompts once — click Allow.)"
else
  warn "  Could not sign with a stable identity — falling back to ad-hoc."
  warn "  CPL→iTerm permission may need re-granting after each rebuild."
  warn "  If launch fails with 'Not authorized', run: tccutil reset AppleEvents"
  codesign --force --sign - "$APP" 2>/dev/null || true
fi

# 4c. Refresh Launch Services / icon cache. Safe after signing — touches the
# bundle mtime and the LS database only, never the sealed Contents/.
touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP" 2>/dev/null || true
if [[ "$ICON_INSTALLED" == true ]]; then
  killall Dock 2>/dev/null || true
  killall Finder 2>/dev/null || true
fi

# 5. Copy iTerm2 profile
echo ""
cp "$CPL_DIR/iterm2/CPL.json" "$DEST_ITERM/CPL.json"
echo "  Installed CPL.json → ~/Library/Application Support/iTerm2/DynamicProfiles/CPL.json"

# 6. Remove obsolete cpl-close-zed binary if present (Zed support removed in v1.5.0)
if [[ -f "$DEST_BIN/cpl-close-zed" ]]; then
  rm -f "$DEST_BIN/cpl-close-zed"
  echo "  Removed obsolete ~/bin/cpl-close-zed (Zed support dropped)"
fi

# 7. Config is ~/.cpl.json, auto-created by cpl-picker on first launch (it detects
#    displays, fingerprints the layout, and migrates maxSlots from any legacy
#    ~/.cpl.conf). Nothing to generate here — geometry/profile detection moved into
#    the picker as of v2.0.0.
echo ""
if [[ -f "$HOME/.cpl.json" ]]; then
  echo "  ~/.cpl.json exists (keeping current config)"
else
  echo "  ~/.cpl.json will be created on first CPL launch"
  if [[ -f "$HOME/.cpl.conf" ]]; then
    echo "  (legacy ~/.cpl.conf detected — maxSlots migrates automatically; delete the file afterward)"
  fi
fi

# Remove legacy flat slot files (~/.cpl-slots/<N>) from pre-2.0. The slot manager is
# now monitor-aware (mon<M>-<N>) and ignores flat files, but clear them for tidiness.
if [[ -d "$HOME/.cpl-slots" ]]; then
  for f in "$HOME/.cpl-slots"/*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    if [[ "$base" =~ ^[0-9]+$ ]]; then
      rm -f "$f"
      echo "  Removed legacy slot file ~/.cpl-slots/$base"
    fi
  done
fi

# 8. Write installed version
echo "$REPO_VERSION" > "$INSTALLED_VERSION_FILE"

echo ""
success "CPL v${REPO_VERSION} installed successfully."
