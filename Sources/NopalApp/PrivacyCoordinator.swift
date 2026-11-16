import AppKit
import CoreGraphics
import LocalAuthentication
import NopalCore
import SwiftUI

final class PrivacyCoordinator {
    private struct Browser {
        let name: String
        let urlScript: String
        let closeScript: String
    }

    private let rules: PrivacyRuleStore
    private let vaults: VaultService
    private let preferences: NopalPreferences
    private let activity: ActivityCenter

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var rulesObserver: NSObjectProtocol?
    private var poller: Timer?
    private var panels: [NSPanel] = []
    private var cachedRules: [PrivacyRule] = []

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
         preferences: NopalPreferences = NopalPreferences(),
         activity: ActivityCenter = .shared) {
        self.rules = rules
        self.vaults = vaults
        self.preferences = preferences
        self.activity = activity
        cachedRules = (try? rules.all()) ?? []
    }

    func start() {
        cachedRules = (try? rules.all()) ?? []

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                        object: nil,
                                                        queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.applicationActivated(app)
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                                                        object: nil,
                                                        queue: .main) { [weak self] _ in
            self?.prepareForSleep()
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                                        object: nil,
                                                        queue: .main) { [weak self] _ in
            self?.refreshOverlay()
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
            self?.refreshOverlay()
        })

        rulesObserver = NotificationCenter.default.addObserver(forName: .nopalRulesChanged,
                                                               object: nil,
                                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            self.cachedRules = (try? self.rules.all()) ?? []
        }

        poller = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkIdle()
            self?.checkWebsite()
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
        hidePanel()
    }

    // MARK: - App rules

    private func applicationActivated(_ app: NSRunningApplication) {
        let bundleID = app.bundleIdentifier ?? ""
        if bundleID != lastApplicationID {
            unlockedRuleID = nil
            lastWebsiteKey = nil
            hidePanel()
        }
        lastApplicationID = bundleID

        guard bundleID != Bundle.main.bundleIdentifier else { return }
        guard let rule = cachedRules.first(where: { candidate in
            guard candidate.enabled, candidate.id != unlockedRuleID,
                  case .application(let identifier, _) = candidate.target else { return false }
            return identifier == bundleID
        }) else { return }

        let displayName: String
        if case .application(_, let name) = rule.target { displayName = name } else { displayName = "This app" }

        showPanel(rule: rule,
                  title: "\(displayName) is open",
                  detail: "This privacy screen covers \(displayName) until you unlock. The app is already running; Nopal does not block launches or background helpers.",
                  secondaryTitle: "Quit \(displayName)",
                  secondaryIsDestructive: true,
                  event: "Showed an app privacy screen",
                  secondaryAction: { [weak self] in
                      self?.activity.record(.privacy, .notice, "Quit an app from a privacy screen")
                      app.terminate()
                  })
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
            // Fail closed: without Automation access Nopal cannot see the page, so it does not pretend to cover it.
            if permissionWarnings.insert(bundleID).inserted {
                activity.record(.privacy, .failure,
                                "Website privacy screens are unavailable in \(browser.name): Automation permission is missing")
            }
            return
        }
        permissionWarnings.remove(bundleID)

        guard let value = descriptor.stringValue,
              let url = URL(string: value),
              let rule = cachedRules.first(where: { $0.matches(url: url) }) else {
            lastWebsiteKey = nil
            return
        }
        let key = "\(rule.id.uuidString)|\(url.absoluteString)"
        guard key != lastWebsiteKey, rule.id != unlockedRuleID else { return }
        lastWebsiteKey = key

        let host: String
        if case .website(let pattern) = rule.target { host = pattern.host } else { host = "a covered website" }

        showPanel(rule: rule,
                  title: "A covered website is open",
                  detail: "\(browser.name) is showing \(host), which matches one of your website rules. Nopal does not save this page or your browsing history.",
                  secondaryTitle: "Close tab",
                  secondaryIsDestructive: false,
                  event: "Showed a website privacy screen",
                  secondaryAction: { [weak self] in
                      self?.activity.record(.privacy, .notice, "Closed a tab from a website privacy screen")
                      Self.runAppleScript(browser.closeScript)
                  })
    }

    private static func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
    }

    // MARK: - Idle and relock

    private func checkIdle() {
        let minutes = preferences.values.idleLockMinutes
        guard minutes > 0 else {
            idleLocked = false
            return
        }
        let idleSeconds = [CGEventType.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
        if idleSeconds >= Double(minutes * 60) {
            guard !idleLocked else { return }
            idleLocked = true
            resetUnlock()
            lockMountedVaults(reason: "inactivity")
        } else {
            idleLocked = false
        }
    }

    private func prepareForSleep() {
        resetUnlock()
        guard preferences.values.lockOnSleep else { return }
        lockMountedVaults(reason: "the Mac went to sleep")
    }

    private func prepareForScreenLock() {
        resetUnlock()
        guard preferences.values.lockOnScreenLock else { return }
        lockMountedVaults(reason: "the screen locked")
    }

    private func lockMountedVaults(reason: String) {
        let mountedCount = vaults.list().filter(\.mounted).count
        guard mountedCount > 0 else { return }
        let failures = vaults.lockAllMounted()
        NotificationCenter.default.post(name: .nopalVaultsChanged, object: nil)
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

    private func refreshOverlay() {
        guard panels.isEmpty,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        applicationActivated(app)
    }

    // MARK: - Privacy screens

    private func showPanel(rule: PrivacyRule,
                           title: String,
                           detail: String,
                           secondaryTitle: String,
                           secondaryIsDestructive: Bool,
                           event: String,
                           secondaryAction: @escaping () -> Void) {
        guard panels.isEmpty else { return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

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
                secondaryTitle: secondaryTitle,
                secondaryIsDestructive: secondaryIsDestructive,
                unlock: { [weak self] in self?.authenticate(rule: rule) },
                secondary: { [weak self] in
                    secondaryAction()
                    self?.hidePanel()
                }
            ))
            panels.append(panel)
            panel.makeKeyAndOrderFront(nil)
        }
        activity.record(.privacy, .notice, event)
    }

    private func authenticate(rule: PrivacyRule) {
        let context = LAContext()
        let reason = "Unlock a Nopal privacy screen"
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if success {
                    self.unlockedRuleID = rule.id
                    self.hidePanel()
                    self.activity.record(.privacy, .success, "Unlocked a privacy screen")
                } else {
                    self.activity.record(.privacy, .failure, "Privacy screen authentication did not complete")
                }
            }
        }
    }

    private func hidePanel() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private func resetUnlock() {
        unlockedRuleID = nil
        lastWebsiteKey = nil
        hidePanel()
    }
}

private struct UnlockOverlay: View {
    let title: String
    let detail: String
    let secondaryTitle: String
    let secondaryIsDestructive: Bool
    let unlock: () -> Void
    let secondary: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(title).font(.largeTitle.bold())
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Text("Privacy screen only. It does not prevent this app or website from loading, and it cannot stop background helpers.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            HStack(spacing: 12) {
                if secondaryIsDestructive {
                    Button(secondaryTitle, role: .destructive) { secondary() }
                } else {
                    Button(secondaryTitle) { secondary() }
                }
                Button("Unlock with Touch ID or password") { unlock() }
                    .buttonStyle(.borderedProminent)
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
