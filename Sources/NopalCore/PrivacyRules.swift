import Foundation

public enum PrivacyRuleError: LocalizedError {
    case invalidApplication
    case invalidWebsite
    case duplicate
    case persistence

    public var errorDescription: String? {
        switch self {
        case .invalidApplication: return "Choose a valid app bundle identifier."
        case .invalidWebsite: return "Enter a valid website host and optional path."
        case .duplicate: return "This privacy rule already exists."
        case .persistence: return "Nopal could not safely save this rule."
        }
    }
}

public struct WebsitePattern: Codable, Equatable {
    public let host: String
    public let pathPrefix: String

    public init(_ value: String) throws {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = raw.contains("://") ? raw : "https://\(raw)"
        guard let parts = URLComponents(string: candidate),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), host.contains("."),
              host.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil,
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil else { throw PrivacyRuleError.invalidWebsite }
        let path = parts.path.isEmpty ? "/" : parts.path
        guard path.hasPrefix("/"), !path.contains("//") else { throw PrivacyRuleError.invalidWebsite }
        self.host = host
        self.pathPrefix = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    public func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let urlHost = url.host?.lowercased(), urlHost == host else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let prefix = pathPrefix.count > 1 && pathPrefix.hasSuffix("/") ? String(pathPrefix.dropLast()) : pathPrefix
        return prefix == "/" || path == prefix || path.hasPrefix(prefix + "/")
    }
}

extension PrivacyRuleTarget {
    /// True when both targets cover the same app bundle or the same host/path pair.
    public func coversSameTarget(as other: PrivacyRuleTarget) -> Bool {
        switch (self, other) {
        case (.application(let left, _), .application(let right, _)):
            return left == right
        case (.website(let left), .website(let right)):
            return left.host == right.host && left.pathPrefix == right.pathPrefix
        default:
            return false
        }
    }
}

public enum PrivacyRuleTarget: Codable, Equatable {
    case application(bundleIdentifier: String, displayName: String)
    case website(WebsitePattern)
}

public struct PrivacyRule: Codable, Identifiable, Equatable {
    public let id: UUID
    public var target: PrivacyRuleTarget
    public var enabled: Bool

    public init(id: UUID = UUID(), target: PrivacyRuleTarget, enabled: Bool = true) throws {
        if case .application(let bundleIdentifier, _) = target,
           bundleIdentifier.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) == nil {
            throw PrivacyRuleError.invalidApplication
        }
        self.id = id
        self.target = target
        self.enabled = enabled
    }

    public func matches(url: URL) -> Bool {
        guard enabled, case .website(let pattern) = target else { return false }
        return pattern.matches(url)
    }
}

public final class PrivacyRuleStore {
    private let fileURL: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nopal/privacy-rules.json")
    }

    public func all() throws -> [PrivacyRule] {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }

    public func add(_ rule: PrivacyRule) throws {
        lock.lock(); defer { lock.unlock() }
        var rules = try loadUnlocked()
        guard !rules.contains(where: { $0.target.coversSameTarget(as: rule.target) }) else {
            throw PrivacyRuleError.duplicate
        }
        rules.append(rule)
        try saveUnlocked(rules)
    }

    public func setEnabled(_ enabled: Bool, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        var rules = try loadUnlocked()
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        try saveUnlocked(rules)
    }

    public func remove(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try saveUnlocked(loadUnlocked().filter { $0.id != id })
    }

    /// Replaces all rules after validating their identifiers and targets. Callers should
    /// decode and validate an entire import before invoking this atomic file update.
    public func replaceAll(_ rules: [PrivacyRule]) throws {
        lock.lock(); defer { lock.unlock() }
        var targets: [PrivacyRuleTarget] = []
        var identifiers = Set<UUID>()
        for rule in rules {
            guard identifiers.insert(rule.id).inserted,
                  !targets.contains(where: { $0.coversSameTarget(as: rule.target) }) else {
                throw PrivacyRuleError.duplicate
            }
            targets.append(rule.target)
        }
        try saveUnlocked(rules)
    }

    private func loadUnlocked() throws -> [PrivacyRule] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do { return try JSONDecoder().decode([PrivacyRule].self, from: Data(contentsOf: fileURL)) }
        catch { throw PrivacyRuleError.persistence }
    }

    private func saveUnlocked(_ rules: [PrivacyRule]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(rules)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch { throw PrivacyRuleError.persistence }
    }
}
