import Foundation

// A saver runs inside Apple's host, so Bundle.main is the host, not our bundle.
private final class MacarchyResourceAnchor: NSObject {}

enum MacarchyResources {
    static var bundle = Bundle(for: MacarchyResourceAnchor.self)
}
