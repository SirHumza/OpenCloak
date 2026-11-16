import CommonCrypto
import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum OpenCloakCredentialError: LocalizedError, Equatable {
    case passwordTooShort
    case passwordMismatch
    case incorrectPassword
    case notConfigured
    case keychain(OSStatus)
    case authenticationCancelled
    case deviceKeyUnavailable
    case persistence

    public var errorDescription: String? {
        switch self {
        case .passwordTooShort:
            return "Use at least \(OpenCloakPasswordHasher.minimumCharacters) characters for the OpenCloak password."
        case .passwordMismatch:
            return "The two passwords do not match."
        case .incorrectPassword:
            return "That OpenCloak password is not correct."
        case .notConfigured:
            return "No OpenCloak password is configured on this Mac."
        case .keychain(let status):
            return "The OpenCloak key could not be stored or read (Keychain error \(status))."
        case .authenticationCancelled:
            return "Authentication did not complete."
        case .deviceKeyUnavailable:
            return "Touch ID is not available for OpenCloak on this Mac."
        case .persistence:
            return "OpenCloak could not save its password record."
        }
    }
}

public struct WrappedMasterKey: Codable, Equatable {
    public var salt: Data
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data

    public init(salt: Data, nonce: Data, ciphertext: Data, tag: Data) {
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

/// A password record never contains the password or the master key in the clear. The master key is
/// wrapped with an AES-GCM key derived from the password, and the password itself is only checked
/// through a PBKDF2 verifier.
public struct OpenCloakPasswordRecord: Codable, Equatable {
    public var version: Int
    public var salt: Data
    public var iterations: UInt32
    public var verifier: Data
    public var masterKeyVerifier: Data?
    public var wrappedKey: WrappedMasterKey

    public init(version: Int = 1,
                salt: Data,
                iterations: UInt32,
                verifier: Data,
                masterKeyVerifier: Data? = nil,
                wrappedKey: WrappedMasterKey) {
        self.version = version
        self.salt = salt
        self.iterations = iterations
        self.verifier = verifier
        self.masterKeyVerifier = masterKeyVerifier
        self.wrappedKey = wrappedKey
    }
}

public enum OpenCloakPasswordHasher {
    public static let minimumCharacters = 8
    public static let iterations: UInt32 = 120_000
    public static let masterKeyLength = 32

    /// PBKDF2-HMAC-SHA256. The password is passed as a C string, never as a shell argument.
    public static func derive(_ password: String, salt: Data, iterations: UInt32) -> Data? {
        guard !salt.isEmpty, iterations > 0 else { return nil }
        var derived = [UInt8](repeating: 0, count: masterKeyLength)
        let status = password.withCString { passwordPointer in
            salt.withUnsafeBytes { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordPointer,
                                     strlen(passwordPointer),
                                     saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                                     salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     iterations,
                                     &derived,
                                     derived.count)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(derived)
    }

    public static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func makeRecord(password: String, masterKey suppliedMasterKey: Data? = nil) throws -> OpenCloakPasswordRecord {
        guard password.count >= minimumCharacters else { throw OpenCloakCredentialError.passwordTooShort }
        guard let salt = randomBytes(32), let wrapSalt = randomBytes(32) else {
            throw OpenCloakCredentialError.persistence
        }
        guard let verifierKey = derive(password, salt: salt, iterations: iterations) else {
            throw OpenCloakCredentialError.persistence
        }
        guard let masterKey = suppliedMasterKey ?? randomBytes(masterKeyLength),
              masterKey.count == masterKeyLength,
              let wrappingKey = derive(password, salt: wrapSalt, iterations: iterations) else {
            throw OpenCloakCredentialError.persistence
        }
        do {
            let sealed = try AES.GCM.seal(masterKey, using: SymmetricKey(data: wrappingKey))
            let wrapped = WrappedMasterKey(salt: wrapSalt,
                                           nonce: Data(sealed.nonce),
                                           ciphertext: sealed.ciphertext,
                                           tag: sealed.tag)
            return OpenCloakPasswordRecord(salt: salt,
                                       iterations: iterations,
                                       verifier: digest(verifierKey),
                                       masterKeyVerifier: digest(masterKey),
                                       wrappedKey: wrapped)
        } catch {
            throw OpenCloakCredentialError.persistence
        }
    }

    /// Returns the master key only when the password verifier matches. A wrong password yields nil.
    public static func masterKey(password: String, record: OpenCloakPasswordRecord) -> Data? {
        guard record.version == 1,
              let key = derive(password, salt: record.salt, iterations: record.iterations),
              constantTimeEqual(digest(key), record.verifier),
              let wrappingKey = derive(password, salt: record.wrappedKey.salt, iterations: record.iterations) else {
            return nil
        }
        guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: record.wrappedKey.nonce),
                                               ciphertext: record.wrappedKey.ciphertext,
                                               tag: record.wrappedKey.tag),
              let master = try? AES.GCM.open(box, using: SymmetricKey(data: wrappingKey)),
              master.count == masterKeyLength else { return nil }
        return master
    }

    public static func masterKey(recoveryKey: String, record: OpenCloakPasswordRecord) -> Data? {
        let compact = recoveryKey.filter { !$0.isWhitespace && $0 != "-" }
        guard compact.count == masterKeyLength * 2,
              compact.allSatisfy({ $0.isHexDigit }),
              let data = Data(hexadecimal: compact),
              let verifier = record.masterKeyVerifier,
              constantTimeEqual(digest(data), verifier) else { return nil }
        return data
    }

    public static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) { difference |= a ^ b }
        return difference == 0
    }

    public static func randomBytes(_ count: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }
}

public enum OpenCloakKeyFormatting {
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

/// The master key is cached in the data-protection Keychain so Touch ID can unlock without the
/// password. When a OpenCloak password exists this item uses `.biometryCurrentSet`, so the Mac password
/// is not an alternate path. Without a OpenCloak password, `.userPresence` is the documented default.
public enum OpenCloakDeviceKey {
    private static let service = "app.opencloak.identity"
    private static let account = "master-key"

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    public static func isBiometricOnlyAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    public static func store(_ key: Data, biometricOnly: Bool) throws {
        var flags: SecAccessControlCreateFlags = biometricOnly ? .biometryCurrentSet : .userPresence
        if biometricOnly && !isBiometricOnlyAvailable() {
            // No enrolled Touch ID: keep the password as the only path rather than weakening access.
            flags = .biometryCurrentSet
        }
        guard let access = SecAccessControlCreateWithFlags(kCFAllocatorDefault,
                                                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           flags,
                                                           nil) else {
            throw OpenCloakCredentialError.keychain(errSecParam)
        }
        var add = query()
        add[kSecValueData as String] = key
        add[kSecAttrAccessControl as String] = access
        let context = LAContext()
        context.localizedReason = "Save the OpenCloak unlock key"
        add[kSecUseAuthenticationContext as String] = context
        var updateQuery = query()
        updateQuery[kSecUseAuthenticationContext as String] = context
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary,
                                         [kSecValueData as String: key] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw OpenCloakCredentialError.keychain(updateStatus)
        }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw OpenCloakCredentialError.keychain(addStatus) }
    }

    public static func read(reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason
        var read = query()
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        read[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecUserCanceled || status == errSecAuthFailed {
            throw OpenCloakCredentialError.authenticationCancelled
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw OpenCloakCredentialError.keychain(status)
        }
        return data
    }

    public static func exists() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var read = query()
        read[kSecReturnAttributes as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        read[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        return SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess
    }

    public static func clear() {
        var delete = query()
        delete[kSecUseAuthenticationContext as String] = LAContext()
        SecItemDelete(delete as CFDictionary)
    }
}

/// Owns the independent OpenCloak password. With a password configured, the Mac password is not
/// accepted by OpenCloak's own prompts; the password unwraps the master key used for hidden apps and
/// locked folders.
public final class OpenCloakIdentity {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenCloak/password.json")
    }

    public var hasPassword: Bool {
        (try? record()) != nil
    }

    public func record() throws -> OpenCloakPasswordRecord? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(OpenCloakPasswordRecord.self, from: data),
              record.version == 1 else {
            throw OpenCloakCredentialError.persistence
        }
        return record
    }

    /// Replaces any existing password. The master key changes, so callers must rotate image
    /// credentials; `ProtectionStore` asks the user to finish hiding/locking items before this runs.
    @discardableResult
    public func setPassword(_ password: String, preservingMasterKey: Data? = nil) throws -> String {
        lock.lock(); defer { lock.unlock() }
        let oldData = try? Data(contentsOf: fileURL)
        let record = try OpenCloakPasswordHasher.makeRecord(password: password, masterKey: preservingMasterKey)
        guard let master = OpenCloakPasswordHasher.masterKey(password: password, record: record) else {
            throw OpenCloakCredentialError.persistence
        }
        do {
            try write(record)
            if OpenCloakDeviceKey.isBiometricOnlyAvailable() {
                try OpenCloakDeviceKey.store(master, biometricOnly: true)
            }
        } catch {
            if let oldData { try? oldData.write(to: fileURL, options: .atomic) }
            else { try? FileManager.default.removeItem(at: fileURL) }
            throw error
        }
        return OpenCloakKeyFormatting.hex(master)
    }

    public func removePassword() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { try FileManager.default.removeItem(at: fileURL) }
            catch { throw OpenCloakCredentialError.persistence }
        }
        OpenCloakDeviceKey.clear()
    }

    public func masterKey(forPassword password: String) -> Data? {
        guard let record = try? record() else { return nil }
        return OpenCloakPasswordHasher.masterKey(password: password, record: record)
    }

    public func masterKey(forRecoveryKey key: String) -> Data? {
        guard let record = try? record() else { return nil }
        return OpenCloakPasswordHasher.masterKey(recoveryKey: key, record: record)
    }

    public func recoveryKey(forPassword password: String) -> String? {
        guard var current = try? record(),
              let master = OpenCloakPasswordHasher.masterKey(password: password, record: current) else { return nil }
        if current.masterKeyVerifier == nil {
            current.masterKeyVerifier = OpenCloakPasswordHasher.digest(master)
            do { try write(current) } catch { return nil }
        }
        return OpenCloakKeyFormatting.hex(master)
    }

    @discardableResult
    public func resetPassword(usingRecoveryKey recoveryKey: String, newPassword: String) throws -> String {
        guard let master = masterKey(forRecoveryKey: recoveryKey) else {
            throw OpenCloakCredentialError.incorrectPassword
        }
        return try setPassword(newPassword, preservingMasterKey: master)
    }

    /// Touch ID path when a password exists. Uses a biometric-only keychain item.
    public func masterKeyUsingTouchID(reason: String) throws -> Data {
        guard hasPassword else { throw OpenCloakCredentialError.notConfigured }
        return try OpenCloakDeviceKey.read(reason: reason)
    }

    /// Fallback when no OpenCloak password exists: the Mac password or Touch ID, as documented.
    public func masterKeyUsingUserPresence(reason: String) throws -> Data {
        if let key = try? OpenCloakDeviceKey.read(reason: reason), key.count == OpenCloakPasswordHasher.masterKeyLength {
            return key
        }
        guard let fresh = OpenCloakPasswordHasher.randomBytes(OpenCloakPasswordHasher.masterKeyLength) else {
            throw OpenCloakCredentialError.persistence
        }
        try OpenCloakDeviceKey.store(fresh, biometricOnly: false)
        return fresh
    }

    private func write(_ record: OpenCloakPasswordRecord) throws {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(record)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            throw OpenCloakCredentialError.persistence
        }
    }
}

private extension Data {
    init?(hexadecimal: String) {
        guard hexadecimal.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexadecimal.count / 2)
        var index = hexadecimal.startIndex
        while index < hexadecimal.endIndex {
            let next = hexadecimal.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimal[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
