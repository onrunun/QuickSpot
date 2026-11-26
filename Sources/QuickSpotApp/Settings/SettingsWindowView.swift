import QuickSpotCore
import SwiftUI

/// Native macOS sidebar-driven Settings & Indexing window.
struct SettingsWindowView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var hoveredTab: SettingsTab?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(width: 0.75)
            detailPane
        }
        .frame(width: 640, height: 480)
        .id(viewModel.appLanguage)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandHeader
                .padding(.top, 36)
                .padding(.horizontal, 14)

            VStack(spacing: 3) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarButton(for: tab)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Text(L10n.tr("settings.sidebar.local_badge"))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: 176, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(SettingsSidebarBackdrop())
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: BrandIcon.appIconImage(pixels: 96))
                .resizable()
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.16), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("QuickSpot")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(liveDotColor)
                        .frame(width: 6, height: 6)
                    Text(liveSummaryLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func sidebarButton(for tab: SettingsTab) -> some View {
        let isSelected = viewModel.selectedTab == tab
        let isHovered = hoveredTab == tab
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                viewModel.selectedTab = tab
            }
        } label: {
            HStack(spacing: 9) {
                SettingsIconBadge(symbol: tab.symbol, tint: tab.badgeTint)
                Text(tab.title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.18)
                            : (isHovered ? Color.primary.opacity(0.05) : Color.clear)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
        }
    }

    private var detailPane: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                Text(viewModel.selectedTab.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                switch viewModel.selectedTab {
                case .indexing:
                    SettingsIndexingTabView(viewModel: viewModel)
                case .folders:
                    SettingsFoldersSectionView(viewModel: viewModel)
                case .general:
                    SettingsGeneralTabView(viewModel: viewModel)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var liveDotColor: Color {
        if !viewModel.settings.isOCREnabled && !viewModel.semanticSettings.isEnabled { return .secondary }
        if isIndexingActive { return .blue }
        if case .paused = viewModel.progress.state { return .orange }
        if case .paused = viewModel.semanticProgress.state { return .orange }
        return .green
    }

    private var liveSummaryLabel: String {
        if !viewModel.settings.isOCREnabled && !viewModel.semanticSettings.isEnabled {
            return L10n.tr("menu.indexing.disabled")
        }
        if case .indexing(let d, let t) = viewModel.progress.state { return "OCR \(d)/\(t)" }
        if case .indexing(let d, let t) = viewModel.semanticProgress.state { return "AI \(d)/\(t)" }
        if isIndexingActive { return L10n.tr("panel.ocr_scanning") }
        if case .paused = viewModel.progress.state { return L10n.tr("panel.ocr_paused_badge") }
        if case .paused = viewModel.semanticProgress.state { return L10n.tr("panel.ocr_paused_badge") }
        return L10n.tr("settings.ocr.ready")
    }

    private var isIndexingActive: Bool {
        if case .scanning = viewModel.progress.state { return true }
        if case .indexing = viewModel.progress.state { return true }
        if case .scanning = viewModel.semanticProgress.state { return true }
        if case .indexing = viewModel.semanticProgress.state { return true }
        return false
    }
}
