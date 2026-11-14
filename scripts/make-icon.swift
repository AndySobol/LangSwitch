// Draws the application icon and writes an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(
    fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    let unit = size / 1024

    // macOS icon grid: an 824-point squircle centred on a 1024 canvas.
    let body = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186 * unit, yRadius: 186 * unit)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -12 * unit), blur: 28 * unit,
        color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill()
    squircle.fill()
    context.restoreGState()

    context.saveGState()
    squircle.addClip()
    // Black glass: a near-black body that is a little lighter towards the top.
    let colors = [
        NSColor(white: 0.20, alpha: 1).cgColor,
        NSColor(white: 0.09, alpha: 1).cgColor,
        NSColor(white: 0.03, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: body.midX, y: body.maxY), end: CGPoint(x: body.midX, y: body.minY), options: [])
    // A soft highlight in the top-left corner.
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor.white.withAlphaComponent(0.16).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
            as CFArray, locations: [0, 1])!
    context.drawRadialGradient(
        glow, startCenter: CGPoint(x: 330 * unit, y: 800 * unit), startRadius: 0,
        endCenter: CGPoint(x: 330 * unit, y: 800 * unit), endRadius: 520 * unit, options: [])
    context.restoreGState()

    NSColor.white.withAlphaComponent(0.14).setStroke()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: 2 * unit, dy: 2 * unit), xRadius: 184 * unit, yRadius: 184 * unit)
    edge.lineWidth = 4 * unit
    edge.stroke()

    // Two key caps: the Latin one behind, the Cyrillic one in front.
    func key(_ letter: String, center: CGPoint, side: CGFloat, alpha: CGFloat, textColor: NSColor) {
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.24, yRadius: side * 0.24)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -10 * unit), blur: 26 * unit,
            color: NSColor.black.withAlphaComponent(0.55).cgColor)
        NSColor.white.withAlphaComponent(alpha).setFill()
        path.fill()
        context.restoreGState()
        let font = NSFont.systemFont(ofSize: side * 0.58, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let text = letter as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2),
            withAttributes: attributes)
    }
    key(
        "A", center: CGPoint(x: 400 * unit, y: 610 * unit), side: 330 * unit, alpha: 0.34,
        textColor: NSColor.white.withAlphaComponent(0.95))
    key(
        "Я", center: CGPoint(x: 610 * unit, y: 420 * unit), side: 380 * unit, alpha: 1,
        textColor: NSColor(white: 0.06, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

for (points, scale) in [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
    let bitmap = draw(size: CGFloat(points * scale))
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}
print(output.path)
