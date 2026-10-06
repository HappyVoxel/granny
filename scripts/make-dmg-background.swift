import AppKit

// The dmg backdrop, Screenize-style: near-black ground, a soft glow under
// each icon slot (Finder labels its icons in black, so the halos are what
// keeps them readable), one clean arrow, and the app icon top centre.
//
// Usage:
//   xcrun swift scripts/make-dmg-background.swift scripts/assets/dmg-background.png
//   sips -s dpiWidth 144 -s dpiHeight 144 scripts/assets/dmg-background.png
//
// Finder draws background images at pixel size, hence the 2x bitmap (660x420
// points) with 144 dpi metadata.

let width: CGFloat = 660
let height: CGFloat = 420
let size = NSSize(width: width, height: height)

// Icon slots, in window coordinates (origin top-left), matching the
// --icon / --app-drop-link positions in scripts/build-release.sh.
let grannySlot = CGPoint(x: 170, y: 200)
let applicationsSlot = CGPoint(x: 490, y: 200)
let iconGlowRadius: CGFloat = 150

let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: x, y: height - y)
}

func glow(at center: CGPoint, radius: CGFloat, alpha: CGFloat) {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(calibratedWhite: 1, alpha: alpha).cgColor,
        NSColor(calibratedWhite: 1, alpha: 0).cgColor,
    ] as CFArray
    guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
    ctx.drawRadialGradient(
        gradient,
        startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius,
        options: [])
}

// Near-black walnut ground.
ctx.setFillColor(NSColor(calibratedRed: 0.055, green: 0.048, blue: 0.040, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

// Halos under the slots: light enough for Finder's black labels, soft
// enough to stay moody. Two rings each - a tight core and a wide spill.
for slot in [grannySlot, applicationsSlot] {
    let center = point(slot.x, slot.y + 34)
    glow(at: center, radius: iconGlowRadius, alpha: 0.22)
    glow(at: center, radius: iconGlowRadius * 0.55, alpha: 0.26)
}
glow(at: point(width / 2, 94), radius: 100, alpha: 0.16)

// The arrow: a straight light bar with a solid head, the Screenize read.
let arrowY = point(grannySlot.x, grannySlot.y).y
let arrowStart: CGFloat = 262
let arrowEnd: CGFloat = 388
ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.92).cgColor)
ctx.setLineWidth(4)
ctx.setLineCap(.butt)
ctx.move(to: CGPoint(x: arrowStart, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEnd, y: arrowY))
ctx.strokePath()
ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.92).cgColor)
ctx.move(to: CGPoint(x: arrowEnd + 26, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEnd, y: arrowY + 12))
ctx.addLine(to: CGPoint(x: arrowEnd, y: arrowY - 12))
ctx.closePath()
ctx.fillPath()

// The app icon, top centre, with its own small halo.
if let icon = NSImage(contentsOfFile: "scripts/assets/granny.icns") {
    let iconSize: CGFloat = 76
    let rect = NSRect(x: (width - iconSize) / 2, y: height - 132, width: iconSize, height: iconSize)
    icon.draw(in: rect)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
else { exit(1) }
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dmg-background.png")
try! png.write(to: out)
print("wrote \(out.path)")
