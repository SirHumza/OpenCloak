import AppKit
import CoreGraphics
import LocalAuthentication
import OpenCloakCore
import SwiftUI

final class PrivacyCoordinator {
    private struct Browser {
        let name: String
        let urlScript: String
        let closeScript: String
    }

    private let rules: PrivacyRuleStore
    private let vaults: VaultService
    private let preferences: OpenCloakPreferences
    private let activity: ActivityCenter
    private let protection: ProtectionStore

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var rulesObserver: NSObjectProtocol?
    private var poller: Timer?
    private var gateTimer: Timer?
    private var panels: [NSPanel] = []
    private var cachedRules: [PrivacyRule] = []

    private var allowances: [LaunchAllowance] = []
    private var blockedAppURLs: [String: URL] = [:]
    private var gateBundleIdentifier: String?
    private var unlockedRuleID: UUID?
    private var lastApplicationID: String?
    private var lastWebsiteKey: String?
    private var permissionWarnings: Set<String> = []
    private var idleLocked = false

    private let browsers: [String: Browser] = [
        "com.apple.Safari": Browser(
            name: "Safari",
            urlScript: "tell application id \"com.apple.Safari\" to get URL of current tab of front window",
            closeScript: "tell application id \"com.apple.Safari\" to close current tab of front window"
        ),
        "com.google.Chrome": Browser(
            name: "Chrome",
            urlScript: "tell application id \"com.google.Chrome\" to get URL of active tab of front window",
            closeScript: "tell application id \"com.google.Chrome\" to close active tab of front window"
        ),
        "com.brave.Browser": Browser(
            name: "Brave",
            urlScript: "tell application id \"com.brave.Browser\" to get URL of active tab of front window",
            closeScript: "tell application id \"com.brave.Browser\" to close active tab of front window"
        ),
        "com.microsoft.edgemac": Browser(
            name: "Edge",
            urlScript: "tell application id \"com.microsoft.edgemac\" to get URL of active tab of front window",
            closeScript: "tell application id \"com.microsoft.edgemac\" to close active tab of front window"
        ),
        "com.vivaldi.Vivaldi": Browser(
            name: "Vivaldi",
            urlScript: "tell application id \"com.vivaldi.Vivaldi\" to get URL of active tab of front window",
            closeScript: "tell application id \"com.vivaldi.Vivaldi\" to close active tab of front window"
        )
    ]

    init(rules: PrivacyRuleStore = PrivacyRuleStore(),
         vaults: VaultService = .shared,
         preferences: OpenCloakPreferences = OpenCloakPreferences(),
         activity: ActivityCenter = .shared,
         protection: ProtectionStore = .shared) {
        self.rules = rules
        self.vaults = vaults
        self.preferences = preferences
        self.activity = activity
        self.protection = protection
        cachedRules = (try? rules.all()) ?? []
    }

    func start() {
        cachedRules = (try? rules.all()) ?? []

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                                        object: nil,
                                                        queue: .main) { [weak self] _ in
            self?.prepareForSleep()
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                        object: nil,
                                                        queue: .main) { [weak self] _ in
            self?.checkGate()
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                        object: nil,
                                                        queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            self?.allowances.removeAll { $0.bundleIdentifier == bundleID }
        })

        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.prepareForScreenLock()
        })
        distributedObservers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                            object: nil,
                                                            queue: .main) { [weak self] _ in
            self?.checkGate()
        })

        rulesObserver = NotificationCenter.default.addObserver(forName: .opencloakRulesChanged,
                                                               object: nil,
                                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cachedRules = (try? self.rules.all()) ?? []
        }

        poller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkIdle()
            self?.checkWebsite()
        }
        // The gate needs a tighter loop than the website poller: the app should not stay usable for
        // a full second after launch.
        gateTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.checkGate()
        }
    }

    func stop() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { workspace.removeObserver($0) }
        workspaceObservers.removeAll()
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.forEach { distributed.removeObserver($0) }
        distributedObservers.removeAll()
        if let rulesObserver { NotificationCenter.default.removeObserver(rulesObserver) }
        poller?.invalidate()
        poller = nil
        gateTimer?.invalidate()
        gateTimer = nil
        hidePanel()
    }

    /// Clears every unlock allowance and stops OpenCloak asking about anything already covered.
    func lockEverything() {
        allowances.removeAll()
        unlockedRuleID = nil
        lastWebsiteKey = nil
        gateBundleIdentifier = nil
        protection.lockNow()
        hidePanel()
        checkGate()
    }

    @discardableResult
    func lockFrontmostApplication() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let url = app.bundleURL else { return false }
        let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
        do {
            if !cachedRules.contains(where: { rule in
                guard case .application(let identifier, _) = rule.target else { return false }
                return identifier == bundleID
            }) {
                try rules.add(PrivacyRule(target: .application(bundleIdentifier: bundleID, displayName: name)))
                cachedRules = try rules.all()
                NotificationCenter.default.post(name: .opencloakRulesChanged, object: nil)
            }
            allowances.removeAll { $0.bundleIdentifier == bundleID }
            blockedAppURLs[bundleID] = url
            app.terminate()
            activity.record(.privacy, .success, "Locked and quit the frontmost app")
            return true
        } catch {
            activity.record(.privacy, .failure, "Could not add a lock for the frontmost app")
            return false
        }
    }

    // MARK: - Launch gate

    private func checkGate() {
        let now = Date()
        allowances = LaunchGate.activeAllowances(allowances, now: now)
        let ownBundleIdentifier = Bundle.main.bundleIdentifier ?? "app.opencloak.privacy"
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        let blocked = LaunchGate.blockedApplications(running: running,
                                                     rules: cachedRules,
                                                     allowances: allowances,
                                                     ownBundleIdentifier: ownBundleIdentifier,
                                                     now: now)

        if blocked.isEmpty {
            if let gateBundleIdentifier, !running.contains(gateBundleIdentifier) {
                self.gateBundleIdentifier = nil
            }
            return
        }
        guard panels.isEmpty else { return }

        for bundleIdentifier in blocked {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                continue
            }
            if let url = app.bundleURL { blockedAppURLs[bundleIdentifier] = url }
            app.terminate()
            if gateBundleIdentifier != bundleIdentifier {
                let name = LaunchGate.displayName(forBundleIdentifier: bundleIdentifier, in: cachedRules)
                activity.record(.privacy, .notice, "Stopped \(name) because it is locked")
            }
        }

        guard let bundleIdentifier = blocked.first else { return }
        guard gateBundleIdentifier != bundleIdentifier else { return }
        gateBundleIdentifier = bundleIdentifier
        presentGate(bundleIdentifier: bundleIdentifier)
    }

    private func presentGate(bundleIdentifier: String) {
        let name = LaunchGate.displayName(forBundleIdentifier: bundleIdentifier, in: cachedRules)
        if PrivacyScreenSelection.applicationRule(forBundleIdentifier: bundleIdentifier, in: cachedRules)?.fakeCrashEnabled == true {
            presentFakeCrash(bundleIdentifier: bundleIdentifier, name: name)
            return
        }
        showPanel(title: "\(name) is locked",
                  detail: "OpenCloak stopped \(name) before it could be used. Unlock to open it again.",
                  footnote: "OpenCloak stops covered apps while it is running. Background helpers, alternate launch paths, and anyone who can disable OpenCloak are outside this guard.",
                  secondaryTitle: "Keep it locked",
                  secondaryIsDestructive: false,
                  allowsPassword: protection.hasPassword,
                  secondaryAction: { [weak self] in
                      self?.gateBundleIdentifier = nil
                  },
                  unlockAction: { [weak self] password in
                      self?.authenticateGate(bundleIdentifier: bundleIdentifier, password: password)
                  })
    }

    private func presentFakeCrash(bundleIdentifier: String, name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) quit unexpectedly."
        alert.informativeText = "Click Reopen to open the application again."
        alert.addButton(withTitle: "Reopen")
        alert.addButton(withTitle: "Ignore")
        let response = alert.runModal()
        defer { gateBundleIdentifier = nil }
        guard response == .alertFirstButtonReturn else { return }
        let heldOption = NSApp.currentEvent?.modifierFlags.contains(.option) == true
            || CGEventSource.flagsState(.combinedSessionState).contains(.maskAlternate)
        guard heldOption else {
            activity.record(.privacy, .notice, "A fake-crash Reopen was ignored because Option was not held")
            return
        }
        grantLaunch(bundleIdentifier)
    }

    private func authenticateGate(bundleIdentifier: String, password: String?) {
        if let password, !password.isEmpty {
            guard protection.authenticate(passwordOrRecoveryKey: password) else {
                activity.record(.privacy, .failure, "A launch-gate password attempt failed")
                return
            }
            grantLaunch(bundleIdentifier)
            return
        }
        protection.authenticateUsingTouchID { [weak self] success in
            guard success else {
                self?.activity.record(.privacy, .failure, "A launch-gate authentication attempt did not complete")
                return
            }
            self?.grantLaunch(bundleIdentifier)
        }
    }

    private func grantLaunch(_ bundleIdentifier: String) {
        allowances.append(LaunchGate.allowance(for: bundleIdentifier, now: Date()))
        activity.record(.privacy, .success, "Allowed a locked app after authentication")
        hidePanel()
        gateBundleIdentifier = nil
        guard let url = blockedAppURLs[bundleIdentifier] else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }

    // MARK: - Website rules

    private var hasEnabledWebsiteRules: Bool {
        cachedRules.contains { rule in
            guard rule.enabled, case .website = rule.target else { return false }
            return true
        }
    }

    private func checkWebsite() {
        guard panels.isEmpty, hasEnabledWebsiteRules else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier,
              let browser = browsers[bundleID],
              let script = NSAppleScript(source: browser.urlScript) else { return }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if error != nil {
            // Fail closed: without Automation access OpenCloak cannot see the page, so it does not pretend to cover it.
            if permissionWarnings.insert(bundleID).inserted {
                activity.record(.privacy, .failure,
                                "Website privacy screens are unavailable in \(browser.name): Automation permission is missing")
            }
            return
        }
        permissionWarnings.remove(bundleID)

        guard let value = descriptor.stringValue,
              let url = URL(string: value),
              let rule = PrivacyScreenSelection.websiteRule(for: url, in: cachedRules, unlocked: unlockedRuleID) else {
            lastWebsiteKey = nil
            return
        }
        guard PrivacyScreenSelection.shouldPresent(rule: rule, url: url, lastPresentedKey: lastWebsiteKey) else { return }
        lastWebsiteKey = PrivacyScreenSelection.key(rule: rule, url: url)

        let host: String
        if case .website(let pattern) = rule.target { host = pattern.host } else { host = "a covered website" }

        showPanel(title: "A covered website is open",
                  detail: "\(browser.name) is showing \(host), which matches one of your website rules. OpenCloak does not save this page or your browsing history.",
                  footnote: "Privacy screen only. It does not prevent this page from loading, and it cannot stop background helpers.",
                  secondaryTitle: "Close tab",
                  secondaryIsDestructive: false,
                  allowsPassword: protection.hasPassword,
                  secondaryAction: { [weak self] in
                      self?.activity.record(.privacy, .notice, "Closed a tab from a website privacy screen")
                      Self.runAppleScript(browser.closeScript)
                  },
                  unlockAction: { [weak self] password in
                      self?.authenticateWebsite(ruleID: rule.id, password: password)
                  })
    }

    private func authenticateWebsite(ruleID: UUID, password: String?) {
        if let password, !password.isEmpty {
            guard protection.authenticate(passwordOrRecoveryKey: password) else { return }
            unlockedRuleID = ruleID
            hidePanel()
            activity.record(.privacy, .success, "Unlocked a website privacy screen")
            return
        }
        protection.authenticateUsingTouchID { [weak self] success in
            guard success else { return }
            self?.unlockedRuleID = ruleID
            self?.hidePanel()
            self?.activity.record(.privacy, .success, "Unlocked a website privacy screen")
        }
    }

    private static func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
    }

    // MARK: - Idle and relock

    private func checkIdle() {
        let minutes = preferences.values.idleLockMinutes
        let idleSeconds = [CGEventType.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        if idleSeconds >= Double(minutes * 60) {
            guard !idleLocked else { return }
            idleLocked = true
            resetUnlock()
            protection.lockNow()
            lockMountedVaults(reason: "inactivity")
        } else {
            idleLocked = false
        }
    }

    private func prepareForSleep() {
        resetUnlock()
        guard preferences.values.lockOnSleep else { return }
        protection.lockNow()
        lockMountedVaults(reason: "the Mac went to sleep")
    }

    private func prepareForScreenLock() {
        resetUnlock()
        guard preferences.values.lockOnScreenLock else { return }
        protection.lockNow()
        lockMountedVaults(reason: "the screen locked")
    }

    private func lockMountedVaults(reason: String) {
        let mountedCount = vaults.list().filter(\.mounted).count
        guard mountedCount > 0 else { return }
        let failures = vaults.lockAllMounted()
        NotificationCenter.default.post(name: .opencloakVaultsChanged, object: nil)
        if failures.isEmpty {
            activity.record(.vault, .success,
                            mountedCount == 1
                            ? "Locked a mounted vault after \(reason)"
                            : "Locked \(mountedCount) mounted vaults after \(reason)")
        } else {
            activity.record(.vault, .failure,
                            failures.count == 1
                            ? "A mounted vault could not be ejected after \(reason) and is still mounted"
                            : "\(failures.count) mounted vaults could not be ejected after \(reason) and are still mounted")
        }
    }

    // MARK: - Privacy screens

    private func showPanel(title: String,
                           detail: String,
                           footnote: String,
                           secondaryTitle: String,
                           secondaryIsDestructive: Bool,
                           allowsPassword: Bool,
                           secondaryAction: @escaping () -> Void,
                           unlockAction: @escaping (String?) -> Void) {
        guard panels.isEmpty else { return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame,
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
            panel.isOpaque = false
            panel.backgroundColor = NSColor.black.withAlphaComponent(0.92)
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: UnlockOverlay(
                title: title,
                detail: detail,
                footnote: footnote,
                secondaryTitle: secondaryTitle,
                secondaryIsDestructive: secondaryIsDestructive,
                allowsPassword: allowsPassword,
                unlock: unlockAction,
                secondary: { [weak self] in
                    secondaryAction()
                    self?.hidePanel()
                }
            ))
            panels.append(panel)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func hidePanel() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func resetUnlock() {
        allowances.removeAll()
        unlockedRuleID = nil
        lastWebsiteKey = nil
        hidePanel()
    }
}

private struct UnlockOverlay: View {
    let title: String
    let detail: String
    let footnote: String
    let secondaryTitle: String
    let secondaryIsDestructive: Bool
    let allowsPassword: Bool
    let unlock: (String?) -> Void
    let secondary: () -> Void

    @State private var password = ""
    @State private var enteringPassword = false
    @State private var enteringRecoveryKey = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(title).font(.largeTitle.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            if enteringPassword || enteringRecoveryKey {
                SecureField(enteringRecoveryKey ? "OpenCloak recovery key" : "OpenCloak password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { unlock(password) }
            }
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 12) {
                if secondaryIsDestructive {
                    Button(secondaryTitle, role: .destructive) { secondary() }
                } else {
                    Button(secondaryTitle) { secondary() }
                }
                if allowsPassword {
                    Button("Enter OpenCloak password") {
                        enteringPassword = true
                        enteringRecoveryKey = false
                        password = ""
                    }
                    Button("Use recovery key") {
                        enteringRecoveryKey = true
                        enteringPassword = false
                        password = ""
                    }
                }
                if OpenCloakDeviceKey.isBiometricOnlyAvailable() {
                    Button("Unlock with Touch ID") { unlock(nil) }
                        .buttonStyle(.borderedProminent)
                }
                if enteringPassword || enteringRecoveryKey {
                    Button("Unlock") { unlock(password) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}
