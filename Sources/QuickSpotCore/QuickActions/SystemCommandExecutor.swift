import AppKit
import Foundation

/// Executes macOS system commands, AppleScripts, screenshots, caffeinate, and local IPv4 inspection.
public enum SystemCommandExecutor {
    public static func execute(_ commandID: String) {
        _ = executeWithError(commandID)
    }

    /// Executes a system command and returns `nil` on success or an actionable localized error message on failure.
    public static func executeWithError(_ commandID: String) -> String? {
        switch commandID {
        case "lock":
            return runAppleScript(
                "tell application \"System Events\" to key code 12 using {control down, command down}",
                targetApp: "System Events",
                requiresAccessibility: true
            )
        case "sleep":
            return runProcess("/usr/bin/pmset", arguments: ["sleepnow"])
        case "restart":
            return runAppleScript(
                "tell application \"System Events\" to restart",
                targetApp: "System Events"
            )
        case "shutdown":
            return runAppleScript(
                "tell application \"System Events\" to shut down",
                targetApp: "System Events"
            )
        case "darkmode":
            return runAppleScript(
                "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode",
                targetApp: "System Events"
            )
        case "trash":
            return runAppleScript(
                "tell application \"Finder\" to empty trash",
                targetApp: "Finder"
            )
        case "mute":
            return runAppleScript(
                "set volume output muted (not (output muted of (get volume settings)))",
                targetApp: nil
            )
        case "screenshot":
            let executable = "/usr/sbin/screencapture"
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                return L10n.tr("sys.error.screencapture_missing")
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) {
                if let err = runProcess(executable, arguments: ["-ic"]) {
                    NSLog("QuickSpot screenshot error: %@", err)
                }
            }
            return nil
        case "caffeinate":
            return runProcess("/usr/bin/caffeinate", arguments: ["-d", "-t", "3600"])
        default:
            return L10n.format("sys.error.unknown_command", commandID)
        }
    }

    public static func localIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let iface = ptr.pointee
            guard let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                address = String(cString: hostname)
                if name == "en0" { break }
            }
        }
        return address
    }

    private static func runProcess(_ path: String, arguments: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        do {
            try task.run()
            return nil
        } catch {
            let tool = URL(fileURLWithPath: path).lastPathComponent
            return L10n.format("sys.error.launch_failed", tool, error.localizedDescription)
        }
    }

    private static func runAppleScript(
        _ script: String,
        targetApp: String?,
        requiresAccessibility: Bool = false
    ) -> String? {
        guard let appleScript = NSAppleScript(source: script) else {
            return L10n.tr("sys.error.prepare_failed")
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return nil }
        return formatAppleScriptError(errorInfo, targetApp: targetApp, requiresAccessibility: requiresAccessibility)
    }

    private static func formatAppleScriptError(
        _ info: NSDictionary,
        targetApp: String?,
        requiresAccessibility: Bool
    ) -> String? {
        let code = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let rawMessage = (info[NSAppleScript.errorBriefMessage] as? String)
            ?? (info[NSAppleScript.errorMessage] as? String)
            ?? ""
        let lower = rawMessage.lowercased()

        if code == -128 {
            return nil
        }

        if code == -1002 || code == -1719 || code == -25211
            || lower.contains("keystroke")
            || lower.contains("assistive")
            || lower.contains("accessibility") {
            return L10n.tr("sys.error.accessibility")
        }

        if code == -1743 || lower.contains("not authorized") || lower.contains("not permitted") {
            let target = targetApp ?? "System Events"
            return L10n.format("sys.error.automation", target)
        }

        if requiresAccessibility {
            return L10n.tr("sys.error.lock_failed")
        }

        if !rawMessage.isEmpty {
            return L10n.format("sys.error.failed_detail", rawMessage)
        }
        return L10n.format("sys.error.failed_code", code)
    }
}
