import QuickSpotCore
import SwiftUI

/// Horizontal scrollable strip of clickable smart pills (QR/barcode, IBAN, URL, email, phone) in the preview pane.
struct PreviewIntelligenceStripView: View {
    let entities: [DetectedSmartEntity]
    let onActivate: (DetectedSmartEntity) -> Void
    let onCopy: (DetectedSmartEntity) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(entities) { entity in
                    pillView(for: entity)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private func pillView(for entity: DetectedSmartEntity) -> some View {
        let tint = tintColor(for: entity.kind)
        return Button {
            onActivate(entity)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName(for: entity.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                Text(prefixLabel(for: entity.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                Text(entity.displayValue)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 165, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.11), in: Capsule())
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.24), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help(tooltip(for: entity))
        .contextMenu {
            Button(L10n.tr("context.copy")) { onCopy(entity) }
            if entity.openURL != nil {
                Button(L10n.tr("preview.primary.open_in_browser")) { onActivate(entity) }
            }
        }
    }

    private func iconName(for kind: DetectedSmartEntity.Kind) -> String {
        switch kind {
        case .qrURL, .qrText: return "qrcode"
        case .iban: return "banknote"
        case .url: return "link"
        case .email: return "envelope"
        case .phone: return "phone"
        }
    }

    private func prefixLabel(for kind: DetectedSmartEntity.Kind) -> String {
        switch kind {
        case .qrURL, .qrText: return L10n.tr("vision.entity.qr")
        case .iban: return "IBAN"
        case .url: return L10n.tr("vision.entity.link")
        case .email: return L10n.tr("vision.entity.email")
        case .phone: return L10n.tr("vision.entity.phone")
        }
    }

    private func tintColor(for kind: DetectedSmartEntity.Kind) -> Color {
        switch kind {
        case .qrURL, .qrText: return .indigo
        case .iban: return .teal
        case .url: return .blue
        case .email: return .purple
        case .phone: return .green
        }
    }

    private func tooltip(for entity: DetectedSmartEntity) -> String {
        if entity.openURL != nil && (entity.kind == .qrURL || entity.kind == .url) {
            return L10n.format("vision.entity.open_help", entity.copyValue)
        }
        return L10n.format("vision.entity.copy_help", entity.copyValue)
    }
}
