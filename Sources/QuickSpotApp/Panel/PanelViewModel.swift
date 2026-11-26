import AppKit
import Combine
import QuickSpotCore

/// Visual severity for transient launcher feedback toasts and permission notices.
enum ToastStyle: Equatable {
    case success
    case warning
    case error
}

/// Drives instant app/recent/path filtering, async OCR lookups, progressive Spotlight queries, and safe execution.
@MainActor
final class PanelViewModel: ObservableObject {
    private static let staleQueryResetInterval: TimeInterval = 45

    @Published var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            queryDidChange()
        }
    }
    @Published var items: [SearchItem] = []
    @Published var selectedIndex: Int = 0
    @Published var toastMessage: String?
    @Published var toastStyle: ToastStyle = .success
    @Published var indexProgress: IndexProgress?
    @Published private(set) var focusRequest: FocusRequest = .selectAll()
    @Published var hasNavigated: Bool = false
    @Published var isSearchingFiles: Bool = false
    @Published var activeFilterBadge: String?
    @Published var pendingConfirmationID: String?
    @Published var selectedFullOCRText: String?
    @Published var isActionPaletteVisible: Bool = false
    @Published var actionPaletteItems: [PaletteActionItem] = []
    @Published var actionPaletteIndex: Int = 0
    @Published var actionPaletteConfirmID: String?
    @Published private(set) var languageToken: UUID = UUID()

    var onOpenSettings: (() -> Void)?
    var onRequestDelayedHide: ((TimeInterval) -> Void)?
    var onCancelPendingHide: (() -> Void)?

    var lastHiddenAt: Date?
    var selectedItemID: String?
    var searchGeneration: UInt64 = 0

    var toastTask: Task<Void, Never>?
    var ocrSearchTask: Task<Void, Never>?
    var ocrFullTextTask: Task<Void, Never>?
    var emptyRefreshTask: Task<Void, Never>?

    let appScanner: AppScanner
    let frecency: FrecencyStore
    let recentFiles: RecentFilesProvider
    let spotlightSearch: SpotlightFileSearch
    let ocrIndexer: ImageOCRIndexer?
    let clipboardHistory: ClipboardHistoryStore

    var appResults: [SearchItem] = []
    var recentResults: [SearchItem] = []
    var ocrResults: [SearchItem] = []
    var fileResults: [SearchItem] = []

    init(
        appScanner: AppScanner,
        frecency: FrecencyStore,
        recentFiles: RecentFilesProvider,
        spotlightSearch: SpotlightFileSearch,
        ocrIndexer: ImageOCRIndexer? = nil,
        clipboardHistory: ClipboardHistoryStore = ClipboardHistoryStore()
    ) {
        self.appScanner = appScanner
        self.frecency = frecency
        self.recentFiles = recentFiles
        self.spotlightSearch = spotlightSearch
        self.ocrIndexer = ocrIndexer
        self.clipboardHistory = clipboardHistory
    }

    var selectedItem: SearchItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func prepareForShow() {
        onCancelPendingHide?()
        closeActionPalette()
        focusRequest = .selectAll()
        hasNavigated = false
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }

        recentFiles.refreshAsync()

        let isStale = lastHiddenAt.map { Date().timeIntervalSince($0) > Self.staleQueryResetInterval } ?? false
        if isStale || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !query.isEmpty {
                query = ""
            } else {
                activeFilterBadge = nil
                isSearchingFiles = false
                applyItems(buildEmptyStateItems(), preserveSelection: false)
            }
            scheduleEmptyStateRefresh()
        }
    }

    func markHidden() {
        lastHiddenAt = Date()
        closeActionPalette()
        spotlightSearch.cancel()
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        emptyRefreshTask?.cancel()
        emptyRefreshTask = nil
        isSearchingFiles = false
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }
    }

    func clearQuery() {
        onCancelPendingHide?()
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }
        query = ""
        focusRequest = .caretAtEnd()
    }

    func cancelConfirmation() {
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }
    }

    func refreshForLanguageChange() {
        languageToken = UUID()
        queryDidChange()
    }

    func setQueryForAutocomplete(_ path: String) {
        onCancelPendingHide?()
        if query != path {
            query = path
        }
        focusRequest = .caretAtEnd()
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        onCancelPendingHide?()
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        hasNavigated = true
        syncSelectionState()
    }

    func select(at index: Int) {
        guard items.indices.contains(index) else { return }
        onCancelPendingHide?()
        selectedIndex = index
        hasNavigated = true
        syncSelectionState()
    }

    func selectAndExecute(at index: Int) -> Bool {
        guard items.indices.contains(index) else { return false }
        if index != selectedIndex {
            selectedIndex = index
            syncSelectionState()
        }
        return executeSelected(revealInFinder: false)
    }

    func executeSelected(revealInFinder: Bool = false) -> Bool {
        guard let item = selectedItem else { return false }
        onCancelPendingHide?()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryContext = trimmed.isEmpty ? nil : trimmed

        if revealInFinder, case .openFile(let url) = item.action {
            frecency.record(id: url.standardizedFileURL.path, query: queryContext)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        }

        if item.requiresConfirmation {
            if pendingConfirmationID != item.id {
                pendingConfirmationID = item.id
                showToast(L10n.tr("panel.toast.confirm_again"), style: .warning, duration: 4.0)
                return false
            }
            pendingConfirmationID = nil
            if toastStyle == .warning { clearToast() }
        }

        if case .openSettings = item.action {
            _ = QuickActionRouter.executeWithFeedback(
                item.action,
                frecency: frecency,
                itemID: item.id,
                query: queryContext
            )
            onOpenSettings?()
            return true
        }

        let outcome = QuickActionRouter.executeWithFeedback(
            item.action,
            frecency: frecency,
            itemID: item.id,
            query: queryContext
        )
        if let errorMessage = outcome.feedbackMessage, !errorMessage.isEmpty {
            showToast(errorMessage, style: .error, duration: 5.0)
            return false
        }
        if case .copyText(let copied) = item.action {
            clipboardHistory.promoteCopiedText(copied)
            showToast(L10n.tr("panel.toast.copied"), style: .success, duration: 0.45)
            if let onRequestDelayedHide {
                onRequestDelayedHide(0.42)
                return false
            }
            return true
        }
        return outcome.shouldHide
    }

    func cancelOrDismiss() -> Bool {
        spotlightSearch.cancel()
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        emptyRefreshTask?.cancel()
        emptyRefreshTask = nil
        isSearchingFiles = false
        pendingConfirmationID = nil
        return true
    }

    func applyItems(_ newItems: [SearchItem], preserveSelection: Bool) {
        let lockedID = (preserveSelection && hasNavigated) ? selectedItemID : nil
        let lockedPath = (preserveSelection && hasNavigated)
            ? selectedItem?.previewURL?.standardizedFileURL.path
            : nil
        items = newItems

        if let lockedID, let preservedIdx = items.firstIndex(where: { $0.id == lockedID }) {
            selectedIndex = preservedIdx
        } else if let lockedPath,
                  let preservedIdx = items.firstIndex(where: { $0.previewURL?.standardizedFileURL.path == lockedPath }) {
            selectedIndex = preservedIdx
        } else if items.isEmpty || !preserveSelection || selectedIndex >= items.count {
            selectedIndex = 0
        }

        syncSelectionState()
    }

    func syncSelectionState() {
        let current = selectedItem
        let newID = current?.id

        if newID != selectedItemID {
            selectedItemID = newID
            if pendingConfirmationID != nil && pendingConfirmationID != newID {
                pendingConfirmationID = nil
                if toastStyle == .warning { clearToast() }
            }
            loadSelectedFullOCRText(for: current)
        } else if current == nil {
            selectedItemID = nil
            ocrFullTextTask?.cancel()
            ocrFullTextTask = nil
            selectedFullOCRText = nil
            if pendingConfirmationID != nil {
                pendingConfirmationID = nil
                if toastStyle == .warning { clearToast() }
            }
        }
    }

    private func loadSelectedFullOCRText(for item: SearchItem?) {
        ocrFullTextTask?.cancel()
        ocrFullTextTask = nil
        selectedFullOCRText = nil

        guard let item,
              item.category == .file,
              let url = item.previewURL,
              url.isFileURL,
              let ocrIndexer else { return }

        let targetID = item.id
        let path = url.standardizedFileURL.path
        ocrFullTextTask = Task { [weak self] in
            let text = await ocrIndexer.fullTextAsync(forPath: path)
            guard !Task.isCancelled, let self, self.selectedItemID == targetID else { return }
            self.selectedFullOCRText = text
        }
    }
}
