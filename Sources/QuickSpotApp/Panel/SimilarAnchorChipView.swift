import AppKit
import QuickSpotCore
import SwiftUI

/// Compact pill anchored inside the search bar showing the active file or clipboard image reference
/// plus an optional cross-modal scope toggle (Images / Documents / All) during "Find Similar" mode.
struct SimilarAnchorChipView: View {
    let anchor: SimilarityAnchor
    let clipboardImage: NSImage?
    let scope: SimilaritySearchScope
    let showScopeToggle: Bool
    let onScopeChange: (SimilaritySearchScope) -> Void
    let onDismiss: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                chipThumbnail
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text(L10n.format("panel.similar.chip", anchor.title))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: showScopeToggle ? 128 : 185, alignment: .leading)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L10n.tr("panel.similar.clear_help"))
            }
            .padding(.leading, 4)
            .padding(.trailing, 7)
            .padding(.vertical, 3.5)
            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if showScopeToggle {
                scopeToggleStrip
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .task(id: anchor.id) {
            guard let url = anchor.url else {
                thumbnail = nil
                return
            }
            thumbnail = PreviewImageCache.shared.cached(url: url, side: 20)
            if thumbnail == nil {
                let loaded = await PreviewImageCache.shared.loadThumbnail(
                    url: url,
                    side: 20,
                    scale: displayScale
                )
                guard !Task.isCancelled else { return }
                thumbnail = loaded
            }
        }
    }

    private var scopeToggleStrip: some View {
        HStack(spacing: 1) {
            scopeButton(.images, symbol: "photo", helpKey: "panel.similar.scope.images")
            scopeButton(.documents, symbol: "doc.text", helpKey: "panel.similar.scope.docs")
            scopeButton(.all, symbol: "square.stack", helpKey: "panel.similar.scope.all")
        }
        .padding(2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func scopeButton(
        _ target: SimilaritySearchScope,
        symbol: String,
        helpKey: String
    ) -> some View {
        let isActive = scope == target
        return Button {
            onScopeChange(target)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .frame(width: 22, height: 18)
                .background(
                    isActive ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(L10n.tr(helpKey))
    }

    @ViewBuilder
    private var chipThumbnail: some View {
        if anchor.isClipboardImage, let clipImg = clipboardImage {
            Image(nsImage: clipImg)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let image = thumbnail {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let url = anchor.url {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
        }
    }
}
