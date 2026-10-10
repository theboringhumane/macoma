import AppKit
import ApplicationServices

/// Intentionally has no Enable, permission request, observer or frame-write path.
@main
struct ReadOnlyDiscovery {
    static func main() throws {
        let trusted = AXIsProcessTrusted()
        var report: [String: Any] = ["accessibilityGranted": trusted,
            "permissionRequested": false, "windowsMoved": false, "displayCount": NSScreen.screens.count]
        if trusted, let screen = NSScreen.screens.first {
            let adapter = PublicWindowAccessibility()
            let frame = CGRect(x: screen.frame.minX, y: 0, width: screen.frame.width, height: screen.frame.height)
            let result = adapter.discover(screenFrame: frame)
            report["eligibleWindowCount"] = result.windows.count
            report["skippedWindowCount"] = result.skipped
            report["discoveryLimitReached"] = result.limitReached
            // Report counts only. Window titles and app names remain private.
            report["applicationCount"] = Set(result.windows.map(\.pid)).count
        } else {
            report["discoveryStatus"] = trusted ? "No display available" : "Skipped: existing Accessibility permission is required"
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
