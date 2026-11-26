import QuickSpotCore
import SwiftUI

/// Root launcher UI combining the search bar, filter/toast indicators, split-pane result list, and live preview.
struct SearchBarAndListView: View {
    @ObservedObject var viewModel: PanelViewModel
    let onExecuteIndex: (Int) -> Void
    let onReveal: () -> Void
    let onQuickLook: () -> Void
    let onOpenSettings: () -> Void
    let onHideWithoutReturnFocus: () -> Void
    let onClose: () -> Void

    private var hasNonEmptyQuery: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inlineToastMessage: String? {
        guard let message = viewModel.toastMessage, !isLongBannerToast(message) else { return nil }
        return message
    }

    private var bannerToastMessage: String? {
        guard let message = viewModel.toastMessage, isLongBannerToast(message) else { return nil }
        return message
    }

    var body: some View {
        let _ = viewModel.languageToken
        VStack(spacing: 0) {
            searchHeader
            if let banner = bannerToastMessage {
                Divider().opacity(0.35)
                feedbackBanner(banner)
            }
            if !viewModel.items.isEmpty {
                Divider().opacity(0.45)
                splitResultsPane
                Divider().opacity(0.35)
                shortcutsFooter
            } else if hasNonEmptyQuery || viewModel.similarAnchor != nil {
                Divider().opacity(0.45)
                emptyOrSearchingStatusRow
            }
        }
        .frame(width: PanelController.panelWidth)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
        )
        .overlay {
            if viewModel.isActionPaletteVisible, let selected = viewModel.selectedItem {
                ActionPaletteOverlay(
                    targetTitle: selected.title,
                    actions: viewModel.actionPaletteItems,
                    selectedIndex: viewModel.actionPaletteIndex,
                    pendingConfirmationID: viewModel.actionPaletteConfirmID,
                    onSelect: { viewModel.selectActionPalette(at: $0) },
                    onExecute: { idx in
                        let shouldHide = viewModel.executeActionPalette(
                            at: idx,
                            onReveal: {
                                let revealed = viewModel.revealSelected()
                                if revealed { onHideWithoutReturnFocus() }
                                return false
                            },
                            onQuickLook: onQuickLook
                        )
                        if shouldHide { onHideWithoutReturnFocus() }
                    },
                    onDismiss: { viewModel.closeActionPalette() }
                )
            }
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.similarAnchor != nil ? "sparkles" : "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(viewModel.similarAnchor != nil ? Color.accentColor : .secondary)
                .frame(width: 24)

            if let anchor = viewModel.similarAnchor {
                SimilarAnchorChipView(
                    anchor: anchor,
                    clipboardImage: viewModel.clipboardAnchorImage,
                    scope: viewModel.similarScope,
                    showScopeToggle: viewModel.canSwitchSimilarScope,
                    onScopeChange: { viewModel.setSimilarScope($0) },
                    onDismiss: { viewModel.exitSimilarMode() }
                )
            }

            FocusTextField(
                text: $viewModel.query,
                placeholder: viewModel.similarAnchor != nil
                    ? L10n.tr("panel.similar_refine_placeholder")
                    : L10n.tr("panel.search_placeholder"),
                focusRequest: viewModel.focusRequest
            )
            .frame(height: 28)

            if let badge = viewModel.activeFilterBadge, viewModel.similarAnchor == nil {
                Text(badge)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .fixedSize()
            }

            if viewModel.isSearchingFiles {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.85)
                    .help(
                        viewModel.similarAnchor != nil
                            ? L10n.tr("panel.similar.searching")
                            : L10n.tr("panel.searching_files")
                    )
            }

            if let toast = inlineToastMessage {
                let tint = toastTint(for: viewModel.toastStyle)
                Text(toast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.14), in: Capsule())
                    .fixedSize()
            }

            if !viewModel.query.isEmpty || viewModel.similarAnchor != nil {
                Button { viewModel.clearQuery() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("panel.clear_search_help"))
            }

            PanelHeaderControls(
                progress: viewModel.indexProgress,
                semanticProgress: viewModel.semanticProgress,
                onOpenSettings: onOpenSettings
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private func feedbackBanner(_ message: String) -> some View {
        let tint = toastTint(for: viewModel.toastStyle)
        let icon = viewModel.toastStyle == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { viewModel.clearToast() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    private var emptyOrSearchingStatusRow: some View {
        HStack(spacing: 10) {
            if viewModel.isSearchingFiles {
                ProgressView()
                    .controlSize(.small)
                Text(
                    viewModel.similarAnchor != nil
                        ? L10n.tr("panel.similar.searching")
                        : L10n.tr("panel.searching_files")
                )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: viewModel.similarAnchor != nil ? "sparkles" : "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(viewModel.similarAnchor != nil ? Color.accentColor.opacity(0.8) : .secondary)
                Text(viewModel.emptyResultMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(L10n.tr("panel.esc_clear"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
    }

    private var splitResultsPane: some View {
        HStack(spacing: 0) {
            resultsList.frame(width: PanelController.listWidth)
            Divider().opacity(0.45)
            Group {
                if let selected = viewModel.selectedItem {
                    let canRemoveBG = selected.previewURL.map { $0.isFileURL && VisionTextExtractor.isSupportedImage($0) } ?? false
                    PreviewPaneView(
                        item: selected,
                        fullOCRText: viewModel.selectedFullOCRText,
                        smartEntities: viewModel.selectedSmartEntities,
                        canFindSimilar: viewModel.selectedSimilarityKind != nil,
                        canRemoveBackground: canRemoveBG,
                        isRemovingBackground: viewModel.isRemovingBackground,
                        isPendingConfirmation: viewModel.pendingConfirmationID == selected.id,
                        heldModifier: viewModel.heldModifier,
                        alternateActionTitle: viewModel.alternateAction?.title,
                        onOpen: { onExecuteIndex(viewModel.selectedIndex) },
                        onAlternateAction: {
                            if viewModel.executeAlternateAction() { onHideWithoutReturnFocus() }
                        },
                        onFindSimilar: { viewModel.findSimilarForSelected() },
                        onRemoveBackground: { viewModel.removeBackgroundAndCopySelected() },
                        onActivateEntity: { entity in
                            if viewModel.activateSmartEntity(entity) { onHideWithoutReturnFocus() }
                        },
                        onCopyEntity: { viewModel.copySmartEntity($0) },
                        onEnterFolder: { _ = viewModel.autocompleteWithTab() },
                        onReveal: onReveal,
                        onQuickLook: onQuickLook,
                        onCopy: { viewModel.copySelected() },
                        onCopyOCRText: { viewModel.copySelectedOCRText() },
                        onToggleActions: { viewModel.toggleActionPalette() }
                    )
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: 390)
    }

    private var resultsList: some View {
        let labels = viewModel.items.map { viewModel.sectionLabel(for: $0) }
        let showHeaders = shouldDisplaySectionHeaders(for: labels)

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 2) {
                            if showHeaders && (index == 0 || labels[index] != labels[index - 1]) {
                                sectionHeader(labels[index], isFirst: index == 0)
                            }
                            ResultRowView(
                                item: item,
                                isSelected: index == viewModel.selectedIndex,
                                shortcutIndex: index < 9 ? index + 1 : nil,
                                isPendingConfirmation: viewModel.pendingConfirmationID == item.id,
                                isCommandHeld: viewModel.heldModifier == .command
                            )
                            .overlay { rowOverlay(index: index, item: item) }
                        }
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: viewModel.selectedIndex) { _, _ in
                if let item = viewModel.selectedItem { proxy.scrollTo(item.id) }
            }
        }
    }

    private func sectionHeader(_ title: String, isFirst: Bool) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, isFirst ? 2 : 8)
            .padding(.bottom, 2)
    }

    private func shouldDisplaySectionHeaders(for labels: [String]) -> Bool {
        guard labels.count >= 2 else { return false }
        let distinct = Set(labels)
        guard distinct.count >= 2 else { return false }
        var runs = 1
        for idx in 1..<labels.count where labels[idx] != labels[idx - 1] {
            runs += 1
        }
        return runs <= 5
    }

    private func rowOverlay(index: Int, item: SearchItem) -> some View {
        let fileURL = (item.previewURL?.isFileURL == true) ? item.previewURL : nil
        let isSupportedImage = fileURL.map { VisionTextExtractor.isSupportedImage($0) } ?? false
        return RowInteractionOverlay(
            fileURL: fileURL,
            openTitle: item.primaryActionTitle,
            canFindSimilar: { viewModel.similarityKind(for: item) != nil },
            canRemoveBackground: isSupportedImage,
            onSelect: { viewModel.select(at: index) },
            onOpen: { onExecuteIndex(index) },
            onFindSimilar: {
                viewModel.select(at: index)
                viewModel.findSimilarForSelected()
            },
            onRemoveBackground: {
                viewModel.select(at: index)
                viewModel.removeBackgroundAndCopySelected()
            },
            onReveal: { viewModel.select(at: index); onReveal() },
            onQuickLook: { viewModel.select(at: index); onQuickLook() },
            onCopy: { viewModel.select(at: index); viewModel.copySelected() },
            onCopyPath: { viewModel.select(at: index); viewModel.copySelectedPath() }
        )
    }

    private var activeFooterHint: String {
        switch viewModel.heldModifier {
        case .command:
            return L10n.tr("panel.footer.cmd_held")
        case .option:
            if let alt = viewModel.alternateAction {
                return L10n.format("panel.footer.opt_held", alt.title)
            }
            return viewModel.selectedItem?.footerShortcutHint ?? L10n.tr("panel.footer.default")
        case .none:
            return viewModel.selectedItem?.footerShortcutHint ?? L10n.tr("panel.footer.default")
        }
    }

    private var shortcutsFooter: some View {
        let isModifierActive = viewModel.heldModifier != .none
        return HStack(spacing: 10) {
            Text(activeFooterHint)
                .foregroundStyle(isModifierActive ? .secondary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(L10n.tr("panel.footer.prefixes"))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .animation(.easeOut(duration: 0.12), value: viewModel.heldModifier)
    }

    private func isLongBannerToast(_ message: String) -> Bool {
        viewModel.toastStyle == .error || message.count > 44
    }

    private func toastTint(for style: ToastStyle) -> Color {
        switch style {
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
