import CoreGraphics
import Foundation
import IOKit.ps

/// Controls background indexing intensity, balancing acoustic/thermal silence against throughput.
public enum IndexingMode: String, CaseIterable, Equatable, Sendable {
    /// Default low-impact mode: E-core QoS, 1-image visual pulses, adaptive duty-cycle cooldowns, and unattended idle boost.
    case quiet
    /// High-throughput mode: larger batches and minimal cooldowns while still respecting thermal safety and live search.
    case fast
}

/// Identifies which hardware stage is executing so batch sizes and cooldown ratios can be tuned independently.
public enum IndexingWorkload: Equatable, Sendable {
    case ocr
    case semanticDocument
    case semanticVisual
}

/// Adaptive thermal-, idle-, and interactivity-aware pacer empirically calibrated for Apple Silicon ANE and Metal GPU.
public final class IndexingPacer: @unchecked Sendable {
    public typealias SleepHandler = @Sendable (UInt64) async -> Void

    /// Minimum continuous user inactivity on AC power before Quiet mode gently accelerates unattended backfills.
    public static let idleBoostThresholdSeconds: TimeInterval = 120
    /// Work units faster than this in OCR (e.g. embedded digital PDF text extraction at ~5ms) bypass heavy ANE cooldown floors.
    private static let lightOCRThresholdSeconds: TimeInterval = 0.03
    private static let interactivePollNanos: UInt64 = 150_000_000

    private let modeProvider: @Sendable () -> IndexingMode
    private let thermalStateProvider: @Sendable () -> ProcessInfo.ThermalState
    private let idleSecondsProvider: @Sendable () -> TimeInterval
    private let isOnACPowerProvider: @Sendable () -> Bool
    private let isInteractiveSearchActiveProvider: @Sendable () -> Bool
    private let sleepHandler: SleepHandler
    private let isEnabled: Bool

    public init(
        modeProvider: @escaping @Sendable () -> IndexingMode = { .quiet },
        thermalStateProvider: @escaping @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
        idleSecondsProvider: @escaping @Sendable () -> TimeInterval = { IndexingPacer.systemIdleSeconds() },
        isOnACPowerProvider: @escaping @Sendable () -> Bool = { IndexingPacer.systemIsOnACPower() },
        isInteractiveSearchActiveProvider: @escaping @Sendable () -> Bool = { false },
        sleepHandler: @escaping SleepHandler = { nanos in try? await Task.sleep(nanoseconds: nanos) },
        isEnabled: Bool = true
    ) {
        self.modeProvider = modeProvider
        self.thermalStateProvider = thermalStateProvider
        self.idleSecondsProvider = idleSecondsProvider
        self.isOnACPowerProvider = isOnACPowerProvider
        self.isInteractiveSearchActiveProvider = isInteractiveSearchActiveProvider
        self.sleepHandler = sleepHandler
        self.isEnabled = isEnabled
    }

    /// Creates a production pacer bound to `IndexSettingsStore` and live macOS thermal, power, and input-idle signals.
    public static func live(
        settingsStore: IndexSettingsStore = IndexSettingsStore(),
        isInteractiveSearchActive: @escaping @Sendable () -> Bool = { false }
    ) -> IndexingPacer {
        IndexingPacer(
            modeProvider: { settingsStore.load().indexingMode },
            isInteractiveSearchActiveProvider: isInteractiveSearchActive
        )
    }

    /// Unthrottled pacer useful for deterministic high-speed tests.
    public static let unthrottled = IndexingPacer(
        modeProvider: { .fast },
        thermalStateProvider: { .nominal },
        idleSecondsProvider: { 0 },
        isOnACPowerProvider: { true },
        isInteractiveSearchActiveProvider: { false },
        isEnabled: false
    )

    public var currentMode: IndexingMode {
        modeProvider()
    }

    /// Selects `.background` (E-core + throttled I/O) in Quiet mode and `.utility` in Fast mode.
    public func taskPriority(force: Bool = false) -> TaskPriority {
        guard isEnabled else { return .utility }
        switch modeProvider() {
        case .quiet:
            return .background
        case .fast:
            return .utility
        }
    }

    /// Gentle per-chunk crawl sleep (applied every 256 inspected entries) to keep large folder scans silent on Disk I/O.
    public var crawlThrottleDelay: TimeInterval {
        guard isEnabled else { return 0 }
        let mode = modeProvider()
        let thermal = thermalStateProvider()
        if thermal == .serious || thermal == .critical { return 0.015 }
        if mode == .fast { return thermal == .fair ? 0.005 : 0 }
        if thermal == .fair { return 0.010 }
        return isIdleBoostActive(mode: mode, thermal: thermal) ? 0.001 : 0.003
    }

    /// Returns the calibrated batch size for the given workload based on mode, thermal state, and idle boost.
    /// Visual embeddings saturate Metal at 1 image (~485ms on M1 Pro), so Quiet uses 1-image pulses to halve peak heat and query stalls.
    public func batchSize(for workload: IndexingWorkload) -> Int {
        guard isEnabled else {
            return defaultFastBatchSize(for: workload)
        }
        let mode = modeProvider()
        let thermal = thermalStateProvider()
        let idleBoost = isIdleBoostActive(mode: mode, thermal: thermal)

        switch workload {
        case .ocr:
            return 1
        case .semanticDocument:
            switch (mode, thermal) {
            case (_, .serious), (_, .critical):
                return 4
            case (.quiet, .fair):
                return 4
            case (.quiet, .nominal):
                return idleBoost ? 12 : 6
            case (.fast, .fair):
                return 8
            case (.fast, .nominal):
                return 16
            @unknown default:
                return 6
            }
        case .semanticVisual:
            switch (mode, thermal) {
            case (_, .serious), (_, .critical):
                return 1
            case (.quiet, .fair):
                return 1
            case (.quiet, .nominal):
                return idleBoost ? 2 : 1
            case (.fast, .fair):
                return 2
            case (.fast, .nominal):
                return 4
            @unknown default:
                return 1
            }
        }
    }

    /// Computes how long to pause after a work unit of `workDuration` seconds to maintain a cool acoustic duty cycle.
    public func cooldownDuration(
        for workload: IndexingWorkload,
        workDuration: TimeInterval,
        force: Bool = false
    ) -> TimeInterval {
        guard isEnabled else { return 0 }
        let clampedWork = max(0, workDuration)
        let mode = modeProvider()
        let thermal = thermalStateProvider()

        // Even user-forced or Fast passes apply protective cooling under serious/critical thermal pressure.
        if thermal == .serious || thermal == .critical {
            let cap: TimeInterval = (thermal == .critical) ? 3.0 : 2.2
            let floor: TimeInterval = (thermal == .critical) ? 0.60 : 0.35
            return clamp(clampedWork * 3.0, min: floor, max: cap)
        }

        if mode == .fast {
            if thermal == .fair {
                let ratio: TimeInterval = (workload == .semanticVisual) ? 0.85 : 0.65
                let floor: TimeInterval = (workload == .semanticVisual) ? 0.15 : 0.08
                return clamp(clampedWork * ratio, min: floor, max: 1.2)
            }
            return 0
        }

        // Fast-path digital PDFs (~5ms CPU-only text extraction) avoid unnecessary ANE cooldown floors.
        if workload == .ocr && clampedWork < Self.lightOCRThresholdSeconds && thermal == .nominal {
            if isIdleBoostActive(mode: mode, thermal: thermal) {
                return 0.005
            }
            return clamp(clampedWork * 0.5, min: 0.01, max: 0.025)
        }

        // Thermal .fair: ease off early before fans become audible or macOS escalates to .serious.
        if thermal == .fair {
            switch workload {
            case .ocr:
                return clamp(clampedWork * 1.6, min: 0.25, max: 2.0)
            case .semanticDocument:
                return clamp(clampedWork * 2.8, min: 0.30, max: 2.2)
            case .semanticVisual:
                return clamp(clampedWork * 3.2, min: 0.50, max: 3.0)
            }
        }

        // Unattended AC idle boost: ~70-85% duty cycle to drain archives while the user is away.
        if isIdleBoostActive(mode: mode, thermal: thermal) {
            switch workload {
            case .ocr:
                return clamp(clampedWork * 0.15, min: 0.02, max: 0.20)
            case .semanticDocument:
                return clamp(clampedWork * 0.35, min: 0.03, max: 0.35)
            case .semanticVisual:
                return clamp(clampedWork * 0.45, min: 0.05, max: 0.65)
            }
        }

        // Default active Quiet mode calibrated on Apple M1 Pro:
        // - Vision OCR (~2W ANE, ~10-30% of 1 core): ~64% ANE duty cycle (~2% total Mac CPU).
        // - Semantic Text (~65ms GPU micro-bursts): ~42% GPU duty cycle.
        // - Semantic Visual (~485ms single-image GPU pulses): ~38% GPU duty cycle, zero fan spin-up.
        let forceScale: TimeInterval = force ? 0.8 : 1.0
        switch workload {
        case .ocr:
            return clamp(clampedWork * 0.55 * forceScale, min: 0.08, max: 0.75)
        case .semanticDocument:
            return clamp(clampedWork * 1.40 * forceScale, min: 0.08, max: 1.20)
        case .semanticVisual:
            return clamp(clampedWork * 1.65 * forceScale, min: 0.15, max: 1.60)
        }
    }

    /// Yields while the user is actively interacting with the QuickSpot launcher panel so live search stays instant.
    public func waitBeforeWork() async {
        guard isEnabled else { return }
        while !Task.isCancelled && isInteractiveSearchActiveProvider() {
            await sleepHandler(Self.interactivePollNanos)
        }
    }

    /// Sleeps for the adaptive cooldown duration (or yields cleanly when zero) before the next unit of work.
    public func cooldownAfterWork(
        for workload: IndexingWorkload,
        workDuration: TimeInterval,
        force: Bool = false
    ) async {
        guard !Task.isCancelled else { return }
        let seconds = cooldownDuration(for: workload, workDuration: workDuration, force: force)
        if seconds > 0.001 {
            let nanos = UInt64((seconds * 1_000_000_000).rounded())
            await sleepHandler(nanos)
        } else {
            await Task.yield()
        }
    }

    /// Seconds since last keyboard/mouse HID event (requires no Accessibility permissions).
    public static func systemIdleSeconds() -> TimeInterval {
        // Matches CoreGraphics `kCGAnyInputEventType` (`~0`) without relying on C macro bridging.
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return 0 }
        let elapsed = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return elapsed.isFinite && elapsed >= 0 ? elapsed : 0
    }

    /// Returns true on desktop Macs or when plugged into AC power.
    public static func systemIsOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPMACPowerKey
    }

    private func isIdleBoostActive(mode: IndexingMode, thermal: ProcessInfo.ThermalState) -> Bool {
        guard mode == .quiet, thermal == .nominal else { return false }
        guard !isInteractiveSearchActiveProvider() else { return false }
        return isOnACPowerProvider() && idleSecondsProvider() >= Self.idleBoostThresholdSeconds
    }

    private func defaultFastBatchSize(for workload: IndexingWorkload) -> Int {
        switch workload {
        case .ocr: return 1
        case .semanticDocument: return 16
        case .semanticVisual: return 4
        }
    }

    private func clamp(_ value: TimeInterval, min lower: TimeInterval, max upper: TimeInterval) -> TimeInterval {
        Swift.min(upper, Swift.max(lower, value))
    }
}
