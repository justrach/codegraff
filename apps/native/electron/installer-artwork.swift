import AppKit

// Finder uses the logical size for its background and the 2x representation on
// Retina displays. The two empty circles sit behind real, draggable file icons.
let canvas = NSSize(width: 720, height: 440)
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func text(_ value: String, _ rect: NSRect, size: CGFloat, weight: NSFont.Weight, ink: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    (value as NSString).draw(in: rect, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: ink, .paragraphStyle: style,
    ])
}
func render(scale: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 720 * scale,
                              pixelsHigh: 440 * scale, bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    color(0xF5EFE3).setFill()
    NSRect(origin: .zero, size: canvas).fill()
    color(0xDCD3C2).setStroke()
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 48, y: 76)); line.line(to: NSPoint(x: 672, y: 76))
    line.lineWidth = 1; line.stroke()
    text("Install Codegraff", NSRect(x: 40, y: 350, width: 640, height: 40),
         size: 28, weight: .semibold, ink: color(0x203653))
    text("Drag Codegraff into Applications", NSRect(x: 40, y: 317, width: 640, height: 27),
         size: 16, weight: .regular, ink: color(0x726B5E))
    for x: CGFloat in [184, 536] {
        color(0xEAE2D3).setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 72, y: 158, width: 144, height: 144)).fill()
    }
    color(0x203653).setStroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 314, y: 229)); arrow.line(to: NSPoint(x: 406, y: 229))
    arrow.move(to: NSPoint(x: 390, y: 243)); arrow.line(to: NSPoint(x: 406, y: 229))
    arrow.line(to: NSPoint(x: 390, y: 215))
    arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.stroke()
    text("Then open Codegraff from Applications.", NSRect(x: 40, y: 35, width: 640, height: 23),
         size: 13, weight: .regular, ink: color(0x726B5E))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
guard CommandLine.arguments.count == 2 else { fatalError("Provide an output TIFF path") }
let reps = [render(scale: 1), render(scale: 2)]
let image = NSImage(size: canvas)
reps.forEach { image.addRepresentation($0) }
let data = image.tiffRepresentation!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
