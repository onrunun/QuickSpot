import QuickSpotCore
import SwiftUI

/// General settings tab covering global hotkey configuration, language, launch at login, and clipboard history.
struct SettingsGeneralTabView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hotkeySection
            preferencesSection
        }
    }

    private var hotkeySection: some View {
        SettingsSectionGroup(L10n.tr("settings.general.hotkey_label")) {
            HStack(spacing: 8) {
                hotkeyStatusBadge
                Button(L10n.tr("settings.hotkey.setup_guide")) {
                    viewModel.openSetupGuide()
                }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                        HotkeyPresetChip(
                            preset: preset,
                            isSelected: viewModel.hotkeyShortcut == preset.shortcut,
                            onSelect: { viewModel.selectHotkeyPreset(preset) }
                        )
                    }

                    ShortcutRecorderButton(
                        shortcut: viewModel.hotkeyShortcut,
                        isCustomActive: viewModel.hotkeyShortcut.matchingPreset == nil,
                        onBeginRecording: { viewModel.suspendHotkeyForRecording() },
                        onEndRecording: { viewModel.resumeHotkeyAfterRecording() },
                        onRecord: { viewModel.selectCustomShortcut($0) }
                    )
                }

                if let conflict = viewModel.hotkeyConflict {
                    HotkeyConflictBannerView(
                        shortcut: viewModel.hotkeyShortcut,
                        conflict: conflict,
                        onOpenKeyboardSettings: { viewModel.openKeyboardSettings() },
                        onSwitchToAlternative: { viewModel.switchToConflictFreeAlternative() }
                    )
                }
            }
            .padding(12)
        }
    }

    private var preferencesSection: some View {
        SettingsSectionGroup(L10n.tr("settings.general.section")) {
            HStack(spacing: 12) {
                Text(L10n.tr("settings.general.language_label"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { viewModel.appLanguage },
                    set: { viewModel.selectLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 170)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            SettingsRowDivider()

            SettingsToggleRow(
                L10n.tr("settings.general.launch_at_login"),
                isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.toggleLaunchAtLogin($0) }
                )
            )

            SettingsRowDivider()

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.tr("settings.clipboard.toggle"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(L10n.format("settings.clipboard.saved_count", viewModel.clipboardCount))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(L10n.tr("settings.clipboard.clear")) {
                    viewModel.clearClipboardHistory()
                }
                .controlSize(.small)
                .disabled(viewModel.clipboardCount == 0)

                Toggle("", isOn: Binding(
                    get: { viewModel.clipboardEnabled },
                    set: { viewModel.toggleClipboardEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var hotkeyStatusBadge: some View {
        let hasConflict = viewModel.hotkeyConflict != nil
        let badgeColor: Color = hasConflict ? .orange : .green
        let label: String
        if hasConflict {
            label = L10n.tr("settings.hotkey.status_conflict")
        } else if viewModel.hotkeyShortcut == .cmdSpace {
            label = L10n.tr("settings.hotkey.status_replacing")
        } else {
            label = L10n.tr("settings.hotkey.status_alongside")
        }

        return HStack(spacing: 4) {
            Circle()
                .fill(badgeColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hasConflict ? .orange : .secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.12), in: Capsule())
    }
}
