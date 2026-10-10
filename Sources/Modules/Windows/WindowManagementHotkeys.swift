import Carbon

enum WindowManagementCommand: Int, CaseIterable {
    case focusLeft = 1, focusRight, focusUp, focusDown
    case moveLeft, moveRight, moveUp, moveDown
    case narrower, wider, fullWidth, stack, unstack, pause
}

/// Registers discrete shortcuts; it never taps or records the global key stream.
final class WindowManagementHotkeys {
    struct Binding {
        let command: WindowManagementCommand
        let keyCode: UInt32
        let shifted: Bool
        let label: String
    }

    static let bindings: [Binding] = [
        Binding(command: .focusLeft, keyCode: UInt32(kVK_LeftArrow), shifted: false, label: "⌃⌥⌘←"),
        Binding(command: .focusRight, keyCode: UInt32(kVK_RightArrow), shifted: false, label: "⌃⌥⌘→"),
        Binding(command: .focusUp, keyCode: UInt32(kVK_UpArrow), shifted: false, label: "⌃⌥⌘↑"),
        Binding(command: .focusDown, keyCode: UInt32(kVK_DownArrow), shifted: false, label: "⌃⌥⌘↓"),
        Binding(command: .moveLeft, keyCode: UInt32(kVK_LeftArrow), shifted: true, label: "⌃⌥⌘⇧←"),
        Binding(command: .moveRight, keyCode: UInt32(kVK_RightArrow), shifted: true, label: "⌃⌥⌘⇧→"),
        Binding(command: .moveUp, keyCode: UInt32(kVK_UpArrow), shifted: true, label: "⌃⌥⌘⇧↑"),
        Binding(command: .moveDown, keyCode: UInt32(kVK_DownArrow), shifted: true, label: "⌃⌥⌘⇧↓"),
        Binding(command: .narrower, keyCode: UInt32(kVK_ANSI_LeftBracket), shifted: false, label: "⌃⌥⌘["),
        Binding(command: .wider, keyCode: UInt32(kVK_ANSI_RightBracket), shifted: false, label: "⌃⌥⌘]"),
        Binding(command: .fullWidth, keyCode: UInt32(kVK_ANSI_F), shifted: false, label: "⌃⌥⌘F"),
        Binding(command: .stack, keyCode: UInt32(kVK_ANSI_S), shifted: false, label: "⌃⌥⌘S"),
        Binding(command: .unstack, keyCode: UInt32(kVK_ANSI_U), shifted: false, label: "⌃⌥⌘U"),
        Binding(command: .pause, keyCode: UInt32(kVK_ANSI_P), shifted: false, label: "⌃⌥⌘P")
    ]

    var onCommand: ((WindowManagementCommand) -> Void)?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x4D415743 // MAWC

    /// Returns a visible error and rolls back every registration on conflict.
    func register() -> String? {
        unregister()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x4D415743,
                  let command = WindowManagementCommand(rawValue: Int(id.id)) else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<WindowManagementHotkeys>.fromOpaque(context).takeUnretainedValue()
            owner.onCommand?(command)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return "Could not register the shortcut handler (\(status))." }
        for binding in Self.bindings {
            let modifiers = UInt32(controlKey | optionKey | cmdKey | (binding.shifted ? shiftKey : 0))
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(binding.command.rawValue))
            let result = RegisterEventHotKey(binding.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else {
                unregister()
                return "Shortcut \(binding.label) is unavailable (\(result)). Turn off keyboard shortcuts or free that combination, then enable again."
            }
            references.append(reference)
        }
        return nil
    }

    func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { unregister() }
}
