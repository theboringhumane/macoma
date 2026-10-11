import AppKit
import Foundation
import ScreenSaver

/// Loads the packaged .saver through NSPrincipalClass, just as the public host
/// does. The default test uses hidden windows and never changes system settings.
@main
@MainActor
struct SaverHostSmoke {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard let bundleIndex = arguments.firstIndex(of: "--bundle"), arguments.indices.contains(bundleIndex + 1) else {
            throw Failure("Usage: SaverHostSmoke --bundle /path/Macarchy.saver [--output /path/evidence] [--visible]")
        }
        let bundleURL = URL(fileURLWithPath: arguments[bundleIndex + 1]).standardizedFileURL
        guard let bundle = Bundle(url: bundleURL) else { throw Failure("Cannot open saver bundle at \(bundleURL.path)") }
        let outputURL: URL?
        if let outputIndex = arguments.firstIndex(of: "--output"), arguments.indices.contains(outputIndex + 1) {
            outputURL = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL!, withIntermediateDirectories: true)
        } else {
            outputURL = nil
        }
        _ = NSApplication.shared
        try bundle.loadAndReturnError()
        guard let principal = bundle.principalClass as? ScreenSaverView.Type else {
            throw Failure("NSPrincipalClass is not a ScreenSaverView")
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 210), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if arguments.contains("--visible") { window.orderFrontRegardless() }
        weak var releasedView: ScreenSaverView?
        var previewEvidence: [String: Any] = [:]
        try autoreleasepool {
            guard let saver = principal.init(frame: window.contentLayoutRect, isPreview: true) else {
                throw Failure("Saver preview initializer returned nil")
            }
            releasedView = saver
            window.contentView = saver
            saver.startAnimation()
            var signatures = Set<UInt64>()
            for index in 0..<70 {
                pump(1.0 / 30.0)
                saver.animateOneFrame()
                let value = diagnostics(saver)
                if let signature = value["softwareFrameSignature"] as? NSNumber { signatures.insert(signature.uint64Value) }
                if index == 10, let outputURL { try snapshot(saver, at: outputURL.appendingPathComponent("preview-first.png")) }
                if index == 65, let outputURL { try snapshot(saver, at: outputURL.appendingPathComponent("preview-later.png")) }
            }
            let running = diagnostics(saver)
            let previewVisible = window.isVisible && window.occlusionState.contains(.visible)
            if !previewVisible {
                try require(running["backend"] as? String == "stopped", "Occluded system preview kept a renderer attached")
                try require(running["engineActive"] as? Bool == false, "Occluded system preview kept an active engine")
                try require(saver.hasConfigureSheet && saver.configureSheet != nil, "Saver configuration sheet is unavailable")
                saver.stopAnimation()
                window.contentView = NSView(frame: window.contentLayoutRect)
                previewEvidence = running
                previewEvidence["occludedIdle"] = true
            } else {
                try require(running["backend"] as? String == "software", "System preview did not select the AppKit renderer")
                try require(running["engineActive"] as? Bool == true, "System preview has no live effect engine")
                try require(running["sharedDisplaySynchronization"] as? Bool == false, "Saver preview joined a shared display barrier")
                try require(signatures.count > 1, "System preview emitted no changing effect frames")
                try require(saver.hasConfigureSheet && saver.configureSheet != nil, "Saver configuration sheet is unavailable")

                let workspace = NSWorkspace.shared.notificationCenter
                workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
                try require(diagnostics(saver)["engineActive"] as? Bool == false, "Display sleep did not release the engine")
                workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
                saver.animateOneFrame()
                try require(diagnostics(saver)["engineActive"] as? Bool == true, "Display wake did not restart the requested animation")

                saver.stopAnimation()
                let stopped = diagnostics(saver)
                try require(stopped["engineActive"] as? Bool == false, "stopAnimation left a live engine")
                saver.setFrameSize(NSSize(width: 420, height: 240))
                saver.layoutSubtreeIfNeeded()
                saver.animateOneFrame()
                workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
                try require(diagnostics(saver)["backend"] as? String == "stopped", "Resize or wake restarted a stopped saver")

                saver.startAnimation()
                saver.animateOneFrame()
                try require(diagnostics(saver)["engineActive"] as? Bool == true, "A stopped saver could not restart")
                window.contentView = NSView(frame: window.contentLayoutRect)
                try require(diagnostics(saver)["engineActive"] as? Bool == false, "Detaching the view left a live engine")
                window.contentView = saver
                saver.animateOneFrame()
                try require(diagnostics(saver)["engineActive"] as? Bool == true, "Reattaching an active saver failed to resume")
                saver.stopAnimation()
                window.contentView = NSView(frame: window.contentLayoutRect)
                previewEvidence = running
                previewEvidence["uniqueFrameSignatures"] = signatures.count
            }
        }
        pump(0.1)
        try require(releasedView == nil, "Saver view retained itself after stop and removal")
        window.close()

        var evidence: [String: Any] = [
            "bundle": bundleURL.path,
            "principalClass": NSStringFromClass(principal),
            "preview": previewEvidence,
            "lifecycle": outputURL != nil && previewEvidence["uniqueFrameSignatures"] != nil
                ? ["stop", "restart", "resizeWhileStopped", "detach", "reattach", "displaySleep", "displayWake", "release"]
                : ["occludedIdle", "stop", "release"],
            "systemSettingsChanged": false,
            "visibleWindow": arguments.contains("--visible")
        ]
        if arguments.contains("--visible") {
            evidence["metal"] = try visibleMetalSmoke(principal)
        }
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        if let outputURL { try data.write(to: outputURL.appendingPathComponent("saver-host-smoke.json"), options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func visibleMetalSmoke(_ principal: ScreenSaverView.Type) throws -> [String: Any] {
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Macarchy host validation"
        guard let saver = principal.init(frame: NSRect(origin: .zero, size: frame.size), isPreview: false) else {
            throw Failure("Full-screen initializer returned nil")
        }
        let hostContent = NSView(frame: NSRect(origin: .zero, size: frame.size))
        hostContent.autoresizingMask = [.width, .height]
        saver.autoresizingMask = [.width, .height]
        hostContent.addSubview(saver)
        window.contentView = hostContent
        defer {
            saver.stopAnimation()
            window.contentView = NSView()
            window.orderOut(nil)
            window.close()
        }
        window.orderFrontRegardless()
        saver.startAnimation()
        for _ in 0..<90 {
            pump(1.0 / 30.0)
            saver.animateOneFrame()
        }
        let running = diagnostics(saver)
        try require(running["backend"] as? String == "metal", "Full-screen host did not select Metal")
        try require(running["sharedDisplaySynchronization"] as? Bool == false, "Full-screen saver joined a shared display barrier")
        try require((running["metalFrameCount"] as? NSNumber)?.uint64Value ?? 0 > 1, "Metal host presented no frames")
        let initialColumns = (running["gridColumns"] as? NSNumber)?.uint32Value ?? 0
        let initialRows = (running["gridRows"] as? NSNumber)?.uint32Value ?? 0
        try require(initialColumns > 1 && initialRows > 1, "Full-screen saver has no display-sized grid")
        saver.setFrameSize(NSSize(width: 480, height: 320))
        for _ in 0..<15 {
            pump(1.0 / 30.0)
            saver.animateOneFrame()
        }
        let resized = diagnostics(saver)
        let resizedColumns = (resized["gridColumns"] as? NSNumber)?.uint32Value ?? 0
        let resizedRows = (resized["gridRows"] as? NSNumber)?.uint32Value ?? 0
        try require(resizedColumns > 1 && resizedRows > 1, "Live resize lost the saver grid")
        try require(resizedColumns != initialColumns || resizedRows != initialRows,
            "Live resize did not update the engine grid")
        saver.setFrameSize(frame.size)
        for _ in 0..<15 {
            pump(1.0 / 30.0)
            saver.animateOneFrame()
        }
        let restored = diagnostics(saver)
        try require(restored["backend"] as? String == "metal", "Returning to full screen did not restore Metal rendering")
        try require((restored["gridColumns"] as? NSNumber)?.uint32Value == initialColumns
            && (restored["gridRows"] as? NSNumber)?.uint32Value == initialRows,
            "Returning to full-screen size did not restore the engine grid")
        saver.stopAnimation()
        let count = diagnostics(saver)["metalFrameCount"] as? NSNumber
        pump(0.15)
        saver.animateOneFrame()
        try require(diagnostics(saver)["engineActive"] as? Bool == false, "Metal engine remained active after stop")
        try require(diagnostics(saver)["metalFrameCount"] as? NSNumber == count, "Metal frame callbacks continued after stop")
        return ["initial": running, "resized": resized, "restored": restored]
    }

    private static func diagnostics(_ saver: ScreenSaverView) -> [String: Any] {
        saver.value(forKey: "diagnostics") as? [String: Any] ?? [:]
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static func snapshot(_ view: NSView, at url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure("Could not create a preview bitmap")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure("Could not encode a preview screenshot")
        }
        try data.write(to: url, options: .atomic)
    }
}
