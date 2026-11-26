import QuickSpotCore
import SwiftUI

/// Unified Indexing & AI tab combining live pipeline status, Vision OCR, and EmbeddingGemma 2 controls.
struct SettingsIndexingTabView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            overviewBanner
            ocrSection
            semanticSection
        }
    }

    private var overviewBanner: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                statusBadgeIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(unifiedStatusTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    if let activeRatio = activeProgressRatio {
                        ProgressView(value: activeRatio)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(isSemanticActive ? .purple : .accentColor)
                            .frame(maxWidth: 210)
                    } else if isScanning {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(maxWidth: 160)
                    }
                }
                Spacer(minLength: 8)
                Button(L10n.tr("settings.ocr.index_now")) {
                    viewModel.triggerCoordinatedIndexNow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled((!viewModel.settings.isOCREnabled && !viewModel.semanticSettings.isEnabled) || isBusy)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            SettingsRowDivider()

            HStack(spacing: 0) {
                metricColumn(value: viewModel.progress.indexedCount, label: L10n.tr("settings.metric.ocr"))
                verticalHairline
                metricColumn(value: viewModel.semanticProgress.embeddedCount, label: L10n.tr("settings.metric.visual"))
                verticalHairline
                metricColumn(value: viewModel.semanticProgress.embeddedDocumentCount, label: L10n.tr("settings.metric.docs"))
            }
            .padding(.vertical, 9)
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.085), lineWidth: 0.75)
        )
    }

    private var ocrSection: some View {
        SettingsSectionGroup(L10n.tr("settings.ocr.section")) {
            SettingsToggleRow(
                L10n.tr("settings.ocr.enable_toggle"),
                subtitle: L10n.format("settings.ocr.stats", viewModel.progress.indexedCount, viewModel.progress.withTextCount),
                isOn: Binding(
                    get: { viewModel.settings.isOCREnabled },
                    set: { viewModel.toggleOCREnabled($0) }
                )
            )
            SettingsRowDivider()
            SettingsToggleRow(
                L10n.tr("settings.ocr.battery_toggle"),
                isOn: Binding(
                    get: { viewModel.settings.indexOnBattery },
                    set: { viewModel.toggleIndexOnBattery($0) }
                )
            )
            SettingsRowDivider()
            indexingPaceRow
            SettingsRowDivider()
            HStack(spacing: 8) {
                Button(L10n.tr("settings.ocr.rescan_empty")) { viewModel.reindexEmptyImages() }
                    .disabled(!viewModel.settings.isOCREnabled)
                    .help(L10n.tr("settings.ocr.rescan_empty_help"))
                Button(L10n.tr("settings.ocr.rebuild")) { viewModel.rebuildIndex() }
                    .disabled(!viewModel.settings.isOCREnabled)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private var indexingPaceRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(L10n.tr("settings.indexing.speed_label"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { viewModel.settings.indexingMode },
                    set: { viewModel.selectIndexingMode($0) }
                )) {
                    Text(L10n.tr("settings.indexing.mode_quiet")).tag(IndexingMode.quiet)
                    Text(L10n.tr("settings.indexing.mode_fast")).tag(IndexingMode.fast)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 170)
            }

            Text(
                viewModel.settings.indexingMode == .quiet
                    ? L10n.tr("settings.indexing.hint_quiet")
                    : L10n.tr("settings.indexing.hint_fast")
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var semanticSection: some View {
        SettingsSectionGroup(L10n.tr("settings.semantic.section")) {
            SettingsToggleRow(
                L10n.tr("settings.semantic.enable_toggle"),
                isOn: Binding(
                    get: { viewModel.semanticSettings.isEnabled },
                    set: { viewModel.toggleSemanticEnabled($0) }
                )
            )
            SettingsRowDivider()
            semanticModelRow
            SettingsRowDivider()
            HStack(spacing: 8) {
                if !viewModel.semanticProgress.modelStatus.isReady {
                    Button(L10n.tr("settings.semantic.get_models")) {
                        viewModel.openSemanticModelDownloadPage()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(L10n.tr("settings.semantic.choose_folder")) {
                    viewModel.selectSemanticModelsFolderViaPanel()
                }
                Button(L10n.tr("settings.ocr.rebuild")) {
                    viewModel.rebuildSemanticIndex()
                }
                .disabled(!viewModel.semanticSettings.isEnabled || !viewModel.semanticProgress.modelStatus.isReady)
                Button(L10n.tr("settings.semantic.find_duplicates")) {
                    viewModel.openDuplicateFinder()
                }
                .disabled(viewModel.semanticProgress.embeddedCount < 2)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private var semanticModelRow: some View {
        let shortDir = viewModel.semanticProgress.modelStatus.directory.path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let isReady = viewModel.semanticProgress.modelStatus.isReady
        return HStack(spacing: 8) {
            Image(systemName: isReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(isReady ? .purple : .orange)
            Text(
                isReady
                    ? L10n.format("settings.semantic.models_ready_in", shortDir)
                    : L10n.format("settings.semantic.models_hint", shortDir)
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func metricColumn(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalHairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 0.75, height: 26)
    }

    private var statusBadgeIcon: some View {
        let (symbol, color): (String, Color) = {
            if !viewModel.settings.isOCREnabled && !viewModel.semanticSettings.isEnabled {
                return ("minus.circle.fill", .secondary)
            }
            if isBusy {
                return ("arrow.triangle.2.circlepath.circle.fill", isSemanticActive ? .purple : .blue)
            }
            if case .paused = viewModel.progress.state { return ("pause.circle.fill", .orange) }
            if case .paused = viewModel.semanticProgress.state { return ("pause.circle.fill", .orange) }
            return ("checkmark.circle.fill", .green)
        }()
        return Image(systemName: symbol)
            .font(.system(size: 18))
            .foregroundStyle(color)
    }

    private var unifiedStatusTitle: String {
        if !viewModel.settings.isOCREnabled && !viewModel.semanticSettings.isEnabled {
            return L10n.tr("menu.indexing.disabled")
        }
        if viewModel.settings.isOCREnabled {
            switch viewModel.progress.state {
            case .scanning: return L10n.tr("menu.indexing.scanning")
            case .indexing(let d, let t): return L10n.format("menu.indexing.ocr_progress", d, t)
            case .paused, .idle: break
            }
        }
        if viewModel.semanticSettings.isEnabled {
            switch viewModel.semanticProgress.state {
            case .scanning: return L10n.tr("menu.indexing.scanning")
            case .indexing(let d, let t): return L10n.format("menu.indexing.semantic_progress", d, t)
            case .paused, .idle, .modelsMissing: break
            }
        }
        if viewModel.settings.isOCREnabled, case .paused(let reason) = viewModel.progress.state {
            return L10n.format("menu.indexing.paused", reason)
        }
        if viewModel.semanticSettings.isEnabled, case .paused(let reason) = viewModel.semanticProgress.state {
            return L10n.format("menu.indexing.paused", reason)
        }
        return L10n.tr("settings.ocr.ready")
    }

    private var isSemanticActive: Bool {
        if case .indexing = viewModel.semanticProgress.state { return true }
        if case .scanning = viewModel.semanticProgress.state { return true }
        return false
    }

    private var isScanning: Bool {
        if case .scanning = viewModel.progress.state { return true }
        if case .scanning = viewModel.semanticProgress.state { return true }
        return false
    }

    private var activeProgressRatio: Double? {
        if case .indexing(let d, let t) = viewModel.progress.state, t > 0 {
            return min(1.0, max(0.0, Double(d) / Double(t)))
        }
        if case .indexing(let d, let t) = viewModel.semanticProgress.state, t > 0 {
            return min(1.0, max(0.0, Double(d) / Double(t)))
        }
        return nil
    }

    private var isBusy: Bool { isScanning || activeProgressRatio != nil }
}
