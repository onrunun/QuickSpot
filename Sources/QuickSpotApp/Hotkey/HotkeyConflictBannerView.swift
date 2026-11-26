import QuickSpotCore
import SwiftUI

/// Inline native macOS warning card guiding the user through resolving Spotlight or system hotkey conflicts.
struct HotkeyConflictBannerView: View {
    let shortcut: HotkeyShortcut
    let conflict: HotkeyConflict
    let onOpenKeyboardSettings: () -> Void
    let onSwitchToAlternative: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(conflict.localizedTitle(for: shortcut))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text(conflict.localizedDetail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if conflict.isSpotlightConflict {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("hotkey.conflict.spotlight.step1"))
                    Text(L10n.tr("hotkey.conflict.spotlight.step2"))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 21)
            }

            HStack(spacing: 8) {
                if conflict.canBeResolvedInKeyboardSettings {
                    Button(L10n.tr("hotkey.conflict.open_keyboard_settings")) {
                        onOpenKeyboardSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }

                if shortcut != .optionSpace {
                    Button(L10n.tr("hotkey.conflict.use_option_space")) {
                        onSwitchToAlternative()
                    }
                    .controlSize(.small)
                }

                Spacer(minLength: 4)

                if conflict.canBeResolvedInKeyboardSettings {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L10n.tr("hotkey.conflict.auto_detecting"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 21)
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.32), lineWidth: 1)
        )
    }
}
