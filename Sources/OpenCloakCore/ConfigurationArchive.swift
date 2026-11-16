import Foundation

/// A user-exportable configuration snapshot. It intentionally contains only
/// privacy rules and preferences: no credentials, no history, no file contents.
public struct ConfigurationSnapshot: Codable, Equatable {
    public let schema: Int
    public let exportedAt: Date
    public let rules: [PrivacyRule]
    public let preferences: PreferenceValues

    public init(schema: Int = 1, exportedAt: Date = Date(), rules: [PrivacyRule], preferences: PreferenceValues) {
        self.schema = schema
        self.exportedAt = exportedAt
        self.rules = rules
        self.preferences = preferences
    }
}

public enum ConfigurationArchiveError: LocalizedError {
    case write

    public var errorDescription: String? {
        "OpenCloak could not write the configuration file."
    }
}

public enum ConfigurationArchive {
    public static func snapshot(rules: [PrivacyRule],
                                preferences: PreferenceValues,
                                date: Date = Date()) -> ConfigurationSnapshot {
        ConfigurationSnapshot(exportedAt: date, rules: rules, preferences: preferences)
    }

    public static func write(_ snapshot: ConfigurationSnapshot, to url: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw ConfigurationArchiveError.write
        }
    }
}
