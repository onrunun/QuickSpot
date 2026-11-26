import AppKit
import QuickSpotCore
import SwiftUI

/// Renders file content previews: monospaced code/text snippets, Quick Look/PDF/video images, or app/file icons.
struct FileContentPreviewView: View {
    let item: SearchItem
    let url: URL
    let size: CGSize
    let onOpen: () -> Void

    @State private var image: NSImage?
    @State private var snippetLines: [String]?
    @State private var loaded = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let snippetLines {
                snippetBox(lines: snippetLines)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onOpen)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onOpen)
            } else {
                fallbackIconBox
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onOpen)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: size.height)
        .task(id: url) {
            image = nil
            snippetLines = nil
            loaded = false

            if FileMetadataInspector.isTextOrCode(url) {
                let targetURL = url
                let lines = await Task.detached(priority: .userInitiated) {
                    FileMetadataInspector.loadTextSnippet(targetURL)
                }.value
                guard !Task.isCancelled else { return }
                snippetLines = lines
                loaded = true
                return
            }

            if url.pathExtension.lowercased() != "app" {
                let side = max(size.width, size.height)
                if let cached = PreviewImageCache.shared.cached(url: url, side: side) {
                    image = cached
                    loaded = true
                    return
                }
                let fetched = await PreviewImageCache.shared.loadPreview(url: url, side: side, scale: scale)
                guard !Task.isCancelled else { return }
                image = fetched
            }
            loaded = true
        }
    }

    private func snippetBox(lines: [String]) -> some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .trailing)
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.92))
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    private var fallbackIconBox: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .opacity(loaded || url.pathExtension.lowercased() == "app" ? 1 : 0.45)
            }
    }
}
