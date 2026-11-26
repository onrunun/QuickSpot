import AppKit
import QuickSpotCore
import SwiftUI

/// Native first-launch setup window letting users choose between alongside-Spotlight and replace-Spotlight modes.
struct OnboardingWindowView: View {
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var prefs: OnboardingPreferencesState
    let onToggleLaunchAtLogin: (Bool) -> Void
    let onSelectLanguage: (AppLanguage) -> Void
    let onCompleteAndOpen: () -> Void
    let onSwitchToSafeAndOpen: () -> Void

    @State private var selectedMode: HotkeyUsageMode

    init(
        hotkeyManager: HotkeyManager,
        prefs: OnboardingPreferencesState,
        onToggleLaunchAtLogin: @escaping (Bool) -> Void,
        onSelectLanguage: @escaping (AppLanguage) -> Void,
        onCompleteAndOpen: @escaping () -> Void,
        onSwitchToSafeAndOpen: @escaping () -> Void
    ) {
        self.hotkeyManager = hotkeyManager
        self.prefs = prefs
        self.onToggleLaunchAtLogin = onToggleLaunchAtLogin
        self.onSelectLanguage = onSelectLanguage
        self.onCompleteAndOpen = onCompleteAndOpen
        self.onSwitchToSafeAndOpen = onSwitchToSafeAndOpen
        self._selectedMode = State(initialValue: hotkeyManager.currentShortcut.usageMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection
            modeCardsSection
            statusStrip
            Divider().opacity(0.45)
            footerSection
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .id(prefs.appLanguage)
        .onChange(of: hotkeyManager.currentShortcut) { _, newValue in
            selectedMode = newValue.usageMode
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: BrandIcon.appIconImage(pixels: 128))
                .resizable()
                .frame(width: 52, height: 52)
                .shadow(color: .black.opacity(0.16), radius: 6, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("onboarding.title"))
                    .font(.system(size: 19, weight: .semibold))
                Text(L10n.tr("onboarding.subtitle"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(AppLanguage.allCases, id: \.self) { language in
                    Button {
                        onSelectLanguage(language)
                    } label: {
                        if language == prefs.appLanguage {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L10n.tr("settings.general.language_label"))
        }
    }

    private var modeCardsSection: some View {
        VStack(spacing: 10) {
            alongsideCard
            replaceSpotlightCard
        }
    }

    private var alongsideCard: some View {
        let isSelected = selectedMode == .alongsideSpotlight
        return modeCard(
            isSelected: isSelected,
            icon: "square.on.square",
            title: L10n.tr("onboarding.mode.alongside.title"),
            badgeText: hotkeyManager.isSpotlightShortcutEnabled
                ? L10n.tr("onboarding.badge.recommended")
                : L10n.tr("onboarding.badge.no_conflict"),
            badgeColor: .accentColor,
            subtitle: L10n.tr("onboarding.mode.alongside.subtitle"),
            onSelect: {
                selectedMode = .alongsideSpotlight
                if hotkeyManager.currentShortcut == .cmdSpace {
                    hotkeyManager.switchToConflictFreeAlternative()
                }
            }
        ) {
            if isSelected {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        presetChip(.optionSpace)
                        presetChip(.optionCmdSpace)
                        ShortcutRecorderButton(
                            shortcut: hotkeyManager.currentShortcut,
                            isCustomActive: hotkeyManager.currentShortcut.matchingPreset == nil,
                            onBeginRecording: { hotkeyManager.suspendForRecording() },
                            onEndRecording: { hotkeyManager.resumeAfterRecording() },
                            onRecord: { shortcut in
                                hotkeyManager.select(shortcut, persist: true)
                            }
                        )
                    }

                    if let conflict = hotkeyManager.activeConflict {
                        HotkeyConflictBannerView(
                            shortcut: hotkeyManager.currentShortcut,
                            conflict: conflict,
                            onOpenKeyboardSettings: { hotkeyManager.openKeyboardSettings() },
                            onSwitchToAlternative: { hotkeyManager.switchToConflictFreeAlternative() }
                        )
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var replaceSpotlightCard: some View {
        let isSelected = selectedMode == .replaceSpotlight
        let spotlightFree = !hotkeyManager.isSpotlightShortcutEnabled
        return modeCard(
            isSelected: isSelected,
            icon: "bolt.circle.fill",
            title: L10n.tr("onboarding.mode.replace.title"),
            badgeText: spotlightFree
                ? L10n.tr("onboarding.badge.ready")
                : L10n.tr("onboarding.badge.one_step"),
            badgeColor: spotlightFree ? .green : .orange,
            subtitle: L10n.tr("onboarding.mode.replace.subtitle"),
            onSelect: {
                selectedMode = .replaceSpotlight
                hotkeyManager.selectPreset(.cmdSpace)
            }
        ) {
            if isSelected {
                if let conflict = hotkeyManager.activeConflict {
                    HotkeyConflictBannerView(
                        shortcut: hotkeyManager.currentShortcut,
                        conflict: conflict,
                        onOpenKeyboardSettings: { hotkeyManager.openKeyboardSettings() },
                        onSwitchToAlternative: { hotkeyManager.switchToConflictFreeAlternative() }
                    )
                    .padding(.top, 4)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12.5))
                        Text(L10n.tr("onboarding.replace.ready_note"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func modeCard<Extra: View>(
        isSelected: Bool,
        icon: String,
        title: String,
        badgeText: String,
        badgeColor: Color,
        subtitle: String,
        onSelect: @escaping () -> Void,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            Text(title)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text(badgeText)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(badgeColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(badgeColor.opacity(0.12), in: Capsule())
                        }
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            extra()
                .padding(.leading, 25)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
    }

    private func presetChip(_ preset: HotkeyPreset) -> some View {
        HotkeyPresetChip(
            preset: preset,
            isSelected: hotkeyManager.currentShortcut == preset.shortcut,
            onSelect: { hotkeyManager.selectPreset(preset) }
        )
    }

    private var statusStrip: some View {
        HStack(alignment: .center, spacing: 9) {
            Circle()
                .fill(hotkeyManager.activeConflict == nil ? Color.green : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                if hotkeyManager.activeConflict == nil {
                    Text(L10n.format("onboarding.status.active", hotkeyManager.currentShortcut.displayString))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                } else {
                    Text(L10n.format("onboarding.status.waiting", hotkeyManager.currentShortcut.displayString))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                }

                Text(L10n.tr("onboarding.change_anytime"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footerSection: some View {
        HStack(spacing: 12) {
            Toggle(L10n.tr("settings.general.launch_at_login"), isOn: Binding(
                get: { prefs.launchAtLogin },
                set: { onToggleLaunchAtLogin($0) }
            ))
            .font(.system(size: 12))

            Spacer()

            if hotkeyManager.activeConflict != nil {
                Button(L10n.tr("onboarding.button.use_safe_and_start")) {
                    onSwitchToSafeAndOpen()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(L10n.tr("onboarding.button.open_quickspot")) {
                    onCompleteAndOpen()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
