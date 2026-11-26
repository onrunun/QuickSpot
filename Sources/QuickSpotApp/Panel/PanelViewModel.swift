import AppKit
import Combine
import QuickSpotCore

/// Visual severity for transient launcher feedback toasts and permission notices.
enum ToastStyle: Equatable {
    case success
    case warning
    case error
}

/// Active single-modifier hold state for live macOS-style button/footer morphing in the launcher panel.
enum HeldModifierMode: Equatable {
    case none
    case command
    case option
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
    @Published var semanticProgress: SemanticIndexProgress?
    @Published private(set) var focusRequest: FocusRequest = .selectAll()
    @Published var hasNavigated: Bool = false
    @Published var isSearchingFiles: Bool = false
    @Published var activeFilterBadge: String?
    @Published var similarAnchor: SimilarityAnchor?
    @Published var similarScope: SimilaritySearchScope = .images
    @Published var canSwitchSimilarScope: Bool = false
    @Published var clipboardAnchorImage: NSImage?
    @Published var similarStatusMessage: String?
    @Published var selectedSimilarityKind: SimilarityTargetKind?
    @Published var selectedSmartEntities: [DetectedSmartEntity] = []
    @Published var isRemovingBackground: Bool = false
    @Published var pendingConfirmationID: String?
    @Published var selectedFullOCRText: String?
    @Published var isActionPaletteVisible: Bool = false
    @Published var actionPaletteItems: [PaletteActionItem] = []
    @Published var actionPaletteIndex: Int = 0
    @Published var actionPaletteConfirmID: String?
    @Published var heldModifier: HeldModifierMode = .none
    @Published private(set) var languageToken: UUID = UUID()

    var onOpenSettings: (() -> Void)?
    var onOpenDuplicateFinder: (() -> Void)?
    var onRequestDelayedHide: ((TimeInterval) -> Void)?
    var onCancelPendingHide: (() -> Void)?

    var lastHiddenAt: Date?
    var selectedItemID: String?
    var searchGeneration: UInt64 = 0
    var previousQueryBeforeSimilar: String?
    var cachedClipboardVector: [Float]?
    var isUpdatingQueryInternally: Bool = false

    var toastTask: Task<Void, Never>?
    var ocrSearchTask: Task<Void, Never>?
    var semanticSearchTask: Task<Void, Never>?
    var ocrFullTextTask: Task<Void, Never>?
    var backgroundRemovalTask: Task<Void, Never>?
    var emptyRefreshTask: Task<Void, Never>?

    let appScanner: AppScanner
    let frecency: FrecencyStore
    let recentFiles: RecentFilesProvider
    let spotlightSearch: SpotlightFileSearch
    let ocrIndexer: ImageOCRIndexer?
    let semanticIndexer: SemanticImageIndexer?
    let clipboardHistory: ClipboardHistoryStore

    var appResults: [SearchItem] = []
    var recentResults: [SearchItem] = []
    var ocrResults: [SearchItem] = []
    var semanticResults: [SearchItem] = []
    var fileResults: [SearchItem] = []

    init(
        appScanner: AppScanner,
        frecency: FrecencyStore,
        recentFiles: RecentFilesProvider,
        spotlightSearch: SpotlightFileSearch,
        ocrIndexer: ImageOCRIndexer? = nil,
        semanticIndexer: SemanticImageIndexer? = nil,
        clipboardHistory: ClipboardHistoryStore = ClipboardHistoryStore()
    ) {
        self.appScanner = appScanner
        self.frecency = frecency
        self.recentFiles = recentFiles
        self.spotlightSearch = spotlightSearch
        self.ocrIndexer = ocrIndexer
        self.semanticIndexer = semanticIndexer
        self.clipboardHistory = clipboardHistory
    }

    var selectedItem: SearchItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    func prepareForShow() {
        onCancelPendingHide?()
        closeActionPalette()
        setHeldModifier(.none)
        focusRequest = .selectAll()
        hasNavigated = false
        pendingConfirmationID = nil
        if toastStyle == .warning { clearToast() }

        recentFiles.refreshAsync()

        let isStale = lastHiddenAt.map { Date().timeIntervalSince($0) > Self.staleQueryResetInterval } ?? false
        if isStale {
            similarAnchor = nil
            similarStatusMessage = nil
            previousQueryBeforeSimilar = nil
            canSwitchSimilarScope = false
            clipboardAnchorImage = nil
            cachedClipboardVector = nil
        }
        if isStale || (similarAnchor == nil && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
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
        setHeldModifier(.none)
        spotlightSearch.cancel()
        ocrSearchTask?.cancel()
        ocrSearchTask = nil
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
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
        if !query.isEmpty {
            query = ""
            focusRequest = .caretAtEnd()
        } else if similarAnchor != nil {
            exitSimilarMode()
        }
    }

    func requestSearchFocusCaretAtEnd() {
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
        if similarAnchor != nil {
            similarAnchor = nil
            similarStatusMessage = nil
            previousQueryBeforeSimilar = nil
        }
        if query != path {
            query = path
        }
        focusRequest = .caretAtEnd()
    }

    func setHeldModifier(_ mode: HeldModifierMode) {
        if heldModifier != mode {
            heldModifier = mode
        }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        onCancelPendingHide?()
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        hasNavigated = true
        syncSelectionState()
    }

    func sectionLabel(for item: SearchItem) -> String {
        let isEmptyQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && similarAnchor == nil
        if isEmptyQuery && item.matchSource == .recent && item.category != .application {
            return L10n.tr("panel.section.recent_files")
        }
        return item.category.sectionTitle
    }

    func moveSelectionBySection(direction: Int) {
        guard !items.isEmpty, direction != 0 else { return }
        let labels = items.map { sectionLabel(for: $0) }
        var sectionStarts: [Int] = [0]
        for idx in 1..<labels.count where labels[idx] != labels[idx - 1] {
            sectionStarts.append(idx)
        }

        let target: Int
        if sectionStarts.count <= 1 {
            target = direction > 0 ? items.count - 1 : 0
        } else if direction > 0 {
            if let nextStart = sectionStarts.first(where: { $0 > selectedIndex }) {
                target = nextStart
            } else {
                target = selectedIndex < items.count - 1 ? items.count - 1 : 0
            }
        } else {
            let currentStart = sectionStarts.last(where: { $0 <= selectedIndex }) ?? 0
            if selectedIndex > currentStart {
                target = currentStart
            } else if let prevStart = sectionStarts.last(where: { $0 < currentStart }) {
                target = prevStart
            } else {
                target = 0
            }
        }
        select(at: target)
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

        if case .systemCommand(let cmdID) = item.action {
            if cmdID == "duplicates" {
                frecency.record(id: item.id, query: queryContext)
                onOpenDuplicateFinder?()
                return true
            }
            if cmdID == "clipboard_similar" {
                findSimilarFromClipboardImage()
                return false
            }
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
        semanticSearchTask?.cancel()
        semanticSearchTask = nil
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
            selectedSimilarityKind = similarityKind(for: current)
            loadSelectedFullOCRText(for: current)
        } else if current == nil {
            selectedItemID = nil
            selectedSimilarityKind = nil
            selectedSmartEntities = []
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
        selectedSmartEntities = []

        guard let item,
              item.category == .file,
              let url = item.previewURL,
              url.isFileURL else { return }

        let targetID = item.id
        let path = url.standardizedFileURL.path
        let ocrRef = ocrIndexer
        let isImageOrPDF = VisionTextExtractor.isSupportedImage(url) || url.pathExtension.lowercased() == "pdf"
        ocrFullTextTask = Task { [weak self] in
            let text = await ocrRef?.fullTextAsync(forPath: path)
            guard !Task.isCancelled, let self, self.selectedItemID == targetID else { return }
            self.selectedFullOCRText = (text?.isEmpty == false) ? text : nil

            guard isImageOrPDF else { return }
            let entities = await Task.detached(priority: .utility) {
                ImageIntelligenceService.analyzePreview(url: url, ocrText: text)
            }.value
            guard !Task.isCancelled, self.selectedItemID == targetID else { return }
            self.selectedSmartEntities = entities
        }
    }
}
