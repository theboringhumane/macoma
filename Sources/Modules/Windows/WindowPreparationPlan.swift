import CoreGraphics

/// Keep navigation's destination ahead of background windows in a bounded scan.
struct WindowPreparationPlan {
    let orderedIDs: [Int]
    let requiredFocusID: Int?

    init(focusedID: Int?, requiresFocus: Bool, frames: [Int: CGRect], targets: [Int: CGRect], viewport: CGRect) {
        requiredFocusID = requiresFocus ? focusedID : nil
        func priority(_ id: Int) -> Int {
            if id == focusedID { return 0 }
            let frame = frames[id]!
            let changed = targets[id].map { $0 != frame } ?? false
            let visible = frame.intersection(viewport).width > 8
            if changed && visible { return 1 }
            return changed ? 2 : 3
        }
        orderedIDs = frames.keys.sorted { lhs, rhs in
            let left = priority(lhs), right = priority(rhs)
            return left == right ? lhs < rhs : left < right
        }
    }

    func canApply(verifiedIDs: Set<Int>) -> Bool {
        requiredFocusID.map { verifiedIDs.contains($0) } ?? true
    }
}
