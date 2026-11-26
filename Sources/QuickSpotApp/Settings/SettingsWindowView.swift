import QuickSpotCore
import SwiftUI

/// Native macOS Settings window covering Vision OCR indexing, watched folders, battery policy, and general options.
struct SettingsWindowView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ocrSection
            foldersSection
            generalSection
        }
        .padding(18)
        .frame(width: 520)
        .frame(minHeight: 530)
        .id(viewModel.appLanguage)
    }

    private var ocrSection: some View {
        GroupBox(L10n.tr("settings.ocr.section")) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L10n.tr("settings.ocr.enable_toggle"), isOn: Binding(
                    get: { viewModel.settings.isOCREnabled },
                    set: { viewModel.toggleOCREnabled($0) }
                ))

                HStack(spacing: 8) {
                    statusIcon
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if case .indexing(let done, let total) = viewModel.progress.state, total > 0 {
                        ProgressView(value: Double(done), total: Double(total))
                            .frame(width: 130)
                    } else if case .scanning = viewModel.progress.state {
                        ProgressView().controlSize(.small)
                    }
                }

                Text(L10n.format("settings.ocr.stats", viewModel.progress.indexedCount, viewModel.progress.withTextCount))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                Toggle(L10n.tr("settings.ocr.battery_toggle"), isOn: Binding(
                    get: { viewModel.settings.indexOnBattery },
                    set: { viewModel.toggleIndexOnBattery($0) }
                ))
                .font(.system(size: 12.5))

                HStack(spacing: 8) {
                    Button(L10n.tr("settings.ocr.index_now")) { viewModel.triggerIndexNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.settings.isOCREnabled)
                    Button(L10n.tr("settings.ocr.rescan_empty")) { viewModel.reindexEmptyImages() }
                        .disabled(!viewModel.settings.isOCREnabled)
                        .help(L10n.tr("settings.ocr.rescan_empty_help"))
                    Button(L10n.tr("settings.ocr.rebuild")) { viewModel.rebuildIndex() }
                        .disabled(!viewModel.settings.isOCREnabled)
                }
                .controlSize(.small)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var foldersSection: some View {
        GroupBox(L10n.tr("settings.folders.section")) {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.settings.folders.isEmpty {
                    Text(L10n.tr("settings.folders.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 110)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(viewModel.settings.folders, id: \.self) { folderRow($0) }
                        }
                    }
                    .frame(height: 125)
                }
                Button(L10n.tr("settings.folders.add_button")) { viewModel.addFolderViaPanel() }
                    .controlSize(.small)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func folderRow(_ folder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            Text(folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button { viewModel.removeFolder(folder) } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("settings.folders.remove_help"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private var generalSection: some View {
        GroupBox(L10n.tr("settings.general.section")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(L10n.tr("settings.general.hotkey_label"), selection: Binding(
                    get: { viewModel.hotkeyPreset },
                    set: { viewModel.selectHotkey($0) }
                )) {
                    ForEach(HotkeyPreset.allCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)

                Picker(L10n.tr("settings.general.language_label"), selection: Binding(
                    get: { viewModel.appLanguage },
                    set: { viewModel.selectLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)

                Toggle(L10n.tr("settings.general.launch_at_login"), isOn: Binding(
                    get: { viewModel.launchAtLogin },
                    set: { viewModel.toggleLaunchAtLogin($0) }
                ))

                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    Toggle(L10n.tr("settings.clipboard.toggle"), isOn: Binding(
                        get: { viewModel.clipboardEnabled },
                        set: { viewModel.toggleClipboardEnabled($0) }
                    ))
                    Spacer()
                    Text("\(viewModel.clipboardCount)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button(L10n.tr("settings.clipboard.clear")) { viewModel.clearClipboardHistory() }
                        .controlSize(.small)
                        .disabled(viewModel.clipboardCount == 0)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusIcon: some View {
        switch viewModel.progress.state {
        case .idle:
            return Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .scanning, .indexing:
            return Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(.blue)
        case .paused:
            return Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        }
    }

    private var statusText: String {
        if !viewModel.settings.isOCREnabled { return L10n.tr("settings.ocr.disabled") }
        switch viewModel.progress.state {
        case .idle: return L10n.tr("settings.ocr.ready")
        case .scanning: return L10n.tr("settings.ocr.scanning")
        case .indexing(let done, let total): return L10n.format("settings.ocr.indexing", done, total)
        case .paused(let reason): return L10n.format("settings.ocr.paused", reason)
        }
    }
}
