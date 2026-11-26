import QuickSpotCore
import SwiftUI

/// Soft, borderless, theme-adaptive strip for high-precision inline preview entities (QR/barcode and validated IBAN).
struct PreviewIntelligenceStripView: View {
    let entities: [DetectedSmartEntity]
    let onActivate: (DetectedSmartEntity) -> Void
    let onCopy: (DetectedSmartEntity) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(entities) { entity in
                SoftEntityChip(
                    entity: entity,
                    onActivate: { onActivate(entity) },
                    onCopy: { onCopy(entity) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SoftEntityChip: View {
    let entity: DetectedSmartEntity
    let onActivate: () -> Void
    let onCopy: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 5) {
                Image(systemName: leadingIconName)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                if entity.kind == .iban {
                    Text("IBAN")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }

                Text(entity.displayValue)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(isHovered ? 1.0 : 0.90))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Image(systemName: trailingIconName)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5.5)
            .background(
                Color.primary.opacity(isHovered ? 0.11 : 0.06),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .animation(.easeOut(duration: 0.14), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
        .contextMenu {
            Button(L10n.tr("context.copy"), action: onCopy)
            if entity.openURL != nil {
                Button(L10n.tr("preview.primary.open_in_browser"), action: onActivate)
            }
        }
    }

    private var leadingIconName: String {
        switch entity.kind {
        case .qrURL, .qrText: return "qrcode"
        case .iban: return "banknote"
        case .url: return "globe"
        case .email: return "envelope"
        }
    }

    private var trailingIconName: String {
        (entity.openURL != nil && (entity.kind == .qrURL || entity.kind == .url))
            ? "arrow.up.right"
            : "doc.on.doc"
    }

    private var tooltip: String {
        if entity.openURL != nil && (entity.kind == .qrURL || entity.kind == .url) {
            return L10n.format("vision.entity.open_help", entity.copyValue)
        }
        return L10n.format("vision.entity.copy_help", entity.copyValue)
    }
}
