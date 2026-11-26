import AppKit
import QuickSpotCore
import SwiftUI

/// Floating Raycast-style secondary action menu (`⌘K`) rendered cleanly over the launcher panel.
struct ActionPaletteOverlay: View {
    let targetTitle: String
    let actions: [PaletteActionItem]
    let selectedIndex: Int
    let pendingConfirmationID: String?
    let onSelect: (Int) -> Void
    let onExecute: (Int) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().opacity(0.35)
                actionsList
                Divider().opacity(0.35)
                footer
            }
            .frame(width: 300)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.32), radius: 16, y: 6)
            .padding(14)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "command.square.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(L10n.tr("palette.header"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
            Text("· \(targetTitle)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var actionsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        actionRow(action, index: index)
                            .id(action.id)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 250)
            .onChange(of: selectedIndex) { _, _ in
                if actions.indices.contains(selectedIndex) {
                    proxy.scrollTo(actions[selectedIndex].id)
                }
            }
        }
    }

    private func actionRow(_ action: PaletteActionItem, index: Int) -> some View {
        let isSelected = index == selectedIndex
        let isPending = pendingConfirmationID == action.id

        return HStack(spacing: 8) {
            actionIcon(action)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(isPending ? L10n.tr("panel.toast.confirm_again") : action.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(action.isDestructive ? .red : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let sub = action.subtitle, !isPending {
                    Text(sub)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            if let hint = action.shortcutHint {
                Text(hint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(rowFill(isSelected: isSelected, isPending: isPending, isDestructive: action.isDestructive))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(index)
            onExecute(index)
        }
    }

    @ViewBuilder
    private func actionIcon(_ action: PaletteActionItem) -> some View {
        if let path = action.iconPath {
            Image(nsImage: AppIconCache.shared.icon(for: path))
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else if let symbol = action.sfSymbol {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(action.isDestructive ? .red : .secondary)
        }
    }

    private func rowFill(isSelected: Bool, isPending: Bool, isDestructive: Bool) -> Color {
        if isPending { return Color.red.opacity(0.22) }
        if !isSelected { return .clear }
        return isDestructive ? Color.red.opacity(0.16) : Color.accentColor.opacity(0.24)
    }

    private var footer: some View {
        HStack {
            Text(L10n.tr("palette.footer"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
