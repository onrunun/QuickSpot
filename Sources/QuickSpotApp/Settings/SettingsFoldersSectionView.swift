import QuickSpotCore
import SwiftUI

/// Dedicated Folders tab providing generous space for both Indexed Folders and Excluded Folders with Finder reveal.
struct SettingsFoldersSectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var hoveredPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionGroup(L10n.tr("settings.folders.section")) {
                Button(L10n.tr("settings.folders.add_button")) {
                    viewModel.addFolderViaPanel()
                }
                .controlSize(.small)
            } content: {
                if viewModel.settings.folders.isEmpty {
                    emptyRow(L10n.tr("settings.folders.empty"))
                } else {
                    ForEach(Array(viewModel.settings.folders.enumerated()), id: \.element) { idx, folder in
                        if idx > 0 { SettingsRowDivider() }
                        folderRow(
                            folder,
                            symbol: "folder.fill",
                            tint: .blue,
                            removeHelp: L10n.tr("settings.folders.remove_help"),
                            onRemove: { viewModel.removeFolder(folder) }
                        )
                    }
                }
            }

            SettingsSectionGroup(L10n.tr("settings.folders.excluded_title")) {
                Button(L10n.tr("settings.folders.exclude_button")) {
                    viewModel.addExcludedFolderViaPanel()
                }
                .controlSize(.small)
            } content: {
                if viewModel.settings.excludedFolders.isEmpty {
                    emptyRow(L10n.tr("settings.folders.excluded_empty"))
                } else {
                    ForEach(Array(viewModel.settings.excludedFolders.enumerated()), id: \.element) { idx, folder in
                        if idx > 0 { SettingsRowDivider() }
                        folderRow(
                            folder,
                            symbol: "folder.badge.minus",
                            tint: .orange,
                            removeHelp: L10n.tr("settings.folders.remove_excluded_help"),
                            onRemove: { viewModel.removeExcludedFolder(folder) }
                        )
                    }
                }
            }
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func folderRow(
        _ folder: String,
        symbol: String,
        tint: Color,
        removeHelp: String,
        onRemove: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredPath == folder
        let displayPath = folder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 18)

            Text(displayPath)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Button {
                viewModel.revealFolderInFinder(folder)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 0.9 : 0.45)
            .help(L10n.tr("settings.folders.reveal_help"))

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(isHovered ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 0.95 : 0.55)
            .help(removeHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isHovered ? Color.primary.opacity(0.035) : Color.clear)
        .onHover { hovering in
            hoveredPath = hovering ? folder : (hoveredPath == folder ? nil : hoveredPath)
        }
    }
}
