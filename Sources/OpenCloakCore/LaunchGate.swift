import Foundation

public struct LaunchAllowance: Codable, Equatable {
    public let bundleIdentifier: String
    public let expires: Date

    public init(bundleIdentifier: String, expires: Date) {
        self.bundleIdentifier = bundleIdentifier
        self.expires = expires
    }
}

/// Pure decision logic for the launch gate: an app covered by an enabled rule is terminated until
/// the user authenticates, at which point a time-boxed allowance is issued.
public enum LaunchGate {
    public static let defaultAllowance: TimeInterval = 12 * 60 * 60

    public static func activeAllowances(_ allowances: [LaunchAllowance], now: Date) -> [LaunchAllowance] {
        allowances.filter { $0.expires > now }
    }

    public static func allowance(for bundleIdentifier: String,
                                 now: Date,
                                 duration: TimeInterval = defaultAllowance) -> LaunchAllowance {
        LaunchAllowance(bundleIdentifier: bundleIdentifier, expires: now.addingTimeInterval(duration))
    }

    /// Every running app that must be stopped right now.
    public static func blockedApplications(running: [String],
                                           rules: [PrivacyRule],
                                           allowances: [LaunchAllowance],
                                           ownBundleIdentifier: String,
                                           now: Date) -> [String] {
        let allowed = Set(activeAllowances(allowances, now: now).map(\.bundleIdentifier))
        var blocked: [String] = []
        for candidate in Set(running) {
            guard candidate != ownBundleIdentifier, !allowed.contains(candidate) else { continue }
            let covered = rules.contains { rule in
                guard rule.isActive(at: now), case .application(let identifier, _) = rule.target else { return false }
                return identifier == candidate
            }
            if covered { blocked.append(candidate) }
        }
        return blocked.sorted()
    }

    public static func displayName(forBundleIdentifier bundleIdentifier: String, in rules: [PrivacyRule]) -> String {
        for rule in rules {
            if case .application(let identifier, let name) = rule.target, identifier == bundleIdentifier {
                return name
            }
        }
        return bundleIdentifier
    }
}
