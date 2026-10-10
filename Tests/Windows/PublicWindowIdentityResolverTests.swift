import CoreGraphics

extension ScrollingWindowLayoutTests {
    static func testPreparationPriority() {
        let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
        let left = CGRect(x: 10, y: 10, width: 680, height: 880)
        let right = CGRect(x: 710, y: 10, width: 680, height: 880)
        let parked = CGRect(x: -674, y: 10, width: 680, height: 880)
        let plan = WindowPreparationPlan(focusedID: 99, requiresFocus: true,
            frames: [1: left, 2: parked, 3: right, 99: parked],
            targets: [1: left, 2: left, 3: left, 99: right], viewport: screen)
        expect(plan.orderedIDs.first == 99, "The requested focus target must be prepared before earlier background IDs")
        expect(plan.orderedIDs == [99, 3, 2, 1], "Changed visible windows follow the target before parked or unchanged windows")
        expect(!plan.canApply(verifiedIDs: [1, 2, 3]), "A partial scan missing the destination must not move other columns")
        expect(plan.canApply(verifiedIDs: [99, 3]), "A verified destination can navigate without an unresponsive background window")
        let resize = WindowPreparationPlan(focusedID: 99, requiresFocus: false,
            frames: [1: left, 99: parked], targets: [1: right, 99: parked], viewport: screen)
        expect(resize.canApply(verifiedIDs: [1]), "A non-navigation layout command can apply its verified windows")
    }

    static func testIdentityResolver() {
        typealias Resolver = PublicWindowIdentityResolver
        let frame = CGRect(x: 20, y: 40, width: 700, height: 800)
        let parked = CGRect(x: -694, y: 40, width: 700, height: 800)
        let first = Resolver.VisibleWindow(number: 10, pid: 100, frame: frame)
        let binding = Resolver.resolve(existing: nil, pid: 100, frame: frame, handleIsLive: true,
            completeAXFrames: [frame], visible: [first])
        expect(binding == Resolver.Binding(number: 10, pid: 100), "A unique initial AX/CG match must bind its public ID")

        expect(Resolver.resolve(existing: nil, pid: 100, frame: frame, handleIsLive: true,
            completeAXFrames: [frame, frame], visible: [first]) == nil,
            "An identical AX window on another Space must prevent initial binding")
        let duplicateGeometry = [first, Resolver.VisibleWindow(number: 11, pid: 100, frame: frame)]
        expect(Resolver.resolve(existing: nil, pid: 100, frame: frame, handleIsLive: true,
            completeAXFrames: [frame], visible: duplicateGeometry) == nil,
            "Ambiguous CG geometry must not create an identity")
        expect(Resolver.resolve(existing: nil, pid: 100, frame: frame, handleIsLive: true,
            completeAXFrames: nil, visible: [first]) == nil,
            "A partial AX scan must not create an identity")
        expect(Resolver.resolve(existing: nil, pid: 100, frame: frame, handleIsLive: true,
            completeAXFrames: [frame, nil], visible: [first]) == nil,
            "Unreadable AX geometry must not establish uniqueness")

        let parkedWindows = [Resolver.VisibleWindow(number: 10, pid: 100, frame: parked),
                             Resolver.VisibleWindow(number: 11, pid: 100, frame: parked),
                             Resolver.VisibleWindow(number: 12, pid: 100, frame: parked)]
        expect(Resolver.resolve(existing: binding, pid: 100, frame: parked, handleIsLive: true,
            completeAXFrames: [parked, parked, parked], visible: parkedWindows) == binding,
            "Known live identities must survive identical same-app parked frames")
        let secondBinding = Resolver.Binding(number: 11, pid: 100)
        expect(Resolver.resolve(existing: secondBinding, pid: 100, frame: parked, handleIsLive: true,
            completeAXFrames: [parked, parked, parked], visible: parkedWindows) == secondBinding,
            "Identical parked windows must retain separate public IDs")
        expect(Resolver.resolve(existing: binding, pid: 100, frame: parked, handleIsLive: false,
            completeAXFrames: [parked], visible: parkedWindows) == nil,
            "A dead AX handle must not reuse its old public binding")

        let replacement = Resolver.VisibleWindow(number: 20, pid: 100, frame: frame)
        expect(Resolver.resolve(existing: binding, pid: 100, frame: frame, handleIsLive: true,
            completeAXFrames: [frame], visible: [replacement]) == nil,
            "A missing public ID must not silently rebind to a new same-geometry window")
        expect(!Resolver.isVisible(binding!, pid: 100, frame: frame, visible: []),
            "An off-Space or hidden CG ID must not authorize a write")
        expect(!Resolver.isVisible(binding!, pid: 100, frame: frame,
            visible: [Resolver.VisibleWindow(number: 10, pid: 200, frame: frame)]),
            "Reusing a public CG ID in another process must not authorize a write")
        expect(!Resolver.isVisible(binding!, pid: 200, frame: frame, visible: [first]),
            "A mismatched AX process must not reuse a cached binding")
        expect(!Resolver.isVisible(binding!, pid: 100, frame: parked, visible: [first]),
            "The visible CG frame must agree with the current AX frame")
        expect(!Resolver.isVisible(binding!, pid: 100, frame: frame, visible: [first, first]),
            "A malformed duplicate CG ID must not authorize a write")
        expect(Resolver.isVisible(binding!, pid: 100, frame: parked, visible: parkedWindows),
            "A valid bound ID must remain usable after movement changes its geometry")
    }
}
