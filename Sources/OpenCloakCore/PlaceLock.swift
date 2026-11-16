import Foundation

public struct LockedItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public let originalPath: String
    public let imageName: String
    public let isDirectory: Bool
    public let byteCount: Int64
    public let fileCount: Int
    public let lockedAt: Date

    public var name: String { URL(fileURLWithPath: originalPath).lastPathComponent }

    public init(id: UUID = UUID(),
                originalPath: String,
                imageName: String,
                isDirectory: Bool,
                byteCount: Int64,
                fileCount: Int,
                lockedAt: Date = Date()) {
        self.id = id
        self.originalPath = originalPath
        self.imageName = imageName
        self.isDirectory = isDirectory
        self.byteCount = byteCount
        self.fileCount = fileCount
        self.lockedAt = lockedAt
    }
}

public enum PlaceLockError: LocalizedError, Equatable {
    case protectedPath
    case missingItem
    case alreadyLocked
    case verificationFailed
    case destinationExists
    case missingParent
    case processFailed(String)
    case imageTool(String)

    public var errorDescription: String? {
        switch self {
        case .protectedPath:
            return "OpenCloak does not lock this location. Choose a folder or file inside your home folder or on an external volume."
        case .missingItem:
            return "That folder or file could not be found."
        case .alreadyLocked:
            return "This item is already locked by OpenCloak."
        case .verificationFailed:
            return "OpenCloak could not verify the encrypted copy, so the original was left in place."
        case .destinationExists:
            return "Something already exists at the original path. Move it aside before unlocking."
        case .missingParent:
            return "The folder that used to contain this item no longer exists."
        case .processFailed(let detail):
            return detail
        case .imageTool(let detail):
            return detail
        }
    }
}

public enum PlaceLockPolicy {
    public static let forbiddenExact = ["/", "/Applications", "/Library", "/System", "/Users", "/Volumes",
                                        "/bin", "/sbin", "/usr", "/private", "/etc", "/var", "/tmp", "/opt"]
    public static let forbiddenPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/private/", "/Library/"]

    public static func isAllowed(path: String,
                                 home: String = NSHomeDirectory(),
                                 ownRoot: String? = nil) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard !forbiddenExact.contains(candidate) else { return false }
        for prefix in forbiddenPrefixes where candidate.hasPrefix(prefix) { return false }
        if let ownRoot {
            let root = URL(fileURLWithPath: ownRoot).standardizedFileURL.path
            if candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return false }
        }
        let standardHomeFolders = ["Desktop", "Documents", "Downloads", "Library", "Pictures", "Movies", "Music"]
            .map { URL(fileURLWithPath: home).appendingPathComponent($0).standardizedFileURL.path }
        if standardHomeFolders.contains(candidate) || candidate == URL(fileURLWithPath: home).standardizedFileURL.path {
            return false
        }
        return true
    }

    public static func imageSize(forBytes bytes: Int64) -> String {
        let megabytes = max(100, Int((Double(max(bytes, 0)) * 1.5 / 1_048_576.0).rounded(.up)) + 32)
        return "\(min(megabytes, 200_000))m"
    }
}

/// Encrypts a folder or file in place: the plaintext is copied into a OpenCloak-owned AES-256 sparse
/// bundle, verified, and only then removed. Unlocking writes it back to the exact original path.
public final class PlaceLockService {
    private let root: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCloak/Locked", isDirectory: true)
    }

    private var manifestURL: URL { root.appendingPathComponent("locked-items.json") }

    public func all() throws -> [LockedItem] {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }

    public func lock(url: URL, credential: String) throws -> LockedItem {
        lock.lock(); defer { lock.unlock() }
        let source = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw PlaceLockError.missingItem
        }
        guard PlaceLockPolicy.isAllowed(path: source.path, ownRoot: root.path) else {
            throw PlaceLockError.protectedPath
        }
        var items = try loadUnlocked()
        guard !items.contains(where: { $0.originalPath == source.path }) else { throw PlaceLockError.alreadyLocked }
        guard let stats = FileTreeStats.measure(source) else { throw PlaceLockError.missingItem }
        try ensureRoot()

        let identifier = UUID()
        let imageURL = root.appendingPathComponent("\(identifier.uuidString).sparsebundle", isDirectory: true)
        do {
            try ImageTool.create(at: imageURL,
                                 volumeName: "OpenCloak Locked",
                                 size: PlaceLockPolicy.imageSize(forBytes: stats.bytes),
                                 credential: credential)
        } catch {
            throw PlaceLockError.imageTool(error.localizedDescription)
        }
        let volume: DiskImageVolume
        do {
            volume = try ImageTool.attach(imageURL, credential: credential)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            throw PlaceLockError.imageTool(error.localizedDescription)
        }
        guard let mountPoint = volume.mountPoint else {
            try? ImageTool.detachAll(ofImageAt: imageURL)
            throw PlaceLockError.imageTool("The encrypted image mounted without a usable volume.")
        }

        let destination = mountPoint.appendingPathComponent(source.lastPathComponent)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            try? ImageTool.detachAll(ofImageAt: imageURL)
            try? fileManager.removeItem(at: imageURL)
            throw PlaceLockError.imageTool("OpenCloak could not copy the item into its encrypted image. Nothing was locked.")
        }
        guard FileTreeStats.matches(source, destination) else {
            try? fileManager.removeItem(at: destination)
            try? ImageTool.detachAll(ofImageAt: imageURL)
            try? fileManager.removeItem(at: imageURL)
            throw PlaceLockError.verificationFailed
        }
        do {
            try fileManager.removeItem(at: source)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? ImageTool.detachAll(ofImageAt: imageURL)
            try? fileManager.removeItem(at: imageURL)
            throw PlaceLockError.processFailed("OpenCloak copied the item but could not remove the original. Nothing was locked.")
        }

        let record = LockedItem(originalPath: source.path,
                                imageName: imageURL.lastPathComponent,
                                isDirectory: isDirectory.boolValue,
                                byteCount: stats.bytes,
                                fileCount: stats.files,
                                lockedAt: Date())
        items.append(record)
        do {
            try saveUnlocked(items)
        } catch {
            try? fileManager.copyItem(at: destination, to: source)
            throw error
        }
        writeNoIndexMarker(at: mountPoint)
        do {
            try ImageTool.detachAll(ofImageAt: imageURL)
        } catch {
            // The record exists, so the item is visible as locked and can be retried later.
            throw PlaceLockError.processFailed("The item is encrypted and recorded, but macOS reported the image as busy. Try unlocking it again.")
        }
        _ = identifier
        return record
    }

    public func unlock(_ item: LockedItem, credential: String) throws {
        lock.lock(); defer { lock.unlock() }
        var items = try loadUnlocked()
        guard items.contains(where: { $0.id == item.id }) else { throw PlaceLockError.missingItem }
        let imageURL = root.appendingPathComponent(item.imageName, isDirectory: true)
        guard fileManager.fileExists(atPath: imageURL.path) else {
            throw PlaceLockError.imageTool("The encrypted image for this item is missing.")
        }
        let volume: DiskImageVolume
        if let existing = ImageTool.mountedVolumes(forImageAt: imageURL).first {
            volume = existing
        } else {
            do { volume = try ImageTool.attach(imageURL, credential: credential) }
            catch { throw PlaceLockError.imageTool(error.localizedDescription) }
        }
        guard let mountPoint = volume.mountPoint else {
            throw PlaceLockError.imageTool("The encrypted image mounted without a usable volume.")
        }
        let sourceName = URL(fileURLWithPath: item.originalPath).lastPathComponent
        let source = mountPoint.appendingPathComponent(sourceName)
        guard FileTreeStats.measure(source) != nil else { throw PlaceLockError.missingItem }
        let destination = URL(fileURLWithPath: item.originalPath)
        guard !fileManager.fileExists(atPath: destination.path) else { throw PlaceLockError.destinationExists }
        guard fileManager.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw PlaceLockError.missingParent
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw PlaceLockError.processFailed("OpenCloak could not restore this item. It stays encrypted.")
        }
        guard let restored = FileTreeStats.measure(destination),
              restored.bytes == item.byteCount,
              FileTreeStats.matches(source, destination) else {
            try? fileManager.removeItem(at: destination)
            throw PlaceLockError.verificationFailed
        }
        try? fileManager.removeItem(at: source)
        items.removeAll { $0.id == item.id }
        do {
            try saveUnlocked(items)
        } catch {
            // Data is restored; keep the image so nothing is lost if the record cannot be updated.
            throw PlaceLockError.processFailed("The item was restored, but OpenCloak could not update its record. It stays in the list.")
        }
        do {
            try ImageTool.detachAll(ofImageAt: imageURL)
        } catch {
            throw PlaceLockError.processFailed("The item was restored, but the image stayed mounted because macOS reported it busy.")
        }
        try? fileManager.removeItem(at: imageURL)
    }

    public func relockAllMounted() throws {
        lock.lock(); defer { lock.unlock() }
        for item in try loadUnlocked() {
            let imageURL = root.appendingPathComponent(item.imageName, isDirectory: true)
            if !ImageTool.mountedVolumes(forImageAt: imageURL).isEmpty {
                try ImageTool.detachAll(ofImageAt: imageURL)
            }
        }
    }

    // MARK: - Internals

    private func ensureRoot() throws {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw PlaceLockError.processFailed("OpenCloak could not prepare its locked-item folder.")
        }
    }

    private func writeNoIndexMarker(at mountPoint: URL) {
        let marker = mountPoint.appendingPathComponent(".metadata_never_index")
        if !fileManager.fileExists(atPath: marker.path) {
            fileManager.createFile(atPath: marker.path, contents: Data(), attributes: nil)
        }
    }

    private func loadUnlocked() throws -> [LockedItem] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        guard let data = try? Data(contentsOf: manifestURL),
              let items = try? JSONDecoder().decode([LockedItem].self, from: data) else {
            throw PlaceLockError.processFailed("OpenCloak could not read its locked-item record. Nothing was changed.")
        }
        return items
    }

    private func saveUnlocked(_ items: [LockedItem]) throws {
        do {
            try ensureRoot()
            let data = try JSONEncoder().encode(items)
            try data.write(to: manifestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            throw PlaceLockError.processFailed("OpenCloak could not save its locked-item record.")
        }
    }
}
