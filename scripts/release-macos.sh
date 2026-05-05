#!/usr/bin/env bash
#
# release-macos.sh — Cut a signed, notarized, Sparkle-ready release of
# Cutti.app and publish it to GitHub Releases.
#
# Usage:
#   scripts/release-macos.sh --version 1.0.0 [--draft]
#
# Required env vars:
#   DEVELOPER_ID_APPLICATION    Codesign identity, e.g.
#                               "Developer ID Application: Foo (ABCD12EFGH)"
#   NOTARYTOOL_KEYCHAIN_PROFILE Profile name created via
#                               `xcrun notarytool store-credentials`
#   SPARKLE_PUBLIC_ED_KEY       base64 public key from `generate_keys`.
#                               Private key lives in login Keychain;
#                               sign_update finds it automatically.
#   GH_TOKEN / GITHUB_TOKEN     Used by `gh` CLI (usually set already).
#
# Steps:
#   1. swift build + wrap into Cutti.app via package-macos.sh --sign
#   2. zip and notarize the .app
#   3. create + sign + notarize a DMG
#   4. sign_update — produce EdDSA signature for Sparkle
#   5. generate appcast.xml advertising this release
#   6. gh release create — uploads BOTH the DMG and appcast.xml
#
# The Sparkle feed URL hardcoded in Info.plist is
#   https://github.com/Fibi66/cutti/releases/latest/download/appcast.xml
# which GitHub redirects to whichever appcast.xml is attached to the
# most recent (non-pre)release. So uploading the new appcast.xml as a
# release asset is all it takes for users to see the update.
#
# Idempotent within a single run; not idempotent across runs (gh release
# create will fail if the tag already exists). Use --draft for testing.

set -euo pipefail

VERSION=""
DRAFT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --draft)   DRAFT=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$VERSION" ]] || { echo "Missing --version" >&2; exit 2; }

: "${DEVELOPER_ID_APPLICATION:?required}"
: "${NOTARYTOOL_KEYCHAIN_PROFILE:?required}"
: "${SPARKLE_PUBLIC_ED_KEY:?required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Cutti.app"
DMG="$BUILD_DIR/Cutti-$VERSION.dmg"
ZIP="$BUILD_DIR/Cutti-$VERSION.zip"
APPCAST="$BUILD_DIR/appcast.xml"
TAG="v$VERSION"

# Build number = total commits on HEAD. Monotonic and reproducible.
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"

# When notarytool stores credentials in a non-default keychain (CI uses a
# build keychain), every notarytool invocation must reference it. Empty
# in local runs (uses login keychain).
NOTARYTOOL_KC=()
if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
  NOTARYTOOL_KC=(--keychain "$NOTARYTOOL_KEYCHAIN")
fi

# ---------- Pre-flight ----------
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "ERROR: working tree is dirty. Commit or stash first." >&2
  exit 1
fi

# CI runs after the tag is already pushed (workflow trigger). If the tag
# already points at HEAD that's fine — we'll skip the tag-create step at
# the end. Otherwise it's an error.
SKIP_TAG_PUSH=0
if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
  TAG_SHA="$(git -C "$ROOT" rev-parse "${TAG}^{commit}")"
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  if [[ "$TAG_SHA" == "$HEAD_SHA" ]]; then
    echo "==> Tag $TAG already at HEAD; will skip tag create + push"
    SKIP_TAG_PUSH=1
  else
    echo "ERROR: tag $TAG already exists but does not point at HEAD." >&2
    echo "       TAG=$TAG_SHA  HEAD=$HEAD_SHA" >&2
    exit 1
  fi
fi

for tool in gh xcrun hdiutil sign_update; do
  command -v "$tool" >/dev/null || {
    echo "ERROR: missing tool: $tool" >&2
    [[ "$tool" == "sign_update" ]] && \
      echo "       Install Sparkle CLI: 'brew install --cask sparkle' or build from source." >&2
    exit 1
  }
done

# ---------- 1. Package + sign the .app ----------
"$ROOT/scripts/package-macos.sh" \
  --version "$VERSION" \
  --build "$BUILD_NUMBER" \
  --sign

# ---------- 2. Notarize the .app ----------
echo "==> Notarizing Cutti.app"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
  "${NOTARYTOOL_KC[@]}" \
  --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --wait
xcrun stapler staple "$APP"

# ---------- 3. Create + sign + notarize the DMG ----------
echo "==> Building DMG"
rm -f "$DMG"

# Layout: Cutti.app + a symlink to /Applications + a Read-Me. Users
# drag-and-drop to install.
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/Cutti.app"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create \
  -volname "Cutti $VERSION" \
  -srcfolder "$DMG_STAGE" \
  -ov -format UDZO \
  "$DMG"

codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG" \
  "${NOTARYTOOL_KC[@]}" \
  --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" \
  --wait
xcrun stapler staple "$DMG"

# ---------- 4. EdDSA sign for Sparkle ----------
echo "==> Signing update with Sparkle EdDSA key"
# CI on a clean keychain hangs on the keychain-based path because
# sign_update silently prompts for unlock when launched from a non-UI
# session. If SPARKLE_ED_PRIVATE_KEY_FILE is set, read the private key
# from that file (44-char base64) and skip the keychain entirely.
if [[ -n "${SPARKLE_ED_PRIVATE_KEY_FILE:-}" ]]; then
  SIGN_LINE="$(sign_update -f "$SPARKLE_ED_PRIVATE_KEY_FILE" "$DMG")"
else
  SIGN_LINE="$(sign_update "$DMG")"
fi
# Output looks like:  sparkle:edSignature="..." length="12345"
echo "$SIGN_LINE"

# ---------- 5. Generate appcast.xml ----------
# Single-item feed advertising just this release. Sparkle clients only
# care about the newest item, so no history is needed for updates to
# work. If you want a "view older releases" UI later, this is the spot
# to extend.
PUB_DATE="$(date -u +'%a, %d %b %Y %H:%M:%S %z')"
DMG_BASENAME="$(basename "$DMG")"
DMG_URL="https://github.com/Fibi66/cutti/releases/download/$TAG/$DMG_BASENAME"

echo "==> Writing appcast.xml"
cat > "$APPCAST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Cutti</title>
    <link>https://github.com/Fibi66/cutti/releases/latest/download/appcast.xml</link>
    <description>Cutti macOS updates</description>
    <language>en</language>
    <item>
      <title>Cutti $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/Fibi66/cutti/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure
        url="$DMG_URL"
        type="application/octet-stream"
        $SIGN_LINE />
    </item>
  </channel>
</rss>
EOF

# ---------- 6. GitHub release ----------
echo "==> Creating GitHub release $TAG"
if [[ $SKIP_TAG_PUSH -eq 0 ]]; then
  git -C "$ROOT" tag -a "$TAG" -m "Cutti $VERSION (build $BUILD_NUMBER)"
  git -C "$ROOT" push origin "$TAG"
fi

DRAFT_FLAG=""
[[ $DRAFT -eq 1 ]] && DRAFT_FLAG="--draft"

# Upload BOTH the DMG and the appcast.xml. The appcast.xml MUST be
# attached so the SUFeedURL alias serves it.
gh release create "$TAG" "$DMG" "$APPCAST" \
  --title "Cutti $VERSION" \
  --notes "Auto-generated release. Edit me with the changelog." \
  $DRAFT_FLAG

cat <<EOF

================================================================
Release $TAG published.
  DMG:     $DMG_URL
  Appcast: https://github.com/Fibi66/cutti/releases/latest/download/appcast.xml

Existing users running Cutti will pick up this update on their next
Sparkle check (default: once a day; or via Settings → Updates → Check Now).
================================================================
EOF
