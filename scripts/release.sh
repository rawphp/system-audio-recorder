#!/usr/bin/env bash
# scripts/release.sh
# Build, notarize, and package SystemAudioRecorder as a distributable DMG.
#
# Prerequisites:
#   - Apple Developer account with Developer ID Application certificate in keychain
#   - xcrun notarytool store-credentials NOTARYTOOL_PROFILE (run once to store API key)
#   - brew install create-dmg
#   - DEVELOPMENT_TEAM env var set to your 10-character Apple team ID
#
# Usage:
#   DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh
#
# Output:
#   dist/SystemAudioRecorder-<version>.dmg  (notarized and stapled)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLIST="$REPO_ROOT/Resources/Info.plist"
PROJECT="$REPO_ROOT/SystemAudioRecorder.xcodeproj"
SCHEME="SystemAudioRecorder"
DIST_DIR="$REPO_ROOT/dist"
STAGING_DIR="$REPO_ROOT/.staging"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-NOTARYTOOL_PROFILE}"

# ─────────────────────────────────────────────────────────────────────────────
# 1. Read version from Info.plist (single source of truth)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Reading version from Info.plist…"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$PLIST")
if [[ -z "$VERSION" ]]; then
  echo "ERROR: CFBundleShortVersionString not found in $PLIST" >&2
  exit 1
fi
echo "    Version: $VERSION"

DMG_NAME="SystemAudioRecorder-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Precondition checks
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Checking preconditions…"

# DEVELOPMENT_TEAM must be set and look like a 10-char Apple team ID
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "ERROR: DEVELOPMENT_TEAM is not set. Export your 10-character Apple team ID." >&2
  exit 1
fi
if ! [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: DEVELOPMENT_TEAM='$DEVELOPMENT_TEAM' does not look like a 10-character Apple team ID." >&2
  exit 1
fi
echo "    DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM  OK"

# Developer ID Application cert must be present in the keychain
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "ERROR: No 'Developer ID Application' certificate found in keychain." >&2
  echo "       Install your Developer ID Application cert via Xcode → Settings → Accounts." >&2
  exit 1
fi
echo "    Developer ID Application cert found  OK"

# create-dmg must be installed
if ! command -v create-dmg &>/dev/null; then
  echo "ERROR: create-dmg not found. Install with: brew install create-dmg" >&2
  exit 1
fi
echo "    create-dmg found at $(command -v create-dmg)  OK"

# notarytool must be reachable
if ! xcrun --find notarytool &>/dev/null; then
  echo "ERROR: xcrun notarytool not found. Ensure Xcode command-line tools are installed." >&2
  exit 1
fi
echo "    xcrun notarytool found  OK"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Build (Release, signed with Developer ID)
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Building (Release)…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  clean build

# ─────────────────────────────────────────────────────────────────────────────
# 4. Locate the built .app
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Locating built .app…"
BUILD_SETTINGS=$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  -showBuildSettings 2>/dev/null)

APP_PATH=$(echo "$BUILD_SETTINGS" \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / WRAPPER_NAME /{w=$2} END{print d "/" w}')

if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: Built .app not found at: $APP_PATH" >&2
  exit 1
fi
echo "    App: $APP_PATH"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Stage: copy .app and create Applications symlink
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Staging…"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# ─────────────────────────────────────────────────────────────────────────────
# 6. Create DMG
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Creating DMG…"
mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

create-dmg \
  --volname "SystemAudioRecorder ${VERSION}" \
  --window-size 500 300 \
  --icon-size 100 \
  --app-drop-link 380 100 \
  "$DMG_PATH" \
  "$STAGING_DIR"

echo "    DMG created: $DMG_PATH"

# ─────────────────────────────────────────────────────────────────────────────
# 7. Submit for notarization
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Submitting to Apple for notarization (this may take several minutes)…"
# `notarytool submit --wait` exits 0 even when Apple returns Invalid, so we
# parse the output to detect that case ourselves and fetch the rejection log.
SUBMIT_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait 2>&1 | tee /dev/stderr)

SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" \
  | awk '/^[[:space:]]+id:[[:space:]]/{id=$2} END{print id}')
NOTARY_STATUS=$(echo "$SUBMIT_OUTPUT" \
  | awk '/^[[:space:]]+status:[[:space:]]/{s=$2} END{print s}')

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  echo "ERROR: Notarization status: ${NOTARY_STATUS:-unknown}" >&2
  if [[ -n "${SUBMISSION_ID:-}" ]]; then
    echo "==> Fetching notarization log for submission ${SUBMISSION_ID}…" >&2
    xcrun notarytool log "$SUBMISSION_ID" \
      --keychain-profile "$NOTARYTOOL_PROFILE" >&2 || true
  fi
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. Staple the notarization ticket
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"

# ─────────────────────────────────────────────────────────────────────────────
# 9. Verify with Gatekeeper
# ─────────────────────────────────────────────────────────────────────────────
echo "==> Verifying with spctl…"
spctl -a -vv -t install "$DMG_PATH"

# ─────────────────────────────────────────────────────────────────────────────
# 10. Cleanup staging
# ─────────────────────────────────────────────────────────────────────────────
rm -rf "$STAGING_DIR"

echo ""
echo "✓ Release complete: $DMG_PATH"
echo "  Version : $VERSION"
echo "  Size    : $(du -sh "$DMG_PATH" | awk '{print $1}')"
