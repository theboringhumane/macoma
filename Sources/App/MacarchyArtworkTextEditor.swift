import AppKit
import SwiftUI

/// Preserve long ASCII rows instead of wrapping them into a different picture.
struct MacarchyArtworkTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let editor = NSTextView(frame: .zero)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.allowsUndo = true
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.textContainerInset = NSSize(width: 12, height: 12)
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel("Custom ASCII artwork")
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? NSTextView, editor.string != text else { return }
        let selected = editor.selectedRange()
        editor.string = text
        editor.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
        }
    }
}
