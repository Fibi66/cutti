#!/usr/bin/env bash
#
# package-macos.sh — Wrap the SwiftPM-built CuttiMac executable into a
# distributable Cutti.app bundle.
#
# Usage:
#   scripts/package-macos.sh --version 1.0.0 --build 1
#   scripts/package-macos.sh --version 1.0.0 --build 1 --sign
#
# Without --sign, produces an unsigned .app for local smoke testing.
# With --sign, expects these env vars:
#   DEVELOPER_ID_APPLICATION   — e.g. "Developer ID Application: Foo Bar (ABCD12EFGH)"
#   SPARKLE_PUBLIC_ED_KEY      — base64 EdDSA public key from `generate_keys`
#
# Output:
#   build/Cutti.app
#
# This script is idempotent — it deletes any prior build/Cutti.app first.

set -euo pipefail

# ---------- Argument parsing ----------
VERSION=""
BUILD_NUMBER=""
SIGN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build)   BUILD_NUMBER="$2"; shift 2 ;;
    --sign)    SIGN=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "Usage: $0 --version X.Y.Z --build N [--sign]" >&2
  exit 2
fi

if [[ $SIGN -eq 1 ]]; then
  : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION when --sign}"
fi

# SPARKLE_PUBLIC_ED_KEY is required regardless of --sign: it goes into
# Info.plist and Sparkle refuses to start with an empty/missing value
# ("The provided EdDSA key could not be decoded" → fatal alert at every
# app launch). The key is the *public* half of the EdDSA pair, so it's
# safe to commit/share — it lives in this repo's GitHub Secrets only
# for convenience, not secrecy. To recover it: any prior signed Cutti.app
# has it baked in (`plutil -extract SUPublicEDKey raw <app>/Contents/Info.plist`),
# or check the value in docs/distributing-macos.md.
: "${SPARKLE_PUBLIC_ED_KEY:?Set SPARKLE_PUBLIC_ED_KEY (base64 EdDSA public key from generate_keys; see docs/distributing-macos.md)}"

# ---------- Paths ----------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/macos/CuttiMac"
SCRIPT_DIR="$ROOT/scripts/macos"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Cutti.app"

INFO_TPL="$SCRIPT_DIR/Info.plist.template"
ENT="$SCRIPT_DIR/Cutti.entitlements"
ICON="$SCRIPT_DIR/AppIcon.icns"

# ---------- Build ----------
echo "==> swift build -c release --arch arm64"
cd "$PKG_DIR"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift build -c release --arch arm64

# Locate build outputs.
EXEC_PATH="$PKG_DIR/.build/arm64-apple-macosx/release/CuttiMac"
RES_BUNDLE="$PKG_DIR/.build/arm64-apple-macosx/release/CuttiMac_CuttiMac.bundle"

if [[ ! -x "$EXEC_PATH" ]]; then
  echo "ERROR: executable not found at $EXEC_PATH" >&2; exit 1
fi
if [[ ! -d "$RES_BUNDLE" ]]; then
  echo "ERROR: SwiftPM resource bundle not found at $RES_BUNDLE" >&2; exit 1
fi

# Locate Sparkle.framework. SwiftPM's binary-target cache lives under
# .build/artifacts/<package>/Sparkle/. The exact path varies by Sparkle
# version, so we glob.
SPARKLE_FRAMEWORK="$(find "$PKG_DIR/.build/artifacts" -type d -name 'Sparkle.framework' -path '*/Sparkle*' | head -n1 || true)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "ERROR: Sparkle.framework not found under .build/artifacts/" >&2
  echo "       Run 'swift package resolve' inside macos/CuttiMac and try again." >&2
  exit 1
fi
echo "==> Using Sparkle at $SPARKLE_FRAMEWORK"

# ---------- Build the .app ----------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"

# Main executable. Renamed from "CuttiMac" to "Cutti" to match
# CFBundleExecutable.
cp "$EXEC_PATH" "$APP/Contents/MacOS/Cutti"
chmod +x "$APP/Contents/MacOS/Cutti"

# SwiftPM's synthesized `Bundle.module` accessor expects the resource
# bundle next to `Bundle.main.bundleURL` — for an `.app`, that's
# `Cutti.app/CuttiMac_CuttiMac.bundle` at the .app's *root*, which
# `codesign` rejects with "unsealed contents present in the bundle
# root". CuttiMac's call sites have been migrated to a custom
# `Bundle.cuttiMacResources` accessor (see CuttiMacBundleResources.swift)
# that looks for the bundle in the Apple-standard location below.
cp -R "$RES_BUNDLE" "$APP/Contents/Resources/"

# Sparkle.framework — preserve symlinks (-R, not -RL).
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"

# App icon. Info.plist references AppIcon.icns via CFBundleIconFile;
# macOS resolves the basename to <name>.icns inside Contents/Resources.
if [[ -f "$ICON" ]]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "WARN: $ICON not found — bundle will ship without an app icon" >&2
fi

# Add @executable_path/../Frameworks to the binary's rpath so the
# dynamic loader can find Sparkle at launch.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
  "$APP/Contents/MacOS/Cutti" 2>/dev/null || true

# ---------- Render Info.plist ----------
ED_KEY="$SPARKLE_PUBLIC_ED_KEY"
if [[ -z "$ED_KEY" ]]; then
  echo "ERROR: SPARKLE_PUBLIC_ED_KEY is empty after validation — refusing to bake a broken Info.plist." >&2
  exit 1
fi
sed \
  -e "s|{{VERSION}}|$VERSION|g" \
  -e "s|{{BUILD}}|$BUILD_NUMBER|g" \
  -e "s|{{ED_PUB_KEY}}|$ED_KEY|g" \
  "$INFO_TPL" > "$APP/Contents/Info.plist"

# Validate the result.
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# ---------- Sign (optional) ----------
if [[ $SIGN -eq 1 ]]; then
  IDENTITY="$DEVELOPER_ID_APPLICATION"
  echo "==> Codesigning with identity: $IDENTITY"

  # Sign nested helpers FIRST. Sparkle ships an Autoupdate.app and an
  # Updater.app inside Sparkle.framework, plus XPC services. SwiftPM
  # may also drop a resource bundle next to the executable (e.g.
  # CuttiMac_CuttiMac.bundle). We sign them bottom-up so each enclosing
  # signature wraps already-signed content. Sparkle docs explicitly
  # warn against `codesign --deep`.
  sign() {
    codesign --force --options runtime --timestamp \
      --sign "$IDENTITY" "$@"
  }

  # Inner XPC services, helper apps, and SwiftPM resource bundles.
  # Note: Sparkle ships a bare Autoupdate Mach-O binary directly inside
  # Versions/B/ (not wrapped in an .app), so we match it by name too.
  while IFS= read -r helper; do
    [[ -n "$helper" ]] || continue
    sign "$helper"
  done < <({
    find "$APP/Contents/Frameworks/Sparkle.framework" \
      \( -name '*.xpc' -o -name '*.app' \) -print
    find "$APP/Contents/Frameworks/Sparkle.framework" \
      -type f -name 'Autoupdate' -print
    find "$APP/Contents/MacOS" "$APP/Contents/Resources" \
      -maxdepth 2 -name '*.bundle' -print 2>/dev/null
  })

  # Any loose dylibs sitting next to the executable.
  while IFS= read -r dylib; do
    [[ -n "$dylib" ]] || continue
    sign "$dylib"
  done < <(find "$APP/Contents/MacOS" "$APP/Contents/Frameworks" \
             -maxdepth 2 -name '*.dylib' -print 2>/dev/null)

  # The Sparkle framework itself.
  sign "$APP/Contents/Frameworks/Sparkle.framework"

  # Finally the main app, with hardened runtime + entitlements.
  codesign --force --options runtime --timestamp \
    --entitlements "$ENT" \
    --sign "$IDENTITY" \
    "$APP"

  # Verify.
  codesign --verify --strict --verbose=2 "$APP"
fi

echo
echo "==> Built $APP"
echo "    Version $VERSION (build $BUILD_NUMBER)"
[[ $SIGN -eq 1 ]] && echo "    Signed:  yes" || echo "    Signed:  no (smoke-test only — not distributable)"
