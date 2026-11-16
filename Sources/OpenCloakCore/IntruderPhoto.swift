import Foundation

public enum IntruderCapturePolicy {
    public static let minimumInterval: TimeInterval = 3
    public static let defaultLimit = 25

    public static func shouldCapture(isEnabled: Bool,
                                     authenticationSucceeded: Bool,
                                     lastCapture: Date?,
                                     now: Date,
                                     minimumInterval: TimeInterval = minimumInterval) -> Bool {
        guard isEnabled, !authenticationSucceeded else { return false }
        guard let lastCapture else { return true }
        return now.timeIntervalSince(lastCapture) >= minimumInterval
    }

    /// Files are expected newest first. Returns the oldest files that exceed the limit.
    public static func filesToDelete(_ files: [URL], limit: Int = defaultLimit) -> [URL] {
        guard files.count > limit else { return [] }
        return Array(files.suffix(files.count - limit))
    }
}

public struct IntruderPhotoStore {
    public let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCloak/Intruder", isDirectory: true)
    }

    @discardableResult
    public func record(_ jpeg: Data, date: Date = Date(), limit: Int = IntruderCapturePolicy.defaultLimit) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let name = "intruder-\(Int(date.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).jpg"
        let url = directory.appendingPathComponent(name)
        try jpeg.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for stale in IntruderCapturePolicy.filesToDelete(all(), limit: limit) {
            try? fileManager.removeItem(at: stale)
        }
        return url
    }

    /// Newest first, by modification date.
    public func all() -> [URL] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { left, right in
                let a = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
    }

    public func deleteAll() throws {
        for url in all() { try fileManager.removeItem(at: url) }
    }
}
