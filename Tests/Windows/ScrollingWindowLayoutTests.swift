import Foundation
import CoreGraphics

@main
struct ScrollingWindowLayoutTests {
    static var assertions = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        assertions += 1
        guard condition() else { fatalError("Line \(line): \(message)") }
    }

    static func main() {
        testIdentityResolver()
        testPreparationPriority()
        testWindowMotion()
        let screen = CGRect(x: 0, y: 25, width: 1440, height: 850)
        var model = ScrollingWindowLayout()
        model.add(1, viewportWidth: screen.width)
        let originalWidth = model.columns[0].width
        for id in 2...8 { model.add(id, viewportWidth: screen.width, afterFocused: false) }
        expect(model.columns.count == 8, "New windows must create independent columns")
        expect(model.columns.allSatisfy { $0.width == originalWidth }, "Opening windows must not squeeze existing widths")
        expect(model.columns.reduce(0) { $0 + $1.width } > screen.width * 3, "The model must extend beyond the viewport")
        expect(model.windowIDs == Array(1...8), "Initial discovery preserves spatial order")
        model.focus(8)
        model.revealFocused(viewportWidth: screen.width)
        expect(model.viewportOffset > screen.width * 2, "Focusing distant columns must scroll the viewport")
        let distant = model.placements(in: screen)
        let focused = distant.first { $0.windowID == 8 }!
        expect(focused.frame.minX >= screen.minX && focused.frame.maxX <= screen.maxX, "Focused column must be fully visible")
        expect(distant.contains { $0.isParked }, "Overflow columns must be parked, not shrunk")
        expect(distant.filter { $0.isParked }.allSatisfy { $0.frame.width == originalWidth.rounded() }, "Parking must preserve widths")
        expect(distant.filter { $0.isParked }.allSatisfy { $0.frame.intersection(screen).width >= 5 }, "Overflow must retain a reachable edge")

        model.focus(1)
        model.revealFocused(viewportWidth: screen.width)
        expect(model.viewportOffset == 0, "Returning to the first column must return to the beginning")
        model.focus(2)
        expect(model.stackFocusedLeft(), "A window must stack into its left neighbour")
        expect(model.columns[0].windows == [1, 2], "Stacked windows keep their row order")
        expect(model.columns.count == 7, "Stacking removes the empty source column")
        let stacked = model.placements(in: screen).filter { $0.windowID == 1 || $0.windowID == 2 }
        expect(stacked.count == 2 && stacked[0].frame.maxY < stacked[1].frame.minY, "Stacked windows must not overlap")
        expect(stacked[1].frame.maxY <= screen.maxY, "A vertical stack must stay within the display")
        expect(model.focus(.up) == 1, "Up focuses the previous window within a column")
        expect(model.focus(.down) == 2, "Down focuses the next window within a column")
        model.moveFocused(.up)
        expect(model.columns[0].windows == [2, 1], "Vertical movement must reorder the stack")
        expect(model.unstack(2), "A stacked window must become its own column")
        expect(model.columns[1].windows == [2], "Unstack inserts immediately to the right")
        expect(model.columns[1].width == originalWidth, "Unstack preserves the column width")

        model.focus(2)
        let neighbourWidth = model.columns[0].width
        model.cycleFocusedWidth(viewportWidth: screen.width)
        expect(model.columns[1].width > originalWidth, "Width cycling changes the selected column")
        expect(model.columns[0].width == neighbourWidth, "Width cycling must preserve neighbour widths")
        model.setWidth(1800, for: 2)
        model.revealFocused(viewportWidth: screen.width)
        expect(model.placements(in: screen).first { $0.windowID == 2 }!.frame.minX == screen.minX + model.outerGap,
               "Oversized minimum widths must keep the title bar's left edge reachable")
        model.remove(2)
        expect(model.focusedWindow != 2 && model.focusedWindow != nil, "Closing the focused window must choose a surviving window")
        model.add(1, viewportWidth: screen.width)
        expect(model.windowIDs.filter { $0 == 1 }.count == 1, "Repeated discovery must not duplicate a window")

        // Repeat varied structural edits to verify invariants through transitions.
        var seed: UInt64 = 0x4D41434152434859
        func random(_ max: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 32) % UInt64(max))
        }
        for step in 0..<600 {
            if model.windowIDs.isEmpty { model.add(step + 100, viewportWidth: screen.width) }
            let current = model.windowIDs[random(model.windowIDs.count)]
            model.focus(current)
            switch random(7) {
            case 0: model.add(step + 1000, viewportWidth: screen.width)
            case 1: model.remove(current)
            case 2: _ = model.stackFocusedLeft()
            case 3: _ = model.unstack(current)
            case 4: model.moveFocused(.left)
            case 5: model.moveFocused(.right)
            default: model.cycleFocusedWidth(viewportWidth: screen.width, backwards: random(2) == 0)
            }
            model.revealFocused(viewportWidth: screen.width)
            expect(Set(model.windowIDs).count == model.windowIDs.count, "Every window must belong to exactly one column")
            expect(model.columns.allSatisfy { !$0.windows.isEmpty && $0.width >= 160 && $0.width.isFinite }, "Columns must remain nonempty with usable widths")
            expect(model.focusedWindow == nil || model.windowIDs.contains(model.focusedWindow!), "Focus must refer to a live window")
            expect(model.viewportOffset >= 0 && model.viewportOffset.isFinite, "Viewport offset must remain valid")
            expect(model.placements(in: screen).allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 }, "Every placement must have positive dimensions")
        }
        for id in model.windowIDs { model.remove(id) }
        expect(model.columns.isEmpty && model.focusedWindow == nil && model.viewportOffset == 0, "Closing all windows resets the model")
        print("PASS: \(assertions) layout assertions; no Accessibility access or window changes.")
    }
}
