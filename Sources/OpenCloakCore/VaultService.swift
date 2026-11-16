import AppKit
import Foundation
import LocalAuthentication
import Security

public struct VaultItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let imageURL: URL
    public let pending: Bool
    public let mounted: Bool
    public let mountPoint: URL?
    public let hasStoredCredential: Bool

    public init(id: String,
                name: String,
                imageURL: URL,
                pending: Bool,
                mounted: Bool,
                mountPoint: URL?,
                hasStoredCredential: Bool) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.pending = pending
        self.mounted = mounted
        self.mountPoint = mountPoint
        self.hasStoredCredential = hasStoredCredential
    }

    /// The phase comes from the operating system state, never from an optimistic claim.
    public var phase: VaultPhase {
        if pending { return .recoveryRequired }
        return mounted ? .mounted : .locked
    }
}

public enum VaultServiceError: LocalizedError, Equatable {
    case invalidName
    case invalidSize
    case alreadyExists
    case pendingVault
    case unsupportedFormat
    case notEncrypted
    case sourceInsideVaults
    case keychain(OSStatus)
    case authenticationCancelled
    case processFailed(String)
    case invalidCredential
    case busy
    case mountedVault
    case destinationExists
    case copyFailed
    case missingVault
    case notPending

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Use a name with letters, numbers, spaces, hyphens, or underscores."
        case .invalidSize:
            return "Choose a supported maximum size, such as 4g."
        case .alreadyExists:
            return "A vault with this name already exists. Choose another name."
        case .pendingVault:
            return "An interrupted vault with this name needs to be finished before you create another."
        case .unsupportedFormat:
            return "Choose a OpenCloak sparse bundle (a .sparsebundle package)."
        case .notEncrypted:
            return "This sparse bundle is not encrypted. OpenCloak only imports encrypted vaults."
        case .sourceInsideVaults:
            return "That vault is already in OpenCloak's vault folder."
        case .keychain(let status):
            return "The secure credential could not be stored or read (Keychain error \(status))."
        case .authenticationCancelled:
            return "Authentication did not complete. The vault stays locked."
        case .processFailed(let detail):
            return detail.isEmpty ? "macOS could not complete the encrypted disk operation." : detail
        case .invalidCredential:
            return "That password or recovery key did not unlock this vault."
        case .busy:
            return "This vault is in use. Close files in it and try again."
        case .mountedVault:
            return "Eject this vault before exporting a copy."
        case .destinationExists:
            return "A file with this name already exists at the destination. Choose a different folder."
        case .copyFailed:
            return "OpenCloak could not verify the completed copy. The original was left unchanged."
        case .missingVault:
            return "The selected vault could not be found."
        case .notPending:
            return "This vault setup was already completed."
        }
    }
}

public enum VaultNaming {
    public static let maximumLength = 40

    public static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= maximumLength,
              trimmed.range(of: "^[A-Za-z0-9][A-Za-z0-9 _-]*$", options: .regularExpression) != nil else {
            throw VaultServiceError.invalidName
        }
        return trimmed
    }

    public static func isValid(_ raw: String) -> Bool {
        (try? normalize(raw)) != nil
    }
}

public final class VaultService {
    public static let shared = VaultService()

    private struct MountedVolume {
        let device: String
        let mountPoint: URL?
    }

    private struct ProcessResult {
        let status: Int32
        let standardOutput: Data
        let standardError: String
    }

    private static let keychainService = "app.opencloak.vault"
    private static let ignoreSIGPIPE: Void = {
        // hdiutil may close its input before the password write finishes.
        _ = signal(SIGPIPE, SIG_IGN)
    }()

    private let fileManager = FileManager.default
    private let root: URL
    private let lock = NSRecursiveLock()
    private var mountedVolumes: [String: MountedVolume] = [:]

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCloak/Vaults", isDirectory: true)
    }

    // MARK: - Listing

    public func list() -> [VaultItem] {
        lock.lock(); defer { lock.unlock() }
        return listUnlocked()
    }

    private func listUnlocked() -> [VaultItem] {
        let urls = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        refreshMountedVolumes(for: urls)
        return urls
            .filter { $0.pathExtension == "sparsebundle" }
            .map { url -> VaultItem in
                let identifier = url.deletingPathExtension().lastPathComponent
                let pendingRange = identifier.range(of: ".pending.")
                let name = pendingRange.map { String(identifier[..<$0.lowerBound]) } ?? identifier
                let volume = mountedVolumes[identifier]
                return VaultItem(id: identifier,
                                 name: name,
                                 imageURL: url,
                                 pending: pendingRange != nil,
                                 mounted: volume != nil,
                                 mountPoint: volume?.mountPoint,
                                 hasStoredCredential: Self.hasStoredCredential(account: name))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshMountedVolumes(for urls: [URL]) {
        mountedVolumes.removeAll()
        guard let result = try? Self.run(arguments: ["info", "-plist"]), result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: result.standardOutput, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return }
        for image in images {
            guard let imagePath = image["image-path"] as? String,
                  let url = urls.first(where: {
                      $0.standardizedFileURL.path == URL(fileURLWithPath: imagePath).standardizedFileURL.path
                  }),
                  let entities = image["system-entities"] as? [[String: Any]],
                  let mountedEntity = entities.first(where: { $0["mount-point"] != nil }),
                  let device = mountedEntity["dev-entry"] as? String else { continue }
            let mountPoint = (mountedEntity["mount-point"] as? String).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            mountedVolumes[url.deletingPathExtension().lastPathComponent] = MountedVolume(device: device, mountPoint: mountPoint)
        }
    }

    // MARK: - Create

    /// Creates an encrypted sparse bundle in a temporary location, then atomically moves it into place.
    /// The credential is stored in the Keychain before creation so an interrupted temporary vault
    /// can still be finished instead of becoming unrecoverable.
    public func create(name rawName: String, size rawSize: String = "4g") throws -> String {
        lock.lock(); defer { lock.unlock() }
        let name = try VaultNaming.normalize(rawName)
        let size = try Self.normalizedSize(rawSize)
        try ensureRoot()

        let finalURL = root.appendingPathComponent("\(name).sparsebundle", isDirectory: true)
        guard !fileManager.fileExists(atPath: finalURL.path) else { throw VaultServiceError.alreadyExists }
        let hasPending = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.contains {
            $0.pathExtension == "sparsebundle" && $0.lastPathComponent.hasPrefix("\(name).pending.")
        } ?? false
        guard !hasPending else { throw VaultServiceError.pendingVault }

        let temporaryURL = root.appendingPathComponent("\(name).pending.\(UUID().uuidString).sparsebundle", isDirectory: true)
        let credential = try Self.randomCredential()
        try Self.store(credential, account: name, allowReplacement: false,
                       biometricOnly: OpenCloakPreferences().values.requireBiometricOnly)

        let result: ProcessResult
        do {
            result = try Self.run(arguments: ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", size,
                                              "-encryption", "AES-256", "-stdinpass", "-volname", name,
                                              "-o", temporaryURL.path],
                                  secret: credential)
        } catch {
            Self.deleteCredential(account: name)
            throw VaultServiceError.processFailed("The disk-image tool could not be started.")
        }

        guard result.status == 0, fileManager.fileExists(atPath: temporaryURL.path) else {
            if !fileManager.fileExists(atPath: temporaryURL.path) { Self.deleteCredential(account: name) }
            throw VaultServiceError.processFailed(Self.message(from: result.standardError))
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            // Keep the temporary vault and its Keychain credential so the user can finish setup.
            throw VaultServiceError.processFailed("The vault was created but could not be finalized. Finish setup from the Vaults list.")
        }
        return credential
    }

    // MARK: - Unlock and lock

    public func unlock(_ item: VaultItem, credential provided: String? = nil) throws {
        lock.lock(); defer { lock.unlock() }
        guard fileManager.fileExists(atPath: item.imageURL.path) else { throw VaultServiceError.missingVault }
        if mountedVolumes[item.id] != nil { return }

        let secret = try Self.credential(for: item, provided: provided)
        let result = try Self.run(arguments: ["attach", "-plist", "-nobrowse", "-noautoopen",
                                              "-stdinpass", item.imageURL.path],
                                  secret: secret)
        guard result.status == 0 else { throw Self.attachError(from: result) }
        guard let volume = Self.volume(from: result.standardOutput) else {
            throw VaultServiceError.processFailed("macOS mounted the vault but did not report a volume.")
        }

        if provided != nil {
            do {
                try Self.store(secret, account: item.name, allowReplacement: true,
                               biometricOnly: OpenCloakPreferences().values.requireBiometricOnly)
            } catch {
                _ = try? Self.run(arguments: ["detach", volume.device])
                throw error
            }
        }
        mountedVolumes[item.id] = volume
    }

    public func lockVault(_ item: VaultItem) throws {
        lock.lock(); defer { lock.unlock() }
        if mountedVolumes[item.id] == nil {
            // Refresh once so a vault mounted before this service instance existed can still be ejected.
            _ = listUnlocked()
        }
        guard let volume = mountedVolumes[item.id] else { return }
        let result = try Self.run(arguments: ["detach", volume.device])
        guard result.status == 0 else {
            let text = result.standardError.lowercased()
            if text.contains("busy") || text.contains("in use") {
                throw VaultServiceError.busy
            }
            throw VaultServiceError.processFailed(Self.message(from: result.standardError))
        }
        mountedVolumes.removeValue(forKey: item.id)
    }

    @discardableResult
    public func lockAllMounted() -> [VaultItem] {
        lock.lock(); defer { lock.unlock() }
        var failures: [VaultItem] = []
        for item in listUnlocked().filter(\.mounted) {
            do { try lockVault(item) }
            catch { failures.append(item) }
        }
        return failures
    }

    /// Removes only credentials owned by OpenCloak vaults. Call after all images are unmounted.
    public func clearStoredCredentials() throws {
        lock.lock(); defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.keychainService,
                                    kSecUseDataProtectionKeychain as String: true]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultServiceError.keychain(status)
        }
    }

    // MARK: - Interrupted creation

    public func finishInterruptedCreation(_ item: VaultItem, credential provided: String? = nil) throws -> VaultItem? {
        lock.lock(); defer { lock.unlock() }
        guard item.pending else { throw VaultServiceError.notPending }
        guard fileManager.fileExists(atPath: item.imageURL.path) else { throw VaultServiceError.missingVault }
        let finalURL = root.appendingPathComponent("\(item.name).sparsebundle", isDirectory: true)
        guard !fileManager.fileExists(atPath: finalURL.path) else { throw VaultServiceError.alreadyExists }

        let secret = try Self.credential(for: item, provided: provided)
        let attach = try Self.run(arguments: ["attach", "-plist", "-nobrowse", "-noautoopen",
                                              "-stdinpass", item.imageURL.path],
                                  secret: secret)
        guard attach.status == 0 else { throw Self.attachError(from: attach) }
        guard let volume = Self.volume(from: attach.standardOutput) else {
            throw VaultServiceError.processFailed("macOS mounted the temporary vault but did not report a volume.")
        }
        let detach = try Self.run(arguments: ["detach", volume.device])
        guard detach.status == 0 else {
            mountedVolumes[item.id] = volume
            throw VaultServiceError.busy
        }

        if provided != nil {
            try Self.store(secret, account: item.name, allowReplacement: true,
                           biometricOnly: OpenCloakPreferences().values.requireBiometricOnly)
        }
        do {
            try fileManager.moveItem(at: item.imageURL, to: finalURL)
        } catch {
            throw VaultServiceError.processFailed("The vault is valid but could not be finalized. Try again.")
        }
        mountedVolumes.removeValue(forKey: item.id)
        return listUnlocked().first { $0.name == item.name && !$0.pending }
    }

    // MARK: - Import and export

    /// Imports a copy of an encrypted sparse bundle. The source is never moved, replaced, or deleted.
    public func importVault(from source: URL, as rawName: String? = nil) throws -> VaultItem {
        lock.lock(); defer { lock.unlock() }
        let sourceURL = source.standardizedFileURL
        guard sourceURL.pathExtension == "sparsebundle" else { throw VaultServiceError.unsupportedFormat }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fileManager.fileExists(atPath: sourceURL.appendingPathComponent("Info.plist").path) else {
            throw VaultServiceError.unsupportedFormat
        }
        let baseName = try VaultNaming.normalize(rawName ?? sourceURL.deletingPathExtension().lastPathComponent)
        guard !Self.isInside(sourceURL, root) else { throw VaultServiceError.sourceInsideVaults }
        try ensureRoot()

        let destination = root.appendingPathComponent("\(baseName).sparsebundle", isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { throw VaultServiceError.alreadyExists }
        guard Self.isEncryptedImage(sourceURL) else { throw VaultServiceError.notEncrypted }

        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
        } catch {
            throw VaultServiceError.copyFailed
        }
        guard Self.copyMatches(sourceURL, destination) else {
            try? fileManager.removeItem(at: destination)
            throw VaultServiceError.copyFailed
        }
        guard let item = listUnlocked().first(where: { $0.id == baseName && !$0.pending }) else {
            throw VaultServiceError.copyFailed
        }
        return item
    }

    /// Writes a verified copy of a locked vault into a user-selected folder. The original stays untouched.
    public func export(_ item: VaultItem, to directory: URL) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !item.pending else { throw VaultServiceError.notPending }
        guard fileManager.fileExists(atPath: item.imageURL.path) else { throw VaultServiceError.missingVault }
        if mountedVolumes[item.id] == nil { _ = listUnlocked() }
        guard mountedVolumes[item.id] == nil else { throw VaultServiceError.mountedVault }

        let targetDirectory = directory.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: targetDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw VaultServiceError.copyFailed
        }
        let destination = targetDirectory.appendingPathComponent("\(item.name).sparsebundle", isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else { throw VaultServiceError.destinationExists }

        do {
            try fileManager.copyItem(at: item.imageURL, to: destination)
        } catch {
            throw VaultServiceError.copyFailed
        }
        guard Self.copyMatches(item.imageURL, destination) else {
            try? fileManager.removeItem(at: destination)
            throw VaultServiceError.copyFailed
        }
        return destination
    }

    // MARK: - Helpers

    private func ensureRoot() throws {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        } catch {
            throw VaultServiceError.processFailed("OpenCloak could not prepare its vault folder.")
        }
    }

    private static func normalizedSize(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard value.range(of: "^[0-9]{1,5}[mgt]$", options: .regularExpression) != nil else {
            throw VaultServiceError.invalidSize
        }
        return value
    }

    private static func randomCredential() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw VaultServiceError.processFailed("The system random generator could not produce a vault key.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func isInside(_ candidate: URL, _ directory: URL) -> Bool {
        let child = candidate.standardizedFileURL.path
        let parent = directory.standardizedFileURL.path
        return child == parent || child.hasPrefix(parent.hasSuffix("/") ? parent : parent + "/")
    }

    private static func isEncryptedImage(_ url: URL) -> Bool {
        guard let result = try? run(arguments: ["isencrypted", url.path]), result.status == 0 else { return false }
        let answer = String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return answer == "yes" || answer == "true" || answer == "1"
    }

    private static func copyMatches(_ source: URL, _ destination: URL) -> Bool {
        guard let sourceStats = directoryStats(source), let destinationStats = directoryStats(destination) else {
            return false
        }
        return sourceStats.files == destinationStats.files && sourceStats.bytes == destinationStats.bytes
    }

    private static func directoryStats(_ url: URL) -> (files: Int, bytes: Int64)? {
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                             options: [],
                                                             errorHandler: nil) else { return nil }
        var files = 0
        var bytes: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    private static func message(from standardError: String) -> String {
        let condensed = standardError
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .replacingOccurrences(of: "hdiutil: ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !condensed.isEmpty else {
            return "macOS could not complete the encrypted disk operation."
        }
        return String(condensed.prefix(180))
    }

    private static func attachError(from result: ProcessResult) -> VaultServiceError {
        let text = result.standardError.lowercased()
        if text.contains("authentication error") || text.contains("incorrect") || text.contains("wrong password") {
            return .invalidCredential
        }
        if text.contains("busy") || text.contains("in use") {
            return .busy
        }
        return .processFailed(message(from: result.standardError))
    }

    private static func volume(from data: Data) -> MountedVolume? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountedEntity = entities.first(where: { $0["mount-point"] != nil }),
              let device = mountedEntity["dev-entry"] as? String else { return nil }
        let mountPoint = (mountedEntity["mount-point"] as? String).map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        return MountedVolume(device: device, mountPoint: mountPoint)
    }

    // MARK: - Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    private static func hasStoredCredential(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private static func accessControl(biometricOnly: Bool) -> SecAccessControl? {
        var flags: SecAccessControlCreateFlags = .userPresence
        if biometricOnly {
            var error: NSError?
            if LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
                flags = .biometryCurrentSet
            }
        }
        return SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                              kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                              flags,
                                              nil)
    }

    private static func store(_ secret: String, account: String, allowReplacement: Bool, biometricOnly: Bool) throws {
        guard let access = accessControl(biometricOnly: biometricOnly) else {
            throw VaultServiceError.keychain(errSecParam)
        }
        let context = LAContext()
        context.localizedReason = "Save the OpenCloak vault credential"
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessControl as String] = access
        query[kSecUseAuthenticationContext as String] = context

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            guard allowReplacement else { throw VaultServiceError.keychain(addStatus) }
            var key = baseQuery(account: account)
            key[kSecUseAuthenticationContext as String] = context
            let update: [String: Any] = [kSecValueData as String: Data(secret.utf8),
                                         kSecAttrAccessControl as String: access]
            let updateStatus = SecItemUpdate(key as CFDictionary, update as CFDictionary)
            if updateStatus == errSecSuccess { return }
            // Never lose a verified recovery credential because an access-control update was rejected.
            let dataStatus = SecItemUpdate(key as CFDictionary,
                                           [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
            guard dataStatus == errSecSuccess else { throw VaultServiceError.keychain(dataStatus) }
            return
        }
        guard addStatus == errSecSuccess else { throw VaultServiceError.keychain(addStatus) }
    }

    private static func read(account: String) throws -> String {
        let context = LAContext()
        context.localizedReason = "Unlock the OpenCloak vault"
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecUserCanceled || status == errSecAuthFailed {
            throw VaultServiceError.authenticationCancelled
        }
        guard status == errSecSuccess, let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw VaultServiceError.keychain(status)
        }
        return secret
    }

    private static func credential(for item: VaultItem, provided: String?) throws -> String {
        if let provided, !provided.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return provided
        }
        return try read(account: item.name)
    }

    private static func deleteCredential(account: String) {
        var query = baseQuery(account: account)
        query[kSecUseAuthenticationContext as String] = LAContext()
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Process adapter

    private static func run(arguments: [String], secret: String? = nil) throws -> ProcessResult {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            throw VaultServiceError.processFailed("The disk-image tool could not be started.")
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if let secret {
                var payload = Data(secret.utf8)
                payload.append(0)
                try? standardInput.fileHandleForWriting.write(contentsOf: payload)
            }
            try? standardInput.fileHandleForWriting.close()
        }

        let group = DispatchGroup()
        var outputData = Data()
        var errorData = Data()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        return ProcessResult(status: process.terminationStatus,
                             standardOutput: outputData,
                             standardError: String(data: errorData, encoding: .utf8) ?? "")
    }
}
