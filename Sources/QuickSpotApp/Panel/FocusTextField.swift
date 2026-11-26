import AppKit
import SwiftUI

/// Describes a programmatic focus request for the launcher search field.
struct FocusRequest: Equatable {
    let id: UUID
    let selectAll: Bool

    static func selectAll() -> FocusRequest {
        FocusRequest(id: UUID(), selectAll: true)
    }

    static func caretAtEnd() -> FocusRequest {
        FocusRequest(id: UUID(), selectAll: false)
    }
}

/// Borderless NSTextField wrapper that reliably grabs first responder and controls selection vs. caret-at-end placement.
struct FocusTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: FocusRequest

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.textColor = .labelColor
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: NSFont.systemFont(ofSize: 18, weight: .regular)
            ]
        )
        field.lineBreakMode = .byTruncatingHead
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.placeholderAttributedString?.string != placeholder {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .foregroundColor: NSColor.placeholderTextColor,
                    .font: NSFont.systemFont(ofSize: 18, weight: .regular)
                ]
            )
        }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true, field.stringValue != text {
            field.stringValue = text
        }
        if context.coordinator.lastFocusID != focusRequest.id {
            context.coordinator.lastFocusID = focusRequest.id
            let selectAll = focusRequest.selectAll
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                if window.firstResponder !== field.currentEditor() {
                    window.makeFirstResponder(field)
                }
                guard let editor = field.currentEditor() else { return }
                if selectAll {
                    editor.selectAll(nil)
                } else {
                    let end = (field.stringValue as NSString).length
                    editor.selectedRange = NSRange(location: end, length: 0)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var lastFocusID: UUID?

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Handled cleanly by the floating panel's key monitor without triggering system alert beeps.
            let intercepted: Set<Selector> = [
                #selector(NSResponder.moveUp(_:)),
                #selector(NSResponder.moveDown(_:)),
                #selector(NSResponder.insertNewline(_:)),
                #selector(NSResponder.cancelOperation(_:)),
                #selector(NSResponder.insertTab(_:))
            ]
            return intercepted.contains(commandSelector)
        }
    }
}
