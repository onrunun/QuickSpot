import AppKit
import QuickSpotCore
import SwiftUI

/// Standalone native macOS window for reviewing and safely trashing visually near-duplicate images.
struct DuplicateFinderWindowView: View {
    @ObservedObject var viewModel: DuplicateFinderViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if let message = viewModel.feedbackMessage {
                feedbackStrip(message)
                Divider()
            }
            contentArea
            Divider()
            footerBar
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("duplicates.window_title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(headerSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { viewModel.preset },
                set: { viewModel.selectPreset($0) }
            )) {
                ForEach(DuplicateThresholdPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 240)

            Button {
                viewModel.scan()
            } label: {
                Label(L10n.tr("duplicates.rescan"), systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(viewModel.isScanning)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var headerSubtitle: String {
        if viewModel.isScanning {
            return L10n.tr("duplicates.scanning")
        }
        if !viewModel.groups.isEmpty {
            return L10n.format(
                "duplicates.summary",
                viewModel.groups.count,
                DuplicateFinderViewModel.formatBytes(viewModel.totalReclaimableBytes)
            )
        }
        return L10n.tr("duplicates.subtitle")
    }

    private func feedbackStrip(_ message: String) -> some View {
        let tint: Color = viewModel.feedbackIsError ? .red : .green
        return HStack(spacing: 8) {
            Image(systemName: viewModel.feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button { viewModel.feedbackMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(tint.opacity(0.11))
    }

    @ViewBuilder
    private var contentArea: some View {
        if viewModel.isScanning {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text(L10n.tr("duplicates.scanning"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.groups.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.purple.opacity(0.75))
                Text(
                    viewModel.indexedImageCount < 2
                        ? L10n.tr("duplicates.empty.not_enough_indexed")
                        : L10n.tr("duplicates.empty.none_found")
                )
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.primary)
                Text(L10n.tr("duplicates.empty.hint"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.groups) { group in
                        duplicateGroupCard(group)
                    }
                }
                .padding(16)
            }
        }
    }

    private func duplicateGroupCard(_ group: NearDuplicateGroup) -> some View {
        let pct = Int((max(0, min(1, Double(group.averageSimilarity))) * 100).rounded())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(L10n.format("duplicates.group_similarity", "\(pct)%"), systemImage: "sparkles")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.12), in: Capsule())

                Text(L10n.format("duplicates.group_count", group.items.count))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if group.reclaimableBytes > 0 {
                    Text(L10n.format("duplicates.reclaimable", DuplicateFinderViewModel.formatBytes(group.reclaimableBytes)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(group.items) { item in
                        DuplicateImageTileView(
                            item: item,
                            isSelectedForTrash: viewModel.selectedForTrash.contains(item.id),
                            onToggle: { viewModel.toggleSelection(item) },
                            onReveal: { viewModel.revealInFinder(item) },
                            onOpen: { viewModel.openFile(item) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button(L10n.tr("duplicates.select_recommended")) {
                viewModel.selectRecommendedDuplicates()
            }
            .disabled(viewModel.groups.isEmpty)

            if !viewModel.selectedForTrash.isEmpty {
                Button(L10n.tr("duplicates.clear_selection")) {
                    viewModel.clearSelection()
                }
            }

            Spacer()

            if !viewModel.selectedForTrash.isEmpty {
                Text(DuplicateFinderViewModel.formatBytes(viewModel.selectedBytes))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.trashSelected()
            } label: {
                Label(
                    L10n.format("duplicates.trash_selected", viewModel.selectedForTrash.count),
                    systemImage: "trash"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(viewModel.selectedForTrash.isEmpty)
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}

private struct DuplicateImageTileView: View {
    let item: DuplicateImageItem
    let isSelectedForTrash: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onOpen: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .overlay {
                                Image(systemName: "photo")
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 156, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 4) {
                    if item.isRecommendedKeep {
                        Text(L10n.tr("duplicates.badge.best"))
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.88), in: Capsule())
                    }
                    Image(systemName: isSelectedForTrash ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelectedForTrash ? .red : .white.opacity(0.88))
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .padding(6)
            }

            Text(item.fileName)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(metaSummary)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(shortParent)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 2)
                Button(action: onReveal) {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("context.reveal_in_finder"))
            }
        }
        .padding(8)
        .frame(width: 172)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelectedForTrash ? Color.red.opacity(0.09) : Color.primary.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelectedForTrash ? Color.red.opacity(0.6) : Color.primary.opacity(0.08),
                    lineWidth: isSelectedForTrash ? 1.5 : 0.75
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) { onToggle() }
        .task(id: item.url) {
            thumbnail = PreviewImageCache.shared.cached(url: item.url, side: 160)
            if thumbnail == nil {
                let loaded = await PreviewImageCache.shared.loadThumbnail(
                    url: item.url,
                    side: 160,
                    scale: displayScale
                )
                guard !Task.isCancelled else { return }
                thumbnail = loaded
            }
        }
    }

    private var metaSummary: String {
        let size = DuplicateFinderViewModel.formatBytes(item.fileSize)
        if item.pixelWidth > 0 && item.pixelHeight > 0 {
            return "\(item.pixelWidth)×\(item.pixelHeight) · \(size)"
        }
        return size
    }

    private var shortParent: String {
        item.url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
