import AppKit
import Foundation
import LocalAuthentication
import OpenCloakCore

enum ProtectionDefaults {
    static let captureIntruderPhotos = "opencloakCaptureIntruderPhotos"
    static let requireQuitAuthentication = "opencloakRequireQuitAuthentication"
    static let startAtLogin = "opencloakStartAtLogin"
    static let hideMenuBarIcon = "opencloakHideMenuBarIcon"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            captureIntruderPhotos: false,
            requireQuitAuthentication: true,
            startAtLogin: false,
            hideMenuBarIcon: false
        ])
    }
}

/// Owns the independent password, hidden apps, in-place locked items, and intruder photos. The
/// master key stays in memory only for the length of the session and is cleared on lock.
final class ProtectionStore: ObservableObject {
    static let shared = ProtectionStore()

    enum ProtectionAction: Identifiable, Equatable {
        case hide(URL)
        case unhide(HiddenApp)
        case openHidden(HiddenApp)
        case lock(URL)
        case unlock(LockedItem)

        var id: String {
            switch self {
            case .hide(let url): return "hide:\(url.path)"
            case .unhide(let app): return "unhide:\(app.bundleIdentifier)"
            case .openHidden(let app): return "open-hidden:\(app.bundleIdentifier)"
            case .lock(let url): return "lock:\(url.path)"
            case .unlock(let item): return "unlock:\(item.id.uuidString)"
            }
        }

        var title: String {
            switch self {
            case .hide(let url): return "Hide \(url.deletingPathExtension().lastPathComponent)"
            case .unhide(let app): return "Unhide \(app.name)"
            case .openHidden(let app): return "Open \(app.name) while hidden"
            case .lock(let url): return "Lock \(url.lastPathComponent)"
            case .unlock(let item): return "Unlock \(item.name)"
            }
        }
    }

    @Published private(set) var hiddenApps: [HiddenApp] = []
    @Published private(set) var lockedItems: [LockedItem] = []
    @Published private(set) var intruderPhotos: [URL] = []
    @Published private(set) var busy = false
    @Published private(set) var hasPassword = false
    @Published private(set) var hasCompletedSetup = UserDefaults.standard.bool(forKey: "hasCompletedOpenCloakSetup")
    @Published private(set) var credential: String?
    @Published var setupRecoveryKey: String?
    @Published var pendingAction: ProtectionAction?
    @Published var errorMessage: String?

    let identity: OpenCloakIdentity
    private let hiddenService: HiddenAppService
    private let placeLockService: PlaceLockService
    private let photoStore: IntruderPhotoStore
    private let camera = IntruderCamera()
    private let activity = ActivityCenter.shared
    private var lastCapture: Date?
    private var temporaryUseObservers: [pid_t: NSObjectProtocol] = [:]

    init(identity: OpenCloakIdentity = OpenCloakIdentity(),
         hiddenService: HiddenAppService = HiddenAppService(),
         placeLockService: PlaceLockService = PlaceLockService(),
         photoStore: IntruderPhotoStore = IntruderPhotoStore()) {
        self.identity = identity
        self.hiddenService = hiddenService
        self.placeLockService = placeLockService
        self.photoStore = photoStore
        refresh()
    }

    var isUnlocked: Bool { credential != nil }

    func refresh() {
        hiddenApps = (try? hiddenService.all()) ?? []
        lockedItems = (try? placeLockService.all()) ?? []
        intruderPhotos = photoStore.all()
        hasPassword = identity.hasPassword
    }

    // MARK: - Password

    func setPassword(_ password: String, confirmation: String) {
        guard password == confirmation else {
            errorMessage = OpenCloakCredentialError.passwordMismatch.errorDescription
            return
        }
        do {
            setupRecoveryKey = try identity.setPassword(password)
            hasPassword = true
            credential = setupRecoveryKey
            activity.record(.privacy, .success, "Set a OpenCloak password")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func revealRecoveryKey(using password: String) -> Bool {
        guard let key = identity.recoveryKey(forPassword: password) else {
            errorMessage = OpenCloakCredentialError.incorrectPassword.errorDescription
            return false
        }
        setupRecoveryKey = key
        return true
    }

    func finishSetup() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOpenCloakSetup")
        hasCompletedSetup = true
        setupRecoveryKey = nil
        credential = nil
    }

    func changePassword(current: String, next: String, confirmation: String) {
        guard identity.masterKey(forPassword: current) != nil else {
            errorMessage = OpenCloakCredentialError.incorrectPassword.errorDescription
            return
        }
        guard next == confirmation else {
            errorMessage = OpenCloakCredentialError.passwordMismatch.errorDescription
            return
        }
        guard hiddenApps.isEmpty && lockedItems.isEmpty else {
            // Rotating the password replaces the master key, so existing encrypted images would be
            // orphaned. Unhide and unlock everything first.
            errorMessage = "Unhide every hidden app and unlock every locked item before changing the password. Existing encrypted images use the current key."
            return
        }
        do {
            setupRecoveryKey = try identity.setPassword(next)
            hasPassword = true
            credential = setupRecoveryKey
            activity.record(.privacy, .success, "Changed the OpenCloak password")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Authentication

    @discardableResult
    func authenticate(password: String) -> Bool {
        guard let key = identity.masterKey(forPassword: password) else {
            recordFailedAttempt()
            return false
        }
        credential = OpenCloakKeyFormatting.hex(key)
        activity.record(.privacy, .success, "Unlocked OpenCloak with the OpenCloak password")
        return true
    }

    @discardableResult
    func authenticate(recoveryKey: String) -> Bool {
        guard let key = identity.masterKey(forRecoveryKey: recoveryKey) else {
            recordFailedAttempt()
            return false
        }
        credential = OpenCloakKeyFormatting.hex(key)
        activity.record(.privacy, .success, "Unlocked OpenCloak with its recovery key")
        return true
    }

    func authenticate(passwordOrRecoveryKey value: String) -> Bool {
        if let key = identity.masterKey(forRecoveryKey: value) {
            credential = OpenCloakKeyFormatting.hex(key)
            activity.record(.privacy, .success, "Unlocked OpenCloak with its recovery key")
            return true
        }
        return authenticate(password: value)
    }

    func resetPassword(recoveryKey: String, next: String, confirmation: String) -> Bool {
        guard next == confirmation else {
            errorMessage = OpenCloakCredentialError.passwordMismatch.errorDescription
            return false
        }
        do {
            setupRecoveryKey = try identity.resetPassword(usingRecoveryKey: recoveryKey, newPassword: next)
            hasPassword = true
            credential = setupRecoveryKey
            activity.record(.privacy, .success, "Reset the OpenCloak password with its recovery key")
            return true
        } catch {
            recordFailedAttempt()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func authenticateUsingTouchID(completion: @escaping (Bool) -> Void) {
        let identity = identity
        DispatchQueue.global(qos: .userInitiated).async {
            let key: Data?
            if identity.hasPassword {
                key = try? identity.masterKeyUsingTouchID(reason: "Unlock OpenCloak")
            } else {
                key = try? identity.masterKeyUsingUserPresence(reason: "Unlock OpenCloak")
            }
            DispatchQueue.main.async {
                guard let key else {
                    self.recordFailedAttempt()
                    completion(false)
                    return
                }
                self.credential = OpenCloakKeyFormatting.hex(key)
                self.activity.record(.privacy, .success, "Unlocked OpenCloak with Touch ID")
                completion(true)
            }
        }
    }

    func lockNow() {
        credential = nil
        DispatchQueue.global(qos: .utility).async { [hiddenService, placeLockService] in
            try? hiddenService.relockIfMounted()
            try? placeLockService.relockAllMounted()
        }
        activity.record(.privacy, .notice, "Locked OpenCloak")
    }

    func relockAllMountedImages() -> [String] {
        var failures: [String] = []
        do { try hiddenService.relockIfMounted() }
        catch { failures.append(error.localizedDescription) }
        do { try placeLockService.relockAllMounted() }
        catch { failures.append(error.localizedDescription) }
        return failures
    }

    private func recordFailedAttempt() {
        activity.record(.privacy, .failure, "An unlock attempt failed")
        guard UserDefaults.standard.bool(forKey: ProtectionDefaults.captureIntruderPhotos) else { return }
        let now = Date()
        guard IntruderCapturePolicy.shouldCapture(isEnabled: true,
                                                 authenticationSucceeded: false,
                                                 lastCapture: lastCapture,
                                                 now: now) else { return }
        lastCapture = now
        camera.capture { data in
            guard let data else { return }
            try? self.photoStore.record(data)
            self.intruderPhotos = self.photoStore.all()
            self.activity.record(.privacy, .notice, "Saved an intruder photo after a failed unlock")
        }
    }

    // MARK: - Protected operations

    func begin(_ action: ProtectionAction) {
        recordPending(action)
    }

    private func recordPending(_ action: ProtectionAction) {
        if let credential {
            perform(action, credential: credential)
            return
        }
        pendingAction = action
    }

    func perform(_ action: ProtectionAction, credential: String) {
        pendingAction = nil
        guard !busy else { return }
        busy = true
        let hidden = hiddenService
        let place = placeLockService
        let protection = self

        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            var summary = ""
            var launchRequest: (HiddenApp, URL)?
            do {
                switch action {
                case .hide(let url):
                    _ = try hidden.hide(appAt: url, credential: credential)
                    summary = "Hid an app inside the encrypted image"
                case .unhide(let app):
                    try hidden.unhide(app, credential: credential)
                    summary = "Restored a hidden app to its original path"
                case .openHidden(let app):
                    launchRequest = (app, try hidden.openTemporarily(app, credential: credential))
                    summary = "Opened a hidden app without unhiding it"
                case .lock(let url):
                    _ = try place.lock(url: url, credential: credential)
                    summary = "Encrypted a folder or file in place"
                case .unlock(let item):
                    try place.unlock(item, credential: credential)
                    summary = "Restored a locked item to its original path"
                }
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                protection.busy = false
                protection.refresh()
                if let failure {
                    protection.errorMessage = failure.localizedDescription
                    protection.activity.record(.privacy, .failure, "A protected-item action did not complete")
                } else {
                    protection.activity.record(.privacy, .success, summary)
                }
                if failure == nil, let (app, url) = launchRequest {
                    protection.launchTemporarily(app, at: url)
                }
            }
        }
    }

    private func launchTemporarily(_ app: HiddenApp, at url: URL) {
        let workspace = NSWorkspace.shared
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] running, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let running else {
                    do { try self.hiddenService.closeTemporaryUse() }
                    catch { self.errorMessage = error.localizedDescription }
                    return
                }
                let observer = workspace.notificationCenter.addObserver(
                    forName: NSWorkspace.didTerminateApplicationNotification,
                    object: running,
                    queue: .main) { [weak self] _ in
                        guard let self else { return }
                        if let token = self.temporaryUseObservers.removeValue(forKey: running.processIdentifier) {
                            workspace.notificationCenter.removeObserver(token)
                        }
                        DispatchQueue.global(qos: .utility).async {
                            do { try self.hiddenService.closeTemporaryUse() }
                            catch {
                                DispatchQueue.main.async {
                                    self.errorMessage = "The hidden app quit, but its encrypted image could not be closed: \(error.localizedDescription)"
                                }
                            }
                        }
                    }
                self.temporaryUseObservers[running.processIdentifier] = observer
            }
        }
    }

    // MARK: - Intruder photos

    func deleteIntruderPhotos() {
        do {
            try photoStore.deleteAll()
            intruderPhotos = []
            activity.record(.privacy, .notice, "Deleted all intruder photos")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Startup protection

    func applyStartupProtection() {
        let enabled = UserDefaults.standard.bool(forKey: ProtectionDefaults.startAtLogin)
        do {
            try LoginAgent.setEnabled(enabled)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Writes a per-user LaunchAgent so OpenCloak starts at login and is relaunched if it is killed. This is
/// what makes "quit protection" and "keep running" real rather than a UI promise.
enum LoginAgent {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/app.opencloak.privacy.plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try write()
        } else {
            bootout()
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
        }
    }

    private static func write() throws {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/OpenCloak").path
        let plist: [String: Any] = [
            "Label": "app.opencloak.privacy",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
        _ = run(arguments: ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private static func bootout() {
        _ = run(arguments: ["bootout", "gui/\(getuid())/app.opencloak.privacy"])
    }

    @discardableResult
    private static func run(arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
