import Foundation
import CoreGraphics

/// Geometry is expressed in Accessibility coordinates: origin at the top left.
/// This model never calls macOS or changes an application window.
struct ScrollingWindowLayout {
    struct Column: Equatable, Identifiable {
        var id: Int { windows[0] }
        var windows: [Int]
        var width: CGFloat
    }

    struct Placement: Equatable {
        let windowID: Int
        let frame: CGRect
        let isParked: Bool
    }

    enum Direction: Equatable { case left, right, up, down }

    private(set) var columns: [Column] = []
    private(set) var focusedWindow: Int?
    private(set) var viewportOffset: CGFloat = 0
    var innerGap: CGFloat = 5
    var outerGap: CGFloat = 10
    var defaultWidthRatio: CGFloat = 0.49
    // Public AX cannot hide windows completely. Keep a reachable edge sliver.
    let parkingSliver: CGFloat = 6

    var windowIDs: [Int] { columns.flatMap(\.windows) }

    func location(of id: Int) -> (column: Int, row: Int)? {
        for (column, value) in columns.enumerated() {
            if let row = value.windows.firstIndex(of: id) { return (column, row) }
        }
        return nil
    }

    mutating func add(_ id: Int, viewportWidth: CGFloat, afterFocused: Bool = true) {
        guard location(of: id) == nil else { return }
        let width = max(160, (viewportWidth - 2 * outerGap) * defaultWidthRatio)
        let insertion = afterFocused
            ? focusedWindow.flatMap { location(of: $0)?.column }.map { $0 + 1 } ?? columns.count
            : columns.count
        columns.insert(Column(windows: [id], width: width), at: insertion)
        if focusedWindow == nil { focusedWindow = id }
    }

    mutating func remove(_ id: Int) {
        guard let index = location(of: id) else { return }
        columns[index.column].windows.remove(at: index.row)
        if columns[index.column].windows.isEmpty { columns.remove(at: index.column) }
        if focusedWindow == id {
            focusedWindow = columns.isEmpty ? nil : columns[min(index.column, columns.count - 1)].windows.first
        }
        if columns.isEmpty { viewportOffset = 0 }
    }

    mutating func focus(_ id: Int) {
        guard location(of: id) != nil else { return }
        focusedWindow = id
    }

    @discardableResult
    mutating func focus(_ direction: Direction) -> Int? {
        guard let id = focusedWindow, let index = location(of: id) else { return nil }
        switch direction {
        case .left, .right:
            let next = index.column + (direction == .left ? -1 : 1)
            guard columns.indices.contains(next) else { return id }
            focusedWindow = columns[next].windows[min(index.row, columns[next].windows.count - 1)]
        case .up, .down:
            let next = index.row + (direction == .up ? -1 : 1)
            guard columns[index.column].windows.indices.contains(next) else { return id }
            focusedWindow = columns[index.column].windows[next]
        }
        return focusedWindow
    }

    mutating func moveFocused(_ direction: Direction) {
        guard let id = focusedWindow, let index = location(of: id) else { return }
        switch direction {
        case .left, .right:
            let next = index.column + (direction == .left ? -1 : 1)
            guard columns.indices.contains(next) else { return }
            columns.swapAt(index.column, next)
        case .up, .down:
            let next = index.row + (direction == .up ? -1 : 1)
            guard columns[index.column].windows.indices.contains(next) else { return }
            columns[index.column].windows.swapAt(index.row, next)
        }
    }

    /// Move the focused window into the column immediately to its left.
    @discardableResult
    mutating func stackFocusedLeft() -> Bool {
        guard let id = focusedWindow, let index = location(of: id), index.column > 0 else { return false }
        columns[index.column].windows.remove(at: index.row)
        columns[index.column - 1].windows.append(id)
        if columns[index.column].windows.isEmpty { columns.remove(at: index.column) }
        return true
    }

    @discardableResult
    mutating func unstack(_ id: Int) -> Bool {
        guard let index = location(of: id), columns[index.column].windows.count > 1 else { return false }
        let width = columns[index.column].width
        columns[index.column].windows.remove(at: index.row)
        columns.insert(Column(windows: [id], width: width), at: index.column + 1)
        return true
    }

    mutating func setWidth(_ width: CGFloat, for id: Int) {
        guard width.isFinite, let index = location(of: id) else { return }
        columns[index.column].width = max(160, width)
    }

    mutating func cycleFocusedWidth(viewportWidth: CGFloat, backwards: Bool = false) {
        guard let id = focusedWindow, let index = location(of: id) else { return }
        let usable = max(160, viewportWidth - outerGap * 2)
        let presets: [CGFloat] = [0.33, 0.49, 0.66, 0.97]
        let ratio = columns[index.column].width / usable
        let next: CGFloat
        if backwards { next = presets.last(where: { $0 < ratio - 0.02 }) ?? presets.last! }
        else { next = presets.first(where: { $0 > ratio + 0.02 }) ?? presets.first! }
        columns[index.column].width = max(160, usable * next)
    }

    mutating func fillFocusedWidth(viewportWidth: CGFloat) {
        guard let id = focusedWindow else { return }
        setWidth(max(160, viewportWidth - 2 * outerGap), for: id)
    }

    /// Bring the focused column into view without changing any column widths.
    mutating func revealFocused(viewportWidth: CGFloat) {
        guard let id = focusedWindow, let index = location(of: id) else { return }
        let usable = max(1, viewportWidth - 2 * outerGap)
        let start = columns.prefix(index.column).reduce(CGFloat.zero) { $0 + $1.width + innerGap }
        let end = start + columns[index.column].width
        if start < viewportOffset { viewportOffset = start }
        else if end > viewportOffset + usable { viewportOffset = end - usable }
        // Oversized application minimum widths are anchored at their left edge.
        if columns[index.column].width > usable { viewportOffset = start }
        let total = max(0, columns.reduce(CGFloat.zero) { $0 + $1.width + innerGap } - innerGap)
        viewportOffset = min(max(0, viewportOffset), max(0, total - usable))
    }

    func placements(in screen: CGRect) -> [Placement] {
        guard screen.width > 0, screen.height > 0 else { return [] }
        let usable = screen.insetBy(dx: outerGap, dy: outerGap)
        var x = usable.minX - viewportOffset
        var output: [Placement] = []
        for column in columns {
            let height = max(1, (usable.height - CGFloat(column.windows.count - 1) * innerGap)
                             / CGFloat(column.windows.count))
            let parkedLeft = x + column.width <= screen.minX + parkingSliver
            let parkedRight = x >= screen.maxX - parkingSliver
            let actualX = parkedLeft ? screen.minX - column.width + parkingSliver
                : parkedRight ? screen.maxX - parkingSliver : x
            for (row, id) in column.windows.enumerated() {
                output.append(Placement(windowID: id,
                    frame: CGRect(x: actualX.rounded(), y: (usable.minY + CGFloat(row) * (height + innerGap)).rounded(),
                                  width: column.width.rounded(), height: height.rounded()),
                    isParked: parkedLeft || parkedRight))
            }
            x += column.width + innerGap
        }
        return output
    }
}
