import AppKit
import QuickSpotCore
import SwiftUI

/// Interactive macOS shortcut recorder button capturing any modifier + key combo with live validation.
struct ShortcutRecorderButton: View {
    let shortcut: HotkeyShortcut
    let isCustomActive: Bool
    let onBeginRecording: () -> Void
    let onEndRecording: () -> Void
    let onRecord: (HotkeyShortcut) -> Void

    @State private var isRecording = false
    @State private var validationHint: String?
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if isRecording { stopRecording() } else { startRecording() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isRecording ? "record.circle.fill" : "keyboard")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(isRecording ? Color.accentColor : .secondary)

                        Text(buttonTitle)
                            .font(.system(size: 12, weight: isCustomActive || isRecording ? .semibold : .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(borderColor, lineWidth: isRecording ? 1.5 : 1)
                    )
                }
                .buttonStyle(.plain)

                if isRecording {
                    Button {
                        stopRecording()
                    } label: {
                        Text(L10n.tr("hotkey.recorder.cancel"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if let validationHint {
                Text(validationHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
        .onDisappear { stopRecording() }
    }

    private var buttonTitle: String {
        if isRecording {
            return L10n.tr("hotkey.recorder.prompt")
        }
        if isCustomActive {
            return L10n.format("hotkey.recorder.custom_active", shortcut.displayString)
        }
        return L10n.tr("hotkey.recorder.record")
    }

    private var backgroundStyle: Color {
        if isRecording { return Color.accentColor.opacity(0.14) }
        if isCustomActive { return Color.accentColor.opacity(0.12) }
        return Color.primary.opacity(0.05)
    }

    private var borderColor: Color {
        if isRecording { return Color.accentColor }
        if isCustomActive { return Color.accentColor.opacity(0.55) }
        return Color.primary.opacity(0.14)
    }

    private func startRecording() {
        validationHint = nil
        isRecording = true
        onBeginRecording()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordedEvent(event)
        }
    }

    private func stopRecording() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        validationHint = nil
        onEndRecording()
    }

    private func handleRecordedEvent(_ event: NSEvent) -> NSEvent? {
        // Escape cancels recording cleanly without modifying the active shortcut.
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            stopRecording()
            return nil
        }

        let carbonMods = Self.carbonModifiers(from: event.modifierFlags)
        let candidate = HotkeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
        guard candidate.isValid else {
            validationHint = L10n.tr("hotkey.recorder.invalid")
            return nil
        }

        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        isRecording = false
        validationHint = nil
        onEndRecording()
        onRecord(candidate)
        return nil
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= CarbonModifierMask.command }
        if flags.contains(.shift) { mask |= CarbonModifierMask.shift }
        if flags.contains(.option) { mask |= CarbonModifierMask.option }
        if flags.contains(.control) { mask |= CarbonModifierMask.control }
        return mask
    }
}

/// Reusable selectable chip for built-in global hotkey presets (`⌥Space`, `⌘Space`, `⌥⌘Space`).
struct HotkeyPresetChip: View {
    let preset: HotkeyPreset
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(preset.shortLabel)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .monospacedDigit()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.14),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .help(preset.title)
    }
}
