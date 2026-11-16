import AppKit
import Carbon
import Foundation

struct BrowserStatus: Identifiable {
    let id: String
    let name: String
    let status: BrowserAutomationStatus
}

enum BrowserAutomationStatus: Equatable {
    case granted
    case denied
    case notDetermined
    case browserNotRunning
    case unknown

    var label: String {
        switch self {
        case .granted: return "Access allowed"
        case .denied: return "Access denied"
        case .notDetermined: return "Permission not requested"
        case .browserNotRunning: return "Browser not running"
        case .unknown: return "Status unavailable"
        }
    }

    var symbol: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        case .notDetermined: return "questionmark.circle"
        case .browserNotRunning: return "moon.zzz"
        case .unknown: return "questionmark.diamond"
        }
    }
}

enum BrowserPermissions {
    static let supportedBrowsers: [(bundleID: String, name: String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Chrome"),
        ("com.brave.Browser", "Brave"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.vivaldi.Vivaldi", "Vivaldi")
    ]

    /// Uses the system Automation permission check. With `askUser` false this never prompts.
    static func status(for bundleID: String, askUser: Bool = false) -> BrowserAutomationStatus {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBufferPointer { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let result = AEDeterminePermissionToAutomateTarget(&target,
                                                           AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard),
                                                           askUser)
        if result == noErr { return .granted }
        if result == OSStatus(errAEEventNotPermitted) { return .denied }
        if result == OSStatus(errAEEventWouldRequireUserConsent) { return .notDetermined }
        if result == OSStatus(procNotFound) { return .browserNotRunning }
        return .unknown
    }

    static func currentStatuses() -> [BrowserStatus] {
        supportedBrowsers.map { BrowserStatus(id: $0.bundleID, name: $0.name, status: status(for: $0.bundleID)) }
    }

    static func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
