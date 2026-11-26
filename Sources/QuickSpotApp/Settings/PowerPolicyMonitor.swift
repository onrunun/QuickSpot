import Foundation
import IOKit.ps
import QuickSpotCore

/// Event-driven monitor pausing background OCR backfills on battery, Low Power Mode, or high thermal load.
@MainActor
final class PowerPolicyMonitor {
    private var indexOnBattery: Bool
    private let onChange: (String?) -> Void
    nonisolated(unsafe) private var powerSource: CFRunLoopSource?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private(set) var blocker: String?

    init(indexOnBattery: Bool, onChange: @escaping (String?) -> Void) {
        self.indexOnBattery = indexOnBattery
        self.onChange = onChange
        self.blocker = Self.blocker(indexOnBattery: indexOnBattery)

        let me = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource(powerSourceChangedCallback, me)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        let names: [Notification.Name] = [
            ProcessInfo.thermalStateDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            })
        }
    }

    deinit {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setIndexOnBattery(_ enabled: Bool) {
        indexOnBattery = enabled
        reevaluate()
    }

    fileprivate func reevaluate() {
        let next = Self.blocker(indexOnBattery: indexOnBattery)
        guard next != blocker else { return }
        blocker = next
        onChange(next)
    }

    nonisolated static func blocker(indexOnBattery: Bool) -> String? {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return L10n.tr("power.low_power_mode") }
        switch info.thermalState {
        case .serious, .critical: return L10n.tr("power.thermal_high")
        default: break
        }
        if !indexOnBattery && !onACPower() { return L10n.tr("power.on_battery") }
        return nil
    }

    nonisolated static func onACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPMACPowerKey
    }
}

private nonisolated func powerSourceChangedCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let address = UInt(bitPattern: context)
    MainActor.assumeIsolated {
        Unmanaged<PowerPolicyMonitor>.fromOpaque(UnsafeRawPointer(bitPattern: address)!).takeUnretainedValue().reevaluate()
    }
}
