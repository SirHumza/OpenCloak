import Foundation

public struct PreferenceValues: Codable, Equatable {
    public var idleLockMinutes: Int
    public var lockOnSleep: Bool
    public var lockOnScreenLock: Bool
    public var eventRetentionDays: Int
    public var requireBiometricOnly: Bool

    public init(idleLockMinutes: Int = 5,
                lockOnSleep: Bool = true,
                lockOnScreenLock: Bool = true,
                eventRetentionDays: Int = 30,
                requireBiometricOnly: Bool = false) {
        self.idleLockMinutes = Self.clampIdle(idleLockMinutes)
        self.lockOnSleep = lockOnSleep
        self.lockOnScreenLock = lockOnScreenLock
        self.eventRetentionDays = Self.clampRetention(eventRetentionDays)
        self.requireBiometricOnly = requireBiometricOnly
    }

    public static let idleChoices = [0, 1, 5, 10, 15, 30]
    public static let retentionChoices = [0, 7, 30, 90]

    public static func clampIdle(_ value: Int) -> Int {
        min(max(value, 0), 120)
    }

    public static func clampRetention(_ value: Int) -> Int {
        min(max(value, 0), 3650)
    }
}

/// Typed access to the local preferences shared by the app and the privacy coordinator.
public struct NopalPreferences {
    public enum Key {
        public static let idleLockMinutes = "idleLockMinutes"
        public static let lockOnSleep = "lockOnSleep"
        public static let lockOnScreenLock = "lockOnScreenLock"
        public static let eventRetentionDays = "eventRetentionDays"
        public static let requireBiometricOnly = "requireBiometricOnly"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var values: PreferenceValues {
        PreferenceValues(
            idleLockMinutes: defaults.object(forKey: Key.idleLockMinutes) as? Int ?? 5,
            lockOnSleep: defaults.object(forKey: Key.lockOnSleep) as? Bool ?? true,
            lockOnScreenLock: defaults.object(forKey: Key.lockOnScreenLock) as? Bool ?? true,
            eventRetentionDays: defaults.object(forKey: Key.eventRetentionDays) as? Int ?? 30,
            requireBiometricOnly: defaults.object(forKey: Key.requireBiometricOnly) as? Bool ?? false
        )
    }

    public func store(_ values: PreferenceValues) {
        defaults.set(values.idleLockMinutes, forKey: Key.idleLockMinutes)
        defaults.set(values.lockOnSleep, forKey: Key.lockOnSleep)
        defaults.set(values.lockOnScreenLock, forKey: Key.lockOnScreenLock)
        defaults.set(values.eventRetentionDays, forKey: Key.eventRetentionDays)
        defaults.set(values.requireBiometricOnly, forKey: Key.requireBiometricOnly)
    }
}
