import AppKit
import QuickSpotCore
import SwiftUI

/// Right-side live preview pane displaying media/snippet/action cards, Finder metadata, caution pills, and actions.
struct PreviewPaneView: View {
    let item: SearchItem
    let fullOCRText: String?
    let isPendingConfirmation: Bool
    let onOpen: () -> Void
    let onEnterFolder: () -> Void
    let onReveal: () -> Void
    let onQuickLook: () -> Void
    let onCopy: () -> Void
    let onCopyOCRText: () -> Void
    let onToggleActions: () -> Void

    @State private var metadataLine = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            previewMedia
                .frame(height: mediaHeight)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let url = item.previewURL, url.isFileURL {
                    Button(action: onReveal) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 10.5))
                            Text(item.subtitle).lineLimit(1).truncationMode(.head)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("context.reveal_in_finder"))

                    if !metadataLine.isEmpty {
                        Text(metadataLine)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(item.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if item.requiresConfirmation {
                cautionPill
            }

            if item.matchSource != .clipboard, let snippet = item.matchedSnippet, !snippet.isEmpty {
                matchedSnippetBox(snippet)
            }

            Spacer(minLength: 6)

            actionButtonsRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.previewURL) {
            metadataLine = ""
            guard let url = item.previewURL, url.isFileURL else { return }
            let details = await Task.detached(priority: .userInitiated) {
                FileMetadataInspector.inspect(url).detailsLine
            }.value
            guard !Task.isCancelled else { return }
            metadataLine = details
        }
    }

    private var hasMatchedSnippet: Bool {
        item.matchSource != .clipboard && item.matchedSnippet?.isEmpty == false
    }

    private var mediaHeight: CGFloat {
        if hasMatchedSnippet { return 162 }
        if item.requiresConfirmation { return 178 }
        return 212
    }

    private var snippetHeaderTitle: String {
        if item.previewURL?.pathExtension.lowercased() == "pdf" {
            return L10n.tr("preview.snippet.pdf")
        }
        if item.matchSource == .fileContent {
            return L10n.tr("preview.snippet.file")
        }
        return L10n.tr("preview.snippet.image")
    }

    private var snippetIconName: String {
        if item.matchSource == .fileContent || item.previewURL?.pathExtension.lowercased() == "pdf" {
            return "doc.text.magnifyingglass"
        }
        return "doc.text.viewfinder"
    }

    private var cautionPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(
                isPendingConfirmation
                    ? L10n.tr("preview.caution.pending")
                    : L10n.tr("preview.caution.required")
            )
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.orange)
            .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Color.orange.opacity(isPendingConfirmation ? 0.18 : 0.11),
            in: Capsule()
        )
    }

    private func matchedSnippetBox(_ snippet: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: snippetIconName)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(snippetHeaderTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actionButtonsRow: some View {
        HStack(spacing: 6) {
            Button(isPendingConfirmation ? L10n.tr("preview.action.confirm_and_run") : item.primaryActionTitle, action: onOpen)
                .buttonStyle(.borderedProminent)
                .tint(isPendingConfirmation ? .orange : nil)
            if item.category == .folder {
                Button(L10n.tr("preview.action.enter_folder"), action: onEnterFolder)
                Button(L10n.tr("context.reveal_in_finder"), action: onReveal)
            } else if item.previewURL?.isFileURL == true {
                Button(L10n.tr("context.reveal_in_finder"), action: onReveal)
                Button(L10n.tr("context.quick_look"), action: onQuickLook)
                if fullOCRText != nil {
                    Button(L10n.tr("preview.action.copy_text"), action: onCopyOCRText)
                }
            } else {
                Button(L10n.tr("context.copy"), action: onCopy)
            }
            Spacer(minLength: 2)
            Button("⌘K", action: onToggleActions)
                .help(L10n.tr("preview.action.all_actions_help"))
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var previewMedia: some View {
        if item.category == .quickAction || item.previewURL == nil {
            QuickActionPreviewCard(item: item)
        } else if let url = item.previewURL {
            FileContentPreviewView(
                item: item,
                url: url,
                size: CGSize(width: 410, height: mediaHeight),
                onOpen: onOpen
            )
        }
    }
}

extension SearchItem {
    var primaryActionTitle: String {
        switch action {
        case .openFile(let url):
            return url.pathExtension.lowercased() == "app"
                ? L10n.tr("preview.primary.open_app")
                : L10n.tr("preview.primary.open")
        case .openURL(let url):
            if url.scheme == "x-apple.systempreferences" || id.hasPrefix("pref:") {
                return L10n.tr("preview.primary.open_settings")
            }
            return L10n.tr("preview.primary.open_in_browser")
        case .copyText: return L10n.tr("preview.primary.copy")
        case .runTerminal: return L10n.tr("preview.primary.run_in_terminal")
        case .systemCommand: return L10n.tr("preview.primary.run")
        case .openSettings: return L10n.tr("preview.primary.open_settings")
        }
    }

    var footerShortcutHint: String {
        if category == .folder {
            return L10n.tr("preview.footer.folder")
        }
        if requiresConfirmation {
            return L10n.tr("preview.footer.confirm")
        }
        switch action {
        case .openFile: return L10n.tr("preview.footer.file")
        case .openURL: return L10n.tr("preview.footer.url")
        case .copyText: return L10n.tr("preview.footer.copy")
        case .runTerminal: return L10n.tr("preview.footer.terminal")
        case .systemCommand: return L10n.tr("preview.footer.system")
        case .openSettings: return L10n.tr("preview.footer.settings")
        }
    }
}
