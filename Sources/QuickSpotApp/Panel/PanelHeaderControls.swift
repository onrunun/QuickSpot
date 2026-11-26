import QuickSpotCore
import SwiftUI

/// Compact OCR & semantic indexing status pill and Settings button shown on the trailing edge of the search header.
struct PanelHeaderControls: View {
    let progress: IndexProgress?
    let semanticProgress: SemanticIndexProgress?
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let badgeText {
                Button(action: onOpenSettings) {
                    Text(badgeText)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.tr("panel.ocr_status_help"))
            }

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.tr("panel.settings_help"))
        }
    }

    private var badgeText: String? {
        if let state = progress?.state {
            switch state {
            case .scanning: return L10n.tr("panel.ocr_scanning")
            case .indexing(let done, let total): return "OCR \(done)/\(total)"
            case .paused: return L10n.tr("panel.ocr_paused_badge")
            case .idle: break
            }
        }
        if let state = semanticProgress?.state {
            switch state {
            case .scanning: return L10n.tr("panel.semantic_scanning")
            case .indexing(let done, let total): return "AI \(done)/\(total)"
            case .paused, .idle, .modelsMissing: return nil
            }
        }
        return nil
    }
}
