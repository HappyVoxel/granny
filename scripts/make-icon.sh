#!/usr/bin/env bash
# Builds scripts/assets/granny.icns from the official logo
# (.github/assets/granny-favicon.png), resized through sips + iconutil.
# Falls back to a drawn placeholder only when the logo file is missing.
# Cached: delete the icns or set GRANNY_ICON_FORCE=1 to regenerate.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

OUT="scripts/assets"
ICNS="$OUT/granny.icns"
SOURCE=".github/assets/granny-favicon.png"

if [ -f "$ICNS" ] && [ "${GRANNY_ICON_FORCE:-0}" != "1" ]; then
  echo "icon cached: $ICNS"
  exit 0
fi

mkdir -p "$OUT/granny.iconset"

if [ -f "$SOURCE" ]; then
  for spec in \
    "16 icon_16x16" "32 icon_16x16@2x" \
    "32 icon_32x32" "64 icon_32x32@2x" \
    "128 icon_128x128" "256 icon_128x128@2x" \
    "256 icon_256x256" "512 icon_256x256@2x" \
    "512 icon_512x512" "1024 icon_512x512@2x"; do
    size="${spec%% *}"
    name="${spec##* }"
    sips -z "$size" "$size" "$SOURCE" --out "$OUT/granny.iconset/$name.png" >/dev/null
  done
  iconutil -c icns "$OUT/granny.iconset" -o "$ICNS"
  rm -rf "$OUT/granny.iconset"
  echo "icon: $ICNS (from $SOURCE)"
  exit 0
fi

echo "warning: $SOURCE missing; drawing the placeholder g"
TMP_SWIFT="$(mktemp -d)/icon.swift"
cat >"$TMP_SWIFT" <<'SWIFT'
import AppKit

func draw(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let s = CGFloat(size)
    let inset = s * 0.045
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.13, alpha: 1).setFill()
    path.fill()

    let text = "g" as NSString
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.66, weight: .bold),
        .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.62, alpha: 1),
    ]
    let textSize = text.size(withAttributes: attributes)
    let origin = NSPoint(x: (s - textSize.width) / 2, y: (s - textSize.height) / 2 + s * 0.02)
    text.draw(at: origin, withAttributes: attributes)

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments[1]
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in entries {
    guard let data = draw(size: size) else {
        FileHandle.standardError.write(Data("icon: draw failed for \(size)\n".utf8))
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png"))
}
SWIFT

swift "$TMP_SWIFT" "$OUT/granny.iconset"
iconutil -c icns "$OUT/granny.iconset" -o "$ICNS"
rm -rf "$OUT/granny.iconset"
echo "icon: $ICNS (placeholder)"
