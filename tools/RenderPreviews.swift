import AppKit
import CoreText
import ImageIO

// Render the production C ABI on the process main thread. This is also the
// execution path used by the app and system screensaver, without UI capture.
enum PreviewError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let value): return value
        }
    }
}

func require(_ status: omacy_status, session: OpaquePointer? = nil) throws {
    guard status == OMACY_OK else {
        var message = [CChar](repeating: 0, count: 1024)
        _ = omacy_session_error_message(session, &message, message.count)
        throw PreviewError.message(String(cString: message))
    }
}

func savePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw PreviewError.message("Cannot create PNG at \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw PreviewError.message("Cannot finish PNG") }
}

final class GridPainter {
    let font: CTFont
    let columns: Int
    let rows: Int
    let cellWidth: CGFloat
    let cellHeight: CGFloat = 16
    var lines: [String: CTLine] = [:]
    var width: Int { Int(CGFloat(columns) * cellWidth) }
    var height: Int { Int(CGFloat(rows) * cellHeight) }

    init(fontURL: URL, columns: Int, rows: Int) throws {
        guard let data = CGDataProvider(url: fontURL as CFURL), let graphicsFont = CGFont(data) else {
            throw PreviewError.message("Cannot load bundled Fairfax HD font")
        }
        font = CTFontCreateWithGraphicsFont(graphicsFont, 16, nil, nil)
        var character: UniChar = 77
        var glyph: CGGlyph = 0
        var advance = CGSize.zero
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        cellWidth = max(ceil(advance.width), 1)
        self.columns = columns
        self.rows = rows
    }

    func paint(_ frame: OmacyFrame) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cells = frame.cells else { throw PreviewError.message("Cannot allocate preview image") }
        func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> CGColor {
            CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
        }
        context.setFillColor(color(frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.textMatrix = .identity
        for index in 0..<(columns * rows) {
            let cell = cells[index]
            let rect = CGRect(x: CGFloat(index % columns) * cellWidth,
                              y: CGFloat(rows - index / columns - 1) * cellHeight,
                              width: cellWidth, height: cellHeight)
            if cell.occupancy & UInt8(OMACY_CELL_HAS_BACKGROUND) != 0 {
                context.setFillColor(color(cell.bg_r, cell.bg_g, cell.bg_b, cell.bg_a))
                context.fill(rect)
            }
            guard cell.occupancy & UInt8(OMACY_CELL_HAS_GLYPH) != 0,
                  let scalar = UnicodeScalar(cell.glyph), cell.glyph != 0 else { continue }
            let key = "\(cell.glyph):\(cell.fg_r):\(cell.fg_g):\(cell.fg_b):\(cell.fg_a)"
            let line: CTLine
            if let cached = lines[key] { line = cached } else {
                if lines.count >= 4096 { lines.removeAll(keepingCapacity: true) }
                let text = NSAttributedString(string: String(scalar), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(cell.fg_r, cell.fg_g, cell.fg_b, cell.fg_a)
                ])
                line = CTLineCreateWithAttributedString(text)
                lines[key] = line
            }
            context.saveGState()
            context.clip(to: rect)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + CTFontGetDescent(font))
            CTLineDraw(line, context)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw PreviewError.message("Cannot publish preview image") }
        return image
    }
}

func render(effect: String, root: URL, seed: UInt64) throws -> [String: Any] {
    let columns = 84, rows = 24, stride = 4
    let artwork = try Data(contentsOf: root.appendingPathComponent("Resources/screensaver.txt"))
    let name = Array(effect.utf8)
    var session: OpaquePointer?
    try artwork.withUnsafeBytes { art in
        try name.withUnsafeBufferPointer { name in
            var config = OmacySessionConfig()
            config.ascii = art.bindMemory(to: UInt8.self).baseAddress
            config.ascii_len = art.count
            config.effect = name.baseAddress
            config.effect_len = name.count
            config.bg_a = 255
            config.has_seed = 1
            config.seed = seed
            try require(omacy_session_create(&config, UInt32(columns), UInt32(rows), &session))
        }
    }
    defer { omacy_session_destroy(session) }
    let painter = try GridPainter(fontURL: root.appendingPathComponent("Resources/FairfaxHD.ttf"), columns: columns, rows: rows)
    var frames: [CGImage] = []
    var frameTicks: [Int] = []
    var ticks = 0, finished = false
    for tick in 0..<1800 {
        var result = OmacyStepResult()
        try require(omacy_session_step(session, 1.0 / 60.0, &result), session: session)
        ticks = tick + 1
        if tick % stride == 0 || result.needs_begin_next != 0 {
            frames.append(try painter.paint(result.frame))
            frameTicks.append(ticks)
        }
        if result.needs_begin_next != 0 { finished = true; break }
    }
    guard finished, frames.count > 2 else { throw PreviewError.message("\(effect) did not complete within the preview budget") }
    let output = root.appendingPathComponent("docs/effects/\(effect).gif")
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else {
        throw PreviewError.message("Cannot create GIF")
    }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    // GIF stores hundredths of a second. Alternate rounded frame boundaries
    // so its duration follows the simulation instead of rounding every delay up.
    var previousBoundary = 0
    for (index, image) in frames.enumerated() {
        let endTick = index + 1 < frames.count ? frameTicks[index + 1] - 1 : ticks
        let boundary = Int((Double(endTick) * 100.0 / 60.0).rounded())
        let delay = Double(boundary - previousBoundary) / 100.0
        previousBoundary = boundary
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { throw PreviewError.message("Cannot finish \(effect) GIF") }
    let sampleIndices = [frames.count / 8, frames.count * 3 / 8, frames.count * 5 / 8, frames.count * 7 / 8]
    for (index, frameIndex) in sampleIndices.enumerated() {
        try savePNG(frames[frameIndex], to: root.appendingPathComponent("build/previews/\(effect)-\(index).png"))
    }
    return ["effect": effect, "seed": seed, "columns": columns, "rows": rows, "simulation_ticks": ticks,
            "gif_frames": frames.count, "gif_duration_seconds": Double(previousBoundary) / 100.0,
            "simulation_hz": 60, "sample_stride": stride,
            "width": painter.width, "height": painter.height, "source": "production C ABI cell grid and bundled Fairfax HD font"]
}

do {
    guard Thread.isMainThread else { throw PreviewError.message("Preview export must run on the main thread") }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("docs/effects"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("build/previews"), withIntermediateDirectories: true)
    let effects = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : ["aurora", "starfield", "circuit"]
    var evidence: [[String: Any]] = []
    for effect in effects {
        let result = try render(effect: effect, root: root, seed: 42)
        evidence.append(result)
        print("Rendered \(effect): \(result["gif_frames"]!) frames")
    }
    let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("docs/effects/manifest.json"))
} catch {
    fputs("Preview export failed: \(error)\n", stderr)
    exit(1)
}
