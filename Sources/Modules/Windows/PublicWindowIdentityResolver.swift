import CoreGraphics

/// Pure decisions for associating public CG metadata with a live AX handle.
/// The caller owns the handle and must verify its lifetime with AX/CFEqual.
enum PublicWindowIdentityResolver {
    struct VisibleWindow {
        let number: UInt32
        let pid: Int32
        let frame: CGRect
    }

    struct Binding: Equatable {
        let number: UInt32
        let pid: Int32
    }

    static func resolve(existing: Binding?, pid: Int32, frame: CGRect, handleIsLive: Bool,
                        completeAXFrames: [CGRect?]?, visible: [VisibleWindow]) -> Binding? {
        guard handleIsLive else { return nil }
        if let existing {
            // A disappeared binding must never silently attach to a different
            // window which happens to occupy the same rectangle.
            return isVisible(existing, pid: pid, frame: frame, visible: visible) ? existing : nil
        }
        guard let completeAXFrames, completeAXFrames.allSatisfy({ $0 != nil }) else { return nil }
        let axMatches = completeAXFrames.compactMap { $0 }.filter { close($0, frame) }
        let cgMatches = visible.filter { $0.pid == pid && close($0.frame, frame) }
        guard axMatches.count == 1, cgMatches.count == 1, let match = cgMatches.first else { return nil }
        return Binding(number: match.number, pid: pid)
    }

    static func isVisible(_ binding: Binding, pid: Int32, frame: CGRect, visible: [VisibleWindow]) -> Bool {
        guard binding.pid == pid else { return false }
        let matches = visible.filter { $0.number == binding.number }
        return matches.count == 1 && matches[0].pid == pid && close(matches[0].frame, frame)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4
            && abs(a.width - b.width) <= 4 && abs(a.height - b.height) <= 4
    }
}
