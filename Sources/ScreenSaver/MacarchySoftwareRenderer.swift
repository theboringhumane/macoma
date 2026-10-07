import AppKit
import CoreText
import QuartzCore

/// AppKit paints the same engine frames as Metal so the System Settings
/// thumbnail can capture a real animation through ScreenSaverView.draw(_:).
/// Frame memory is copied before the next engine call invalidates it.
@MainActor
final class MacarchySoftwareRenderer {
    private var session: OmacyEngineSession?
    private var snapshot = OmacyStore.loadConfiguration()
    private var cells: [OmacyCell] = []
    private var columns: UInt32 = 0
    private var rows: UInt32 = 0
    private var font = OmacyFont.makeFont(size: 12)
    private var lastTimestamp: CFTimeInterval?
    private var finishedAt: CFTimeInterval?
    private var viewSize = CGSize.zero
    private var fitsArt = true
    private var lines: [GlyphKey: CTLine] = [:]
    private var clearColor = NSColor.black
    private(set) var frameCount: UInt64 = 0
    private(set) var frameSignature: UInt64 = 0
    private(set) var diagnostic: String?

    var isRunning: Bool { session != nil }
    var currentEffect: String { snapshot.settings.engineEffect }

    @discardableResult
    func start(in bounds: NSRect, fitsArt: Bool) -> Bool {
        stop()
        self.fitsArt = fitsArt
        viewSize = bounds.size
        snapshot = OmacyStore.loadConfiguration()
        return createSession()
    }

    func stop() {
        session = nil
        cells.removeAll(keepingCapacity: false)
        lines.removeAll(keepingCapacity: false)
        lastTimestamp = nil
        finishedAt = nil
    }

    func resize(to bounds: NSRect) {
        guard bounds.size != viewSize, bounds.width > 1, bounds.height > 1 else { return }
        viewSize = bounds.size
        guard session != nil else { return }
        // Only the small AppKit preview restarts on resize. A full-screen
        // fallback keeps the current effect until its normal boundary.
        if fitsArt { _ = createSession() }
    }

    func advance(timestamp: CFTimeInterval = CACurrentMediaTime()) {
        guard let session else { return }
        if let finishedAt, timestamp - finishedAt >= 0.75 {
            let previousBackground = snapshot.settings.background
            snapshot = OmacyStore.loadConfiguration()
            if snapshot.settings.background != previousBackground {
                _ = createSession()
                return
            }
            let layout = makeLayout()
            lines.removeAll(keepingCapacity: true)
            let configuration = engineConfiguration()
            switch session.beginNext(
                configuration: configuration,
                cols: layout.cols,
                rows: layout.rows,
                fileIdentity: "\(snapshot.art)|\(snapshot.settings)|\(layout.cols)x\(layout.rows)"
            ) {
            case .committed:
                self.finishedAt = nil
                lastTimestamp = timestamp
            case .ignoredUntilIdentityChanges:
                _ = createSession()
            case .failed(let failure):
                diagnostic = failure.description
                stop()
            }
            return
        }
        let elapsed = lastTimestamp.map { min(max(timestamp - $0, 0), 0.1) } ?? (1.0 / 30.0)
        lastTimestamp = timestamp
        switch session.step(elapsed: elapsed) {
        case .frame(let result):
            let frame = result.frame
            let count = Int(frame.cols) * Int(frame.rows)
            guard let pointer = frame.cells, count > 0, count <= OmacyLayout.maxCells else { return }
            columns = frame.cols
            rows = frame.rows
            cells = Array(UnsafeBufferPointer(start: pointer, count: count))
            clearColor = color(frame.clear_r, frame.clear_g, frame.clear_b, frame.clear_a)
            frameCount &+= 1
            // A stable content digest lets the host smoke test distinguish an
            // advancing engine from repeated screenshots of the same frame.
            frameSignature = cells.reduce(14695981039346656037) { signature, cell in
                var next = (signature ^ UInt64(cell.glyph)) &* 1099511628211
                next = (next ^ UInt64(cell.fg_r) ^ (UInt64(cell.fg_g) << 8)
                    ^ (UInt64(cell.fg_b) << 16) ^ (UInt64(cell.occupancy) << 24)) &* 1099511628211
                return (next ^ UInt64(cell.bg_r) ^ (UInt64(cell.bg_g) << 8)
                    ^ (UInt64(cell.bg_b) << 16)) &* 1099511628211
            }
            if result.needs_begin_next != 0, finishedAt == nil { finishedAt = timestamp }
        case .failure(let failure):
            diagnostic = failure.description
            stop()
        }
    }

    func draw(in bounds: NSRect) {
        clearColor.setFill()
        bounds.fill()
        guard !cells.isEmpty, columns > 0, rows > 0,
              let context = NSGraphicsContext.current?.cgContext else {
            drawStaticArt(in: bounds)
            return
        }
        let cellSize = OmacyLayout.cellSize(font: font)
        let origin = CGPoint(
            x: bounds.minX + (bounds.width - CGFloat(columns) * cellSize.width) / 2,
            y: bounds.minY + (bounds.height - CGFloat(rows) * cellSize.height) / 2
        )
        context.saveGState()
        context.clip(to: bounds)
        context.textMatrix = .identity
        for (index, cell) in cells.enumerated() {
            let column = index % Int(columns)
            let row = index / Int(columns)
            let rect = CGRect(
                x: origin.x + CGFloat(column) * cellSize.width,
                y: origin.y + CGFloat(Int(rows) - row - 1) * cellSize.height,
                width: cellSize.width,
                height: cellSize.height
            )
            if cell.occupancy & UInt8(OMACY_CELL_HAS_BACKGROUND) != 0 {
                context.setFillColor(color(cell.bg_r, cell.bg_g, cell.bg_b, cell.bg_a).cgColor)
                context.fill(rect)
            }
            guard cell.occupancy & UInt8(OMACY_CELL_HAS_GLYPH) != 0,
                  let scalar = UnicodeScalar(cell.glyph), cell.glyph != 0 else { continue }
            let key = GlyphKey(scalar: cell.glyph, r: cell.fg_r, g: cell.fg_g, b: cell.fg_b, a: cell.fg_a)
            let line: CTLine
            if let cached = lines[key] {
                line = cached
            } else {
                if lines.count >= 4096 { lines.removeAll(keepingCapacity: true) }
                let string = NSAttributedString(string: String(scalar), attributes: [
                    .font: font,
                    .foregroundColor: color(cell.fg_r, cell.fg_g, cell.fg_b, cell.fg_a)
                ])
                line = CTLineCreateWithAttributedString(string)
                lines[key] = line
            }
            context.saveGState()
            context.clip(to: rect)
            context.textPosition = CGPoint(x: rect.minX, y: rect.minY + max(-font.descender, 0))
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }

    private func createSession() -> Bool {
        let layout = makeLayout()
        session = OmacyEngineSession(
            configuration: engineConfiguration(),
            cols: layout.cols,
            rows: layout.rows,
            report: { [weak self] in self?.diagnostic = $0 }
        )
        lastTimestamp = nil
        finishedAt = nil
        cells.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
        if session != nil { diagnostic = nil }
        return session != nil
    }

    private func engineConfiguration() -> OmacyEngineConfiguration {
        OmacyEngineConfiguration(
            art: snapshot.art,
            initialEffect: snapshot.settings.engineEffect,
            effects: snapshot.settings.effects,
            background: snapshot.settings.backgroundRGBA
        )
    }

    private func makeLayout() -> (cols: UInt32, rows: UInt32) {
        let requestedSize = CGFloat(snapshot.settings.fontSize)
        var size = requestedSize
        if fitsArt {
            let art = OmacyLayout.artGrid(snapshot.art)
            let requestedCell = OmacyLayout.cellSize(font: OmacyFont.makeFont(size: requestedSize))
            let ratio = min(
                1,
                viewSize.width * 0.9 / (CGFloat(art.cols + 4) * requestedCell.width),
                viewSize.height * 0.9 / (CGFloat(art.rows + 4) * requestedCell.height)
            )
            size = max(0.5, requestedSize * ratio)
        }
        font = OmacyFont.makeFont(size: size)
        let layout = OmacyLayout.grid(viewSize: viewSize, scale: 1, font: font)
        return (layout.cols, layout.rows)
    }

    private func drawStaticArt(in bounds: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = snapshot.art.size(withAttributes: attributes)
        snapshot.art.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }

    private func color(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    private struct GlyphKey: Hashable {
        let scalar: UInt32
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
    }
}
