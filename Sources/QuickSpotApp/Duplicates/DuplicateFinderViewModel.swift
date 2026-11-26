import AppKit
import Foundation
import QuickSpotCore

/// Sensitivity presets for pairwise cosine clustering in the Near-Duplicate Photo Finder.
enum DuplicateThresholdPreset: String, CaseIterable, Identifiable {
    case relaxed
    case balanced
    case strict

    var id: String { rawValue }

    var threshold: Float {
        switch self {
        case .relaxed: return 0.91
        case .balanced: return 0.94
        case .strict: return 0.97
        }
    }

    var title: String {
        switch self {
        case .relaxed: return L10n.tr("duplicates.threshold.relaxed")
        case .balanced: return L10n.tr("duplicates.threshold.balanced")
        case .strict: return L10n.tr("duplicates.threshold.strict")
        }
    }
}

/// Drives the standalone Near-Duplicate Photo Finder & safe Trash cleaner window.
@MainActor
final class DuplicateFinderViewModel: ObservableObject {
    @Published var preset: DuplicateThresholdPreset = .balanced
    @Published var groups: [NearDuplicateGroup] = []
    @Published var selectedForTrash: Set<String> = []
    @Published var isScanning: Bool = false
    @Published var hasScannedOnce: Bool = false
    @Published var feedbackMessage: String?
    @Published var feedbackIsError: Bool = false

    private let semanticIndexer: SemanticImageIndexer
    private var scanTask: Task<Void, Never>?

    init(semanticIndexer: SemanticImageIndexer) {
        self.semanticIndexer = semanticIndexer
    }

    var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var selectedBytes: Int64 {
        var total: Int64 = 0
        for group in groups {
            for item in group.items where selectedForTrash.contains(item.id) {
                total += item.fileSize
            }
        }
        return total
    }

    var indexedImageCount: Int {
        semanticIndexer.currentSnapshot().embeddedCount
    }

    func scan() {
        scanTask?.cancel()
        isScanning = true
        feedbackMessage = nil
        feedbackIsError = false
        let threshold = preset.threshold
        let indexer = semanticIndexer

        scanTask = Task { [weak self] in
            let found = await indexer.findNearDuplicateImagesAsync(threshold: threshold, maxGroups: 80)
            guard !Task.isCancelled, let self else { return }
            self.groups = found
            self.selectedForTrash = []
            self.isScanning = false
            self.hasScannedOnce = true
        }
    }

    func selectPreset(_ newPreset: DuplicateThresholdPreset) {
        guard preset != newPreset else { return }
        preset = newPreset
        scan()
    }

    func toggleSelection(_ item: DuplicateImageItem) {
        if selectedForTrash.contains(item.id) {
            selectedForTrash.remove(item.id)
        } else {
            selectedForTrash.insert(item.id)
        }
    }

    func selectRecommendedDuplicates() {
        var next = Set<String>()
        for group in groups {
            for item in group.items where !item.isRecommendedKeep {
                next.insert(item.id)
            }
        }
        selectedForTrash = next
    }

    func clearSelection() {
        selectedForTrash.removeAll()
    }

    func revealInFinder(_ item: DuplicateImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openFile(_ item: DuplicateImageItem) {
        NSWorkspace.shared.open(item.url)
    }

    func trashSelected() {
        guard !selectedForTrash.isEmpty else { return }

        var trashedPaths: [String] = []
        var freedBytes: Int64 = 0
        var failureCount = 0

        for group in groups {
            for item in group.items where selectedForTrash.contains(item.id) {
                switch FileActionService.moveToTrash(item.url) {
                case .success:
                    trashedPaths.append(item.id)
                    freedBytes += item.fileSize
                case .failure:
                    failureCount += 1
                }
            }
        }

        let trashedSet = Set(trashedPaths)
        if !trashedPaths.isEmpty {
            semanticIndexer.removeIndexedPaths(trashedPaths)
            selectedForTrash.subtract(trashedSet)
            groups = groups.compactMap { group in
                let remaining = group.items.filter { !trashedSet.contains($0.id) }
                guard remaining.count >= 2 else { return nil }
                return NearDuplicateGroup(
                    id: group.id,
                    items: remaining,
                    averageSimilarity: group.averageSimilarity
                )
            }
        }

        if failureCount > 0 && trashedPaths.isEmpty {
            feedbackIsError = true
            feedbackMessage = L10n.tr("duplicates.toast.trash_failed")
        } else if !trashedPaths.isEmpty {
            feedbackIsError = false
            let sizeStr = Self.formatBytes(freedBytes)
            feedbackMessage = L10n.format("duplicates.toast.trashed", trashedPaths.count, sizeStr)
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
