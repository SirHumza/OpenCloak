import Foundation

public enum EventCategory: String, Codable, Equatable {
    case vault
    case privacy
    case system
}

public enum EventOutcome: String, Codable, Equatable {
    case success
    case failure
    case notice
}

public struct EventRecord: Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let category: EventCategory
    public let outcome: EventOutcome
    public let summary: String

    public init(id: UUID = UUID(), date: Date = Date(), category: EventCategory, outcome: EventOutcome, summary: String) {
        self.id = id
        self.date = date
        self.category = category
        self.outcome = outcome
        self.summary = summary
    }
}

public enum EventLogError: LocalizedError {
    case persistence

    public var errorDescription: String? {
        "OpenCloak could not update the local activity history."
    }
}

/// Stores a small, local history of actions and outcomes.
///
/// Records never include file names, vault names, browsing URLs, or credentials.
/// The history is capped and can be pruned by age or cleared by the user.
public final class EventLog {
    public static let maximumEntries = 250
    private let fileURL: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCloak/events.json")
    }

    public func all() throws -> [EventRecord] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    public func recent(limit: Int = 10) throws -> [EventRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(try load().prefix(max(0, limit)))
    }

    public func record(_ record: EventRecord) throws {
        lock.lock(); defer { lock.unlock() }
        var records = try load()
        records.insert(record, at: 0)
        if records.count > Self.maximumEntries {
            records = Array(records.prefix(Self.maximumEntries))
        }
        try save(records)
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try save([])
    }

    public func prune(olderThanDays days: Int, now: Date = Date()) throws {
        guard days > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -days, to: now) else { return }
        try save(try load().filter { $0.date >= cutoff })
    }

    private func load() throws -> [EventRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([EventRecord].self, from: data)
        } catch {
            // Preserve unreadable history instead of deleting it, then start a fresh local log.
            quarantine()
            return []
        }
    }

    private func quarantine() {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("events.unreadable.\(stamp).json")
        try? fileManager.moveItem(at: fileURL, to: backup)
    }

    private func save(_ records: [EventRecord]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw EventLogError.persistence
        }
    }
}
