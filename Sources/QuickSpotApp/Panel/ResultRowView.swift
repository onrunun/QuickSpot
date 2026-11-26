import AppKit
import QuickSpotCore
import SwiftUI

/// Caches NSWorkspace file/app icons with a bounded limit to keep typing and scrolling completely stutter-free.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 200
    }

    func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 28, height: 28)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Renders one compact result row with thumbnails, folder Tab cue, confirmation badge, and ⌘1..⌘9 shortcuts.
struct ResultRowView: View {
    let item: SearchItem
    let isSelected: Bool
    let shortcutIndex: Int?
    let isPendingConfirmation: Bool
    let isCommandHeld: Bool

    @State private var thumbnail: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(spacing: 10) {
            iconView
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            trailingAccessory
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowHighlightColor)
        )
        .contentShape(Rectangle())
        .task(id: item.id) {
            thumbnail = nil
            guard item.category == .file,
                  let url = item.previewURL,
                  url.isFileURL,
                  url.pathExtension.lowercased() != "app" else { return }

            if let cached = PreviewImageCache.shared.cached(url: url, side: 32) {
                thumbnail = cached
                return
            }
            let fetched = await PreviewImageCache.shared.loadThumbnail(url: url, side: 32, scale: scale)
            guard !Task.isCancelled else { return }
            thumbnail = fetched
        }
    }

    private var rowHighlightColor: Color {
        if isPendingConfirmation {
            return Color.orange.opacity(0.24)
        }
        return isSelected ? Color.accentColor.opacity(0.24) : Color.clear
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        HStack(spacing: 4) {
            if item.requiresConfirmation && isPendingConfirmation {
                Text(L10n.tr("row.press_again"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
            } else if item.requiresConfirmation && isSelected {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(L10n.tr("row.requires_confirmation_help"))
            } else if item.category == .folder && isSelected {
                HStack(spacing: 2) {
                    Text("⇥")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                .help(L10n.tr("row.enter_folder_help"))
            }

            if let shortcutIndex {
                Text("⌘\(shortcutIndex)")
                    .font(.system(size: 10.5, weight: isCommandHeld ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isCommandHeld ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        isCommandHeld ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                    .animation(.easeOut(duration: 0.12), value: isCommandHeld)
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let path = item.iconPath {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: AppIconCache.shared.icon(for: path))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
        } else if let symbol = item.sfSymbol {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(badgeGradient)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
        } else if item.category == .folder {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.blue.opacity(0.16))
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.blue)
                }
        }
    }

    private var badgeGradient: some ShapeStyle {
        if item.requiresConfirmation {
            return AnyShapeStyle(Color.red.gradient)
        }
        switch item.action {
        case .runTerminal: return AnyShapeStyle(Color.black.gradient)
        case .copyText: return AnyShapeStyle(Color.orange.gradient)
        case .systemCommand, .openSettings: return AnyShapeStyle(Color.purple.gradient)
        case .openURL: return AnyShapeStyle(Color.blue.gradient)
        case .openFile: return AnyShapeStyle(Color.gray.gradient)
        }
    }
}
