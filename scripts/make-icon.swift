import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = root.appendingPathComponent("build/Macoma.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes = [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
             (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
             (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")]
for (size, name) in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let transform = AffineTransform(scale: CGFloat(size) / 1024)
    (transform as NSAffineTransform).concat()
    let shape = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.19, blue: 0.22, alpha: 1),
               ending: NSColor(calibratedRed: 0.035, green: 0.065, blue: 0.085, alpha: 1))!.draw(in: shape, angle: -90)
    NSColor(white: 1, alpha: 0.1).setStroke(); shape.lineWidth = 3; shape.stroke()
    NSColor(calibratedRed: 0.62, green: 0.98, blue: 0.77, alpha: 1).setFill()
    let pixel: CGFloat = 64
    // Original terminal prompt, drawn on a visible character-cell grid.
    for (col, row) in [(0, 3), (1, 2), (2, 1), (1, 0), (0, -1), (4, -1), (5, -1), (6, -1)] {
        NSBezierPath(roundedRect: NSRect(x: 265 + CGFloat(col) * pixel, y: 422 + CGFloat(row) * pixel,
                                         width: pixel - 7, height: pixel - 7), xRadius: 8, yRadius: 8).fill()
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
