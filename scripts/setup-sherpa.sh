#!/usr/bin/env bash
# Fetch the sherpa-onnx + ONNX Runtime macOS xcframeworks that Cutti
# links against for real speaker diarization. Total ~80MB extracted,
# NOT checked into git — run this script once after cloning the repo.
#
# Idempotent: skips any step whose output is already present.

set -euo pipefail

SHERPA_VERSION="v1.12.39"
ORT_VERSION="1.24.4"

SHERPA_ASSET="sherpa-onnx-${SHERPA_VERSION}-macos-xcframework-static.tar.bz2"
SHERPA_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_VERSION}/${SHERPA_ASSET}"

ORT_ASSET="onnxruntime-osx-universal2-static_lib-${ORT_VERSION}.zip"
ORT_URL="https://github.com/csukuangfj/onnxruntime-libs/releases/download/v${ORT_VERSION}/${ORT_ASSET}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/macos/CuttiMac/Vendor"
SHERPA_XCF="${VENDOR_DIR}/sherpa-onnx.xcframework"
ORT_XCF="${VENDOR_DIR}/onnxruntime.xcframework"

mkdir -p "${VENDOR_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ─── 1. sherpa-onnx ────────────────────────────────────────────────────
if [ -d "${SHERPA_XCF}" ] && [ -f "${SHERPA_XCF}/Info.plist" ]; then
  echo "✅ sherpa-onnx.xcframework already present"
else
  echo "⬇️  Downloading sherpa-onnx ${SHERPA_VERSION}…"
  curl -sL -o "${TMP_DIR}/${SHERPA_ASSET}" "${SHERPA_URL}"
  echo "📦 Extracting sherpa-onnx…"
  tar -xjf "${TMP_DIR}/${SHERPA_ASSET}" -C "${TMP_DIR}"
  SRC="${TMP_DIR}/sherpa-onnx-${SHERPA_VERSION}-macos-xcframework-static/sherpa-onnx.xcframework"
  if [ ! -d "${SRC}" ]; then
    echo "❌ Extracted archive does not contain expected xcframework layout."
    exit 1
  fi
  cp -R "${SRC}" "${VENDOR_DIR}/"

  # Generate a module.modulemap so SPM can `import SherpaOnnxC`.
  cat > "${SHERPA_XCF}/macos-arm64_x86_64/Headers/module.modulemap" <<'EOF'
module SherpaOnnxC {
    umbrella header "sherpa-onnx/c-api/c-api.h"
    export *
    link "c++"
}
EOF
  echo "✅ Installed ${SHERPA_XCF}"
fi

# ─── 2. ONNX Runtime static ────────────────────────────────────────────
# sherpa-onnx's libsherpa-onnx.a leaves OrtGetApiBase undefined; we need
# ONNX Runtime's static lib (+ the separate mlas arch-specific libs)
# merged into a single universal .a to feed an xcframework.
if [ -d "${ORT_XCF}" ] && [ -f "${ORT_XCF}/Info.plist" ]; then
  echo "✅ onnxruntime.xcframework already present"
else
  echo "⬇️  Downloading onnxruntime ${ORT_VERSION}…"
  curl -sL -o "${TMP_DIR}/${ORT_ASSET}" "${ORT_URL}"
  echo "📦 Extracting onnxruntime…"
  unzip -q "${TMP_DIR}/${ORT_ASSET}" -d "${TMP_DIR}"
  ORT_SRC="${TMP_DIR}/onnxruntime-osx-universal2-static_lib-${ORT_VERSION}"
  ORT_LIBS="${ORT_SRC}/lib"

  # Merge mlas_arm64 into the arm64 slice of libonnxruntime.a, same for x86_64.
  WORK="${TMP_DIR}/ort-merge"
  mkdir -p "${WORK}"
  lipo -thin arm64 "${ORT_LIBS}/libonnxruntime.a" -output "${WORK}/ort-arm64.a"
  lipo -thin x86_64 "${ORT_LIBS}/libonnxruntime.a" -output "${WORK}/ort-x86_64.a"

  libtool -static -o "${WORK}/merged-arm64.a" \
    "${WORK}/ort-arm64.a" "${ORT_LIBS}/libonnxruntime_mlas_arm64.a"
  libtool -static -o "${WORK}/merged-x86_64.a" \
    "${WORK}/ort-x86_64.a" "${ORT_LIBS}/libonnxruntime_mlas_x86_64.a"

  lipo -create "${WORK}/merged-arm64.a" "${WORK}/merged-x86_64.a" \
    -output "${WORK}/libonnxruntime.a"

  # Build the onnxruntime.xcframework layout by hand. xcodebuild -create-xcframework
  # refuses static-archives-with-headers, so we lay out the same structure
  # that xcodebuild would emit for a shared framework.
  SLICE="${ORT_XCF}/macos-arm64_x86_64"
  mkdir -p "${SLICE}/Headers"
  cp "${WORK}/libonnxruntime.a" "${SLICE}/libonnxruntime.a"
  cp -R "${ORT_SRC}/include/"* "${SLICE}/Headers/"

  # Minimal modulemap so downstream targets can `import OnnxRuntimeC`
  # if they need the C API directly. Currently unused (sherpa wraps it)
  # but cheap to ship.
  cat > "${SLICE}/Headers/module.modulemap" <<'EOF'
module OnnxRuntimeC {
    header "onnxruntime_c_api.h"
    export *
    link "c++"
}
EOF

  cat > "${ORT_XCF}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>BinaryPath</key>
            <string>libonnxruntime.a</string>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>macos-arm64_x86_64</string>
            <key>LibraryPath</key>
            <string>libonnxruntime.a</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
                <string>x86_64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
EOF
  echo "✅ Installed ${ORT_XCF}"
fi

echo "🎉 sherpa-onnx + onnxruntime xcframeworks ready."

