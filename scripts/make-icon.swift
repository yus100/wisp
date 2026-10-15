// Draws Wisp's app icon, a glowing will-o'-the-wisp on a dark tile, and writes Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift            (run from the repository root)
//
// Procedural on purpose: the icon is reproducible and easy to tweak.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray,
        locations: stops.map(\.0))!
}

func drawIcon(in context: CGContext) {
    // Tile: the macOS icon grid's 824 pt rounded square, with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
    context.addPath(tilePath)
    context.setFillColor(color(0x0B0A16))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(
        gradient([(0, color(0x231C46)), (0.55, color(0x110E24)), (1, color(0x07060F))]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint ambient light behind the wisp.
    context.drawRadialGradient(
        gradient([(0, color(0x5EEAD4, 0.22)), (1, color(0x5EEAD4, 0))]),
        startCenter: CGPoint(x: 560, y: 590), startRadius: 0,
        endCenter: CGPoint(x: 560, y: 590), endRadius: 420, options: [])

    // Tail: soft glows laid along a curve, shrinking and fading toward the tip, like a comet's trail.
    func point(_ t: CGFloat, _ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGPoint {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
    let trails: [(curve: [CGPoint], width: CGFloat, strength: CGFloat)] = [
        ([CGPoint(x: 578, y: 600), CGPoint(x: 400, y: 640), CGPoint(x: 250, y: 470), CGPoint(x: 300, y: 270)], 92, 1),
        ([CGPoint(x: 590, y: 585), CGPoint(x: 500, y: 470), CGPoint(x: 440, y: 360), CGPoint(x: 470, y: 230)], 54, 0.6),
    ]
    for trail in trails {
        let steps = 220
        for step in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(step) / CGFloat(steps)
            let center = point(t, trail.curve[0], trail.curve[1], trail.curve[2], trail.curve[3])
            let radius = trail.width * pow(1 - t, 1.25) + 4
            let alpha = 0.075 * trail.strength * (1 - t * 0.85)
            context.drawRadialGradient(
                gradient([(0, color(0xCCFBF1, alpha * 1.6)), (0.5, color(0x2DD4BF, alpha)), (1, color(0x6366F1, 0))]),
                startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }
    }

    // Orb: layered glow, then a bright core.
    let orb = CGPoint(x: 578, y: 600)
    for (radius, alpha) in [(260.0, 0.10), (190.0, 0.18), (140.0, 0.30)] {
        context.drawRadialGradient(
            gradient([(0, color(0x99F6E4, alpha)), (1, color(0x2DD4BF, 0))]),
            startCenter: orb, startRadius: 0, endCenter: orb, endRadius: radius, options: [])
    }
    context.saveGState()
    context.setShadow(offset: .zero, blur: 60, color: color(0xCCFBF1, 1))
    context.drawRadialGradient(
        gradient([(0, color(0xFFFFFF)), (0.45, color(0xE0FFF8)), (0.8, color(0x5EEAD4, 0.9)), (1, color(0x2DD4BF, 0))]),
        startCenter: CGPoint(x: orb.x - 18, y: orb.y + 22), startRadius: 0,
        endCenter: orb, endRadius: 112, options: [])
    context.restoreGState()

    // Sparks drifting off the tail.
    for (x, y, r) in [(318.0, 470.0, 8.0), (250.0, 350.0, 5.5), (470.0, 250.0, 5.0), (712.0, 770.0, 7.0), (760.0, 420.0, 4.5)] {
        let center = CGPoint(x: x, y: y)
        context.drawRadialGradient(
            gradient([(0, color(0xFFFFFF, 0.95)), (0.4, color(0x99F6E4, 0.6)), (1, color(0x5EEAD4, 0))]),
            startCenter: center, startRadius: 0, endCenter: center, endRadius: r * 3, options: [])
    }
    context.restoreGState()
}

func renderPNG(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(in: context)
    return bitmap.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let iconset = fileManager.temporaryDirectory.appending(path: "AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try renderPNG(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try renderPNG(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let output = URL(filePath: fileManager.currentDirectoryPath).appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
let png = URL(filePath: fileManager.currentDirectoryPath).appending(path: "docs/assets/icon.png")
try fileManager.createDirectory(at: png.deletingLastPathComponent(), withIntermediateDirectories: true)
try renderPNG(size: 256).write(to: png)
print("Wrote \(output.path) and \(png.path)")
