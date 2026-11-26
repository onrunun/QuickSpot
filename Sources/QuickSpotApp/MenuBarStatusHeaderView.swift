import AppKit
import QuickSpotCore
import SwiftUI

/// Live native-vibrancy status header embedded at the top of QuickSpot's menu bar dropdown.
struct MenuBarStatusHeaderView: View {
    @ObservedObject var viewModel: SettingsViewModel
    let onOpenSettings: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpenSettings) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(nsImage: BrandIcon.appIconImage(pixels: 64))
                        .resizable()
                        .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("QuickSpot")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer(minLength: 4)
                            statusPill
                        }
                        Text(subtitleText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                if let activeRatio = activeProgressRatio {
                    ProgressView(value: activeRatio)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(isSemanticActive ? .purple : .accentColor)
                } else if isScanning {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                } else {
                    metricsStrip
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: 276, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .id(viewModel.appLanguage)
    }

    private var metricsStrip: some View {
        HStack(spacing: 0) {
            metricCell(
                value: viewModel.progress.indexedCount,
                label: L10n.tr("menu.metric.ocr")
            )
            divider
            metricCell(
                value: viewModel.semanticProgress.embeddedCount,
                label: L10n.tr("menu.metric.visual")
            )
            divider
            metricCell(
                value: viewModel.semanticProgress.embeddedDocumentCount,
                label: L10n.tr("menu.metric.docs")
            )
        }
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func metricCell(value: Int, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value.formatted())
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 0.5, height: 20)
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusBadgeLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor.opacity(0.14), in: Capsule())
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
        if case .indexing(let done, let total) = viewModel.progress.state, total > 0 {
            return min(1.0, max(0.0, Double(done) / Double(total)))
        }
        if case .indexing(let done, let total) = viewModel.semanticProgress.state, total > 0 {
            return min(1.0, max(0.0, Double(done) / Double(total)))
        }
        return nil
    }

    private var statusColor: Color {
        if !viewModel.settings.isOCREnabled && !viewModel.semanticSettings.isEnabled {
            return .secondary
        }
        if activeProgressRatio != nil || isScanning {
            return isSemanticActive ? .purple : .blue
        }
        if case .paused = viewModel.progress.state { return .orange }
        if case .paused = viewModel.semanticProgress.state { return .orange }
        return .green
    }

    private var statusBadgeLabel: String {
        if !viewModel.settings.isOCREnabled && !viewModel.semanticSettings.isEnabled {
            return L10n.tr("menu.indexing.disabled")
        }
        if activeProgressRatio != nil || isScanning {
            return L10n.tr("panel.ocr_scanning").replacingOccurrences(of: "…", with: "")
        }
        if case .paused = viewModel.progress.state {
            return L10n.tr("panel.ocr_paused_badge")
        }
        if case .paused = viewModel.semanticProgress.state {
            return L10n.tr("panel.ocr_paused_badge")
        }
        return L10n.tr("settings.ocr.ready")
    }

    private var subtitleText: String {
        if viewModel.settings.isOCREnabled {
            switch viewModel.progress.state {
            case .scanning: return L10n.tr("menu.indexing.scanning")
            case .indexing(let done, let total): return L10n.format("menu.indexing.ocr_progress", done, total)
            case .paused(let reason): return L10n.format("menu.indexing.paused", reason)
            case .idle: break
            }
        }
        if viewModel.semanticSettings.isEnabled {
            switch viewModel.semanticProgress.state {
            case .scanning: return L10n.tr("menu.indexing.scanning")
            case .indexing(let done, let total): return L10n.format("menu.indexing.semantic_progress", done, total)
            case .paused(let reason): return L10n.format("menu.indexing.paused", reason)
            case .modelsMissing: return L10n.tr("settings.semantic.models_missing")
            case .idle: break
            }
        }
        return L10n.tr("settings.sidebar.local_badge")
    }
}
