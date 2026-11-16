import AppKit
import Foundation

public struct HiddenApp: Codable, Identifiable, Equatable {
    public let bundleIdentifier: String
    public let name: String
    public let originalPath: String
    public let byteCount: Int64
    public let hiddenAt: Date

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String,
                name: String,
                originalPath: String,
                byteCount: Int64,
                hiddenAt: Date = Date()) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.originalPath = originalPath
        self.byteCount = byteCount
        self.hiddenAt = hiddenAt
    }
}

public enum HiddenAppError: LocalizedError, Equatable {
    case notAnApplication
    case protectedLocation
    case alreadyHidden
    case missingBundle
    case appIsRunning
    case verificationFailed
    case destinationExists
    case processFailed(String)
    case imageTool(String)

    public var errorDescription: String? {
        switch self {
        case .notAnApplication:
            return "Choose an app bundle to hide."
        case .protectedLocation:
            return "OpenCloak does not hide apps from a system or protected location."
        case .alreadyHidden:
            return "This app is already hidden."
        case .missingBundle:
            return "The app bundle could not be found at that path."
        case .appIsRunning:
            return "Quit the app before hiding it so its files can be copied safely."
        case .verificationFailed:
            return "OpenCloak could not verify the encrypted copy, so the original was left in place."
        case .destinationExists:
            return "Something already exists at the app's original path. Move it aside before unhiding."
        case .processFailed(let detail):
            return detail
        case .imageTool(let detail):
            return detail
        }
    }
}

public enum HiddenAppPolicy {
    public static let forbiddenPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/private/", "/Library/"]

    public static func isHideable(path: String,
                                  bundleIdentifier: String?,
                                  ownBundleIdentifier: String = "app.opencloak.privacy",
                                  ownRoot: String? = nil) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard candidate.hasSuffix(".app") || candidate.contains(".app/") else { return false }
        guard !candidate.contains(".app/") else { return false }
        if let ownRoot {
            let root = URL(fileURLWithPath: ownRoot).standardizedFileURL.path
            if candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return false }
        }
        for prefix in forbiddenPrefixes where candidate.hasPrefix(prefix) { return false }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty,
              bundleIdentifier != ownBundleIdentifier,
              bundleIdentifier.range(of: "^[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil else {
            return false
        }
        return true
    }

    public static func bundleIdentifier(at url: URL) -> String? {
        Bundle(url: url)?.bundleIdentifier
    }

    public static func displayName(at url: URL) -> String {
        let bundle = Bundle(url: url)
        return bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
    }
}

/// Moves an app bundle into an encrypted, non-browsing sparse bundle. Launch Services stops seeing
/// the original path, so the app disappears from Spotlight, Launchpad, and the Dock (the Dock tile
/// clears on the next Dock refresh). Unhiding restores the bundle to the exact original path.
public final class HiddenAppService {
    private let root: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCloak/Hidden", isDirectory: true)
    }

    public var imageURL: URL { root.appendingPathComponent("Hidden.sparsebundle", isDirectory: true) }
    private var manifestURL: URL { root.appendingPathComponent("hidden-apps.json") }

    public func all() throws -> [HiddenApp] {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }

    public func hide(appAt url: URL, credential: String) throws -> HiddenApp {
        lock.lock(); defer { lock.unlock() }
        let source = url.standardizedFileURL
        guard fileManager.fileExists(atPath: source.path) else { throw HiddenAppError.missingBundle }
        guard let bundleIdentifier = HiddenAppPolicy.bundleIdentifier(at: source),
              HiddenAppPolicy.isHideable(path: source.path,
                                         bundleIdentifier: bundleIdentifier,
                                         ownRoot: root.path) else {
            throw HiddenAppError.notAnApplication
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .allSatisfy(\.isTerminated) else { throw HiddenAppError.appIsRunning }
        var hidden = try loadUnlocked()
        guard !hidden.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            throw HiddenAppError.alreadyHidden
        }
        guard let sourceStats = FileTreeStats.measure(source) else { throw HiddenAppError.missingBundle }
        try ensureRoot()

        let volume = try mountedImage(credential: credential, createIfNeeded: true)
        guard let mountPoint = volume.mountPoint else { throw HiddenAppError.imageTool("The encrypted image mounted without a usable volume.") }
        let destination = mountPoint.appendingPathComponent(source.lastPathComponent)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw HiddenAppError.imageTool("An app with this name is already in the encrypted image.")
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw HiddenAppError.imageTool("OpenCloak could not copy the app into its encrypted image.")
        }
        guard FileTreeStats.matches(source, destination),
              (FileTreeStats.measure(destination)?.bytes ?? -1) == sourceStats.bytes else {
            try? fileManager.removeItem(at: destination)
            throw HiddenAppError.verificationFailed
        }

        do {
            try fileManager.removeItem(at: source)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw HiddenAppError.processFailed("OpenCloak copied the app but could not remove the original. Nothing was hidden.")
        }

        let record = HiddenApp(bundleIdentifier: bundleIdentifier,
                               name: HiddenAppPolicy.displayName(at: source),
                               originalPath: source.path,
                               byteCount: sourceStats.bytes)
        hidden.append(record)
        do {
            try saveUnlocked(hidden)
        } catch {
            // Put the app back rather than reporting a hide that was never recorded.
            try? fileManager.copyItem(at: destination, to: source)
            try? fileManager.removeItem(at: destination)
            throw error
        }
        writeNoIndexMarker(at: mountPoint)
        try? ImageTool.detachAll(ofImageAt: imageURL)
        return record
    }

    public func unhide(_ app: HiddenApp, credential: String) throws {
        lock.lock(); defer { lock.unlock() }
        var hidden = try loadUnlocked()
        guard hidden.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
            throw HiddenAppError.alreadyHidden
        }
        let destination = URL(fileURLWithPath: app.originalPath)
        guard !fileManager.fileExists(atPath: destination.path) else { throw HiddenAppError.destinationExists }
        guard fileManager.fileExists(atPath: destination.deletingLastPathComponent().path) else {
            throw HiddenAppError.destinationExists
        }
        let volume = try mountedImage(credential: credential, createIfNeeded: false)
        guard let mountPoint = volume.mountPoint else { throw HiddenAppError.imageTool("The encrypted image mounted without a usable volume.") }
        let source = mountPoint.appendingPathComponent(destination.lastPathComponent)
        guard fileManager.fileExists(atPath: source.path) else { throw HiddenAppError.missingBundle }
        guard let sourceStats = FileTreeStats.measure(source), sourceStats.bytes == app.byteCount else {
            throw HiddenAppError.verificationFailed
        }

        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            throw HiddenAppError.processFailed("OpenCloak could not restore the app. It stays encrypted.")
        }
        guard FileTreeStats.matches(source, destination) else {
            try? fileManager.removeItem(at: destination)
            throw HiddenAppError.verificationFailed
        }

        try? fileManager.removeItem(at: source)
        hidden.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        try saveUnlocked(hidden)
        try? ImageTool.detachAll(ofImageAt: imageURL)
    }

    /// Mounts the encrypted image and returns the app URL without restoring it to Applications.
    /// The caller must call `closeTemporaryUse` after the launched app exits.
    public func openTemporarily(_ app: HiddenApp, credential: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard try loadUnlocked().contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else {
            throw HiddenAppError.missingBundle
        }
        let volume = try mountedImage(credential: credential, createIfNeeded: false)
        guard let mountPoint = volume.mountPoint else {
            throw HiddenAppError.imageTool("The encrypted image mounted without a usable volume.")
        }
        let appURL = mountPoint.appendingPathComponent(URL(fileURLWithPath: app.originalPath).lastPathComponent)
        guard FileManager.default.fileExists(atPath: appURL.path),
              HiddenAppPolicy.bundleIdentifier(at: appURL) == app.bundleIdentifier else {
            throw HiddenAppError.verificationFailed
        }
        return appURL
    }

    public func closeTemporaryUse() throws {
        lock.lock(); defer { lock.unlock() }
        try ImageTool.detachAll(ofImageAt: imageURL)
    }

    public func relockIfMounted() throws {
        try closeTemporaryUse()
    }

    // MARK: - Internals

    private func ensureRoot() throws {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            throw HiddenAppError.processFailed("OpenCloak could not prepare its hidden-app folder.")
        }
    }

    private func mountedImage(credential: String, createIfNeeded: Bool) throws -> DiskImageVolume {
        if let existing = ImageTool.mountedVolumes(forImageAt: imageURL).first,
           existing.mountPoint != nil {
            return existing
        }
        if !fileManager.fileExists(atPath: imageURL.path) {
            guard createIfNeeded else { throw HiddenAppError.imageTool("No hidden apps are stored on this Mac.") }
            try ensureRoot()
            do {
                try ImageTool.create(at: imageURL, volumeName: "OpenCloak Hidden", size: "80g", credential: credential)
            } catch {
                throw HiddenAppError.imageTool(error.localizedDescription)
            }
        }
        do {
            return try ImageTool.attach(imageURL, credential: credential)
        } catch {
            throw HiddenAppError.imageTool(error.localizedDescription)
        }
    }

    private func writeNoIndexMarker(at mountPoint: URL) {
        let marker = mountPoint.appendingPathComponent(".metadata_never_index")
        if !fileManager.fileExists(atPath: marker.path) {
            fileManager.createFile(atPath: marker.path, contents: Data(), attributes: nil)
        }
    }

    private func loadUnlocked() throws -> [HiddenApp] {
        guard fileManager.fileExists(atPath: manifestURL.path) else { return [] }
        guard let data = try? Data(contentsOf: manifestURL),
              let apps = try? JSONDecoder().decode([HiddenApp].self, from: data) else {
            throw HiddenAppError.processFailed("OpenCloak could not read its hidden-app record. No app was changed.")
        }
        return apps
    }

    private func saveUnlocked(_ apps: [HiddenApp]) throws {
        do {
            try ensureRoot()
            let data = try JSONEncoder().encode(apps)
            try data.write(to: manifestURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            throw HiddenAppError.processFailed("OpenCloak could not save its hidden-app record.")
        }
    }
}
