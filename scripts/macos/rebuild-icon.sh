#!/usr/bin/env bash
#
# rebuild-icon.sh — Regenerate scripts/macos/AppIcon.icns from
# AppIcon-source-1024.png. Run this after replacing the source PNG.
#
# Requires: python3 + Pillow, sips, iconutil (sips/iconutil ship with macOS).
#   python3 -m pip install --user Pillow

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/AppIcon-source-1024.png"
OUT="$SCRIPT_DIR/AppIcon.icns"
TMP="$(mktemp -d -t cutti-icon)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: source image not found at $SRC" >&2
  exit 1
fi

python3 - "$SRC" "$ICONSET" <<'PY'
import os, sys
from PIL import Image, ImageDraw

src, out_dir = sys.argv[1], sys.argv[2]
img = Image.open(src).convert("RGBA")

# Center-crop to square then resize to 1024 master.
w, h = img.size
side = min(w, h)
left, top = (w - side) // 2, (h - side) // 2
img = img.crop((left, top, left + side, top + side)).resize((1024, 1024), Image.LANCZOS)

# Big Sur-style rounded square mask (radius ~22.4% of side, super-sampled).
def rounded_mask(size, radius_pct=0.2237):
    big = size * 4
    rb = int(big * radius_pct)
    m = Image.new("L", (big, big), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, big - 1, big - 1), radius=rb, fill=255)
    return m.resize((size, size), Image.LANCZOS)

canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
canvas.paste(img, (0, 0), rounded_mask(1024))

for s, name in [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]:
    canvas.resize((s, s), Image.LANCZOS).save(
        os.path.join(out_dir, name), "PNG", optimize=True,
    )
PY

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$TMP"
echo "==> Wrote $OUT ($(stat -f%z "$OUT") bytes)"
