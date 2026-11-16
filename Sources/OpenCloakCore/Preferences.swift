import Foundation

public enum OpenCloakAppearanceTheme: String, CaseIterable, Codable {
    case glass, white, dark, bubble, daisies, nightDrive, sakura

    public var displayName: String {
        switch self {
        case .glass: return "Glass"
        case .white: return "White"
        case .dark: return "Dark"
        case .bubble: return "Bubble"
        case .daisies: return "Daisies"
        case .nightDrive: return "Night Drive"
        case .sakura: return "Sakura"
        }
    }

    public var accentRGB: [Double] {
        switch self {
        case .glass: return [0.16, 0.36, 0.23]
        case .white: return [0.16, 0.36, 0.23]
        case .dark: return [0.40, 0.76, 0.55]
        case .bubble: return [0.52, 0.30, 0.76]
        case .daisies: return [0.75, 0.49, 0.12]
        case .nightDrive: return [0.12, 0.78, 0.90]
        case .sakura: return [0.83, 0.32, 0.48]
        }
    }

    public var backgroundRGB: [Double]? {
        switch self {
        case .glass: return nil
        case .white: return [0.98, 0.98, 0.99]
        case .dark: return [0.10, 0.11, 0.13]
        case .bubble: return [0.97, 0.94, 1.0]
        case .daisies: return [1.0, 0.98, 0.90]
        case .nightDrive: return [0.035, 0.055, 0.11]
        case .sakura: return [1.0, 0.94, 0.96]
        }
    }

    public var prefersDarkAppearance: Bool {
        self == .dark || self == .nightDrive
    }
}

public enum OpenCloakTextSize: Int, CaseIterable, Codable {
    case small = 0
    case standard = 1
    case large = 2

    public var displayName: String {
        switch self {
        case .small: return "Small"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }
}

public struct PreferenceValues: Codable, Equatable {
    public var idleLockMinutes: Int
    public var lockOnSleep: Bool
    public var lockOnScreenLock: Bool
    public var eventRetentionDays: Int
    public var requireBiometricOnly: Bool
    public var appearanceTheme: OpenCloakAppearanceTheme
    public var textSize: OpenCloakTextSize

    public init(idleLockMinutes: Int = 5,
                lockOnSleep: Bool = true,
                lockOnScreenLock: Bool = true,
                eventRetentionDays: Int = 30,
                requireBiometricOnly: Bool = false,
                appearanceTheme: OpenCloakAppearanceTheme = .glass,
                textSize: OpenCloakTextSize = .standard) {
        self.idleLockMinutes = Self.clampIdle(idleLockMinutes)
        self.lockOnSleep = lockOnSleep
        self.lockOnScreenLock = lockOnScreenLock
        self.eventRetentionDays = Self.clampRetention(eventRetentionDays)
        self.requireBiometricOnly = requireBiometricOnly
        self.appearanceTheme = appearanceTheme
        self.textSize = textSize
    }

    private enum CodingKeys: String, CodingKey {
        case idleLockMinutes, lockOnSleep, lockOnScreenLock, eventRetentionDays
        case requireBiometricOnly, appearanceTheme, textSize
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(idleLockMinutes: try values.decodeIfPresent(Int.self, forKey: .idleLockMinutes) ?? 5,
                  lockOnSleep: try values.decodeIfPresent(Bool.self, forKey: .lockOnSleep) ?? true,
                  lockOnScreenLock: try values.decodeIfPresent(Bool.self, forKey: .lockOnScreenLock) ?? true,
                  eventRetentionDays: try values.decodeIfPresent(Int.self, forKey: .eventRetentionDays) ?? 30,
                  requireBiometricOnly: try values.decodeIfPresent(Bool.self, forKey: .requireBiometricOnly) ?? false,
                  appearanceTheme: try values.decodeIfPresent(OpenCloakAppearanceTheme.self, forKey: .appearanceTheme) ?? .glass,
                  textSize: try values.decodeIfPresent(OpenCloakTextSize.self, forKey: .textSize) ?? .standard)
    }

    public static let idleChoices = [5, 10, 15, 20, 30, 45, 60]
    public static let retentionChoices = [0, 7, 30, 90]

    public static func clampIdle(_ value: Int) -> Int {
        min(max(value, 5), 60)
    }

    public static func clampRetention(_ value: Int) -> Int {
        min(max(value, 0), 3650)
    }
}

/// Typed access to the local preferences shared by the app and the privacy coordinator.
public struct OpenCloakPreferences {
    public enum Key {
        public static let idleLockMinutes = "idleLockMinutes"
        public static let lockOnSleep = "lockOnSleep"
        public static let lockOnScreenLock = "lockOnScreenLock"
        public static let eventRetentionDays = "eventRetentionDays"
        public static let requireBiometricOnly = "requireBiometricOnly"
        public static let appearanceTheme = "opencloakAppearanceTheme"
        public static let textSize = "opencloakTextSize"
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
            requireBiometricOnly: defaults.object(forKey: Key.requireBiometricOnly) as? Bool ?? false,
            appearanceTheme: OpenCloakAppearanceTheme(rawValue: defaults.string(forKey: Key.appearanceTheme) ?? "") ?? .glass,
            textSize: OpenCloakTextSize(rawValue: defaults.object(forKey: Key.textSize) as? Int ?? OpenCloakTextSize.standard.rawValue) ?? .standard
        )
    }

    public func store(_ values: PreferenceValues) {
        defaults.set(values.idleLockMinutes, forKey: Key.idleLockMinutes)
        defaults.set(values.lockOnSleep, forKey: Key.lockOnSleep)
        defaults.set(values.lockOnScreenLock, forKey: Key.lockOnScreenLock)
        defaults.set(values.eventRetentionDays, forKey: Key.eventRetentionDays)
        defaults.set(values.requireBiometricOnly, forKey: Key.requireBiometricOnly)
        defaults.set(values.appearanceTheme.rawValue, forKey: Key.appearanceTheme)
        defaults.set(values.textSize.rawValue, forKey: Key.textSize)
    }
}
