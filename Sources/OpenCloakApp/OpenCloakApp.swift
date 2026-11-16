import AppKit
import Carbon
import OpenCloakCore
import SwiftUI

@main
enum OpenCloakMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var hotKeyHandler: EventHandlerRef?
    private var openHotKey: EventHotKeyRef?
    private var lockHotKey: EventHotKeyRef?
    private let vaults = VaultStore()
    private let activity = ActivityCenter.shared
    private let protection = ProtectionStore.shared
    private lazy var privacyCoordinator = PrivacyCoordinator(activity: activity, protection: protection)
    private var quitAllowed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProtectionDefaults.registerDefaults()
        installStatusItem()
        installGlobalHotKeys()
        privacyCoordinator.start()
        DispatchQueue.global(qos: .utility).async { [weak protection, weak activity] in
            let failures = protection?.relockAllMountedImages() ?? []
            if !failures.isEmpty {
                activity?.record(.privacy, .failure, "One or more protected images stayed mounted after restart")
            }
        }
        activity.prune(retentionDays: OpenCloakPreferences().values.eventRetentionDays)
        if UserDefaults.standard.bool(forKey: ProtectionDefaults.startAtLogin) {
            protection.applyStartupProtection()
        }

        if !UserDefaults.standard.bool(forKey: "hasOpenedOpenCloak") {
            UserDefaults.standard.set(true, forKey: "hasOpenedOpenCloak")
            openMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        privacyCoordinator.stop()
        NotificationCenter.default.removeObserver(self, name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
        if let openHotKey { UnregisterEventHotKey(openHotKey) }
        if let lockHotKey { UnregisterEventHotKey(lockHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        // Best effort only: a forced termination or power loss can still leave a vault mounted.
        _ = VaultService.shared.lockAllMounted()
        _ = protection.relockAllMountedImages()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let requiresAuthentication = UserDefaults.standard.bool(forKey: ProtectionDefaults.requireQuitAuthentication)
        guard requiresAuthentication, !quitAllowed else { return .terminateNow }
        QuitGuard.confirm(protection: protection) { [weak self] allowed in
            self?.quitAllowed = allowed
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "OpenCloak")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "OpenCloak privacy"
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open OpenCloak", action: #selector(openMainWindow), keyEquivalent: "n")
        open.target = self
        menu.addItem(open)
        let lock = NSMenuItem(title: "Lock All Vaults", action: #selector(lockAllVaults), keyEquivalent: "l")
        lock.target = self
        menu.addItem(lock)
        let lockEverything = NSMenuItem(title: "Lock Everything", action: #selector(lockEverything), keyEquivalent: "L")
        lockEverything.target = self
        menu.addItem(lockEverything)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenCloak", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        item.isVisible = !UserDefaults.standard.bool(forKey: ProtectionDefaults.hideMenuBarIcon)
        statusItem = item
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(userDefaultsChanged(_:)),
                                               name: UserDefaults.didChangeNotification,
                                               object: UserDefaults.standard)
    }

    @objc private func userDefaultsChanged(_ notification: Notification) {
        statusItem?.isVisible = !UserDefaults.standard.bool(forKey: ProtectionDefaults.hideMenuBarIcon)
    }

    private func installGlobalHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerProcPtr = { _, event, userData in
            guard let userData else { return noErr }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &identifier)
            guard status == noErr else { return status }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                if identifier.id == 1 { delegate.openMainWindow() }
                else if identifier.id == 2 { _ = delegate.privacyCoordinator.lockFrontmostApplication() }
            }
            return noErr
        }
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                  Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler) == noErr else { return }
        let signature = OSType(0x4F434C4B)
        let openID = EventHotKeyID(signature: signature, id: 1)
        let lockID = EventHotKeyID(signature: signature, id: 2)
        RegisterEventHotKey(UInt32(kVK_ANSI_O), UInt32(cmdKey | optionKey), openID,
                            GetApplicationEventTarget(), 0, &openHotKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_L), UInt32(cmdKey | optionKey), lockID,
                            GetApplicationEventTarget(), 0, &lockHotKey)
    }

    @objc private func openMainWindow() {
        if window == nil { window = makeMainWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func lockAllVaults() {
        vaults.lockAll()
    }

    @objc private func lockEverything() {
        privacyCoordinator.lockEverything()
        vaults.lockAll()
    }

    private func makeMainWindow() -> NSWindow {
        let content = MainView(protection: protection)
            .environmentObject(vaults)
            .environmentObject(activity)
            .environmentObject(protection)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "OpenCloak"
        window.contentView = NSHostingView(rootView: content)
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("OpenCloakMainWindow")
        return window
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case vaults = "Vaults"
    case apps = "Locked apps"
    case websites = "Websites"
    case hidden = "Hidden apps"
    case locked = "Locked files"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .vaults: return "lock"
        case .apps: return "square.stack.3d.up"
        case .websites: return "globe"
        case .hidden: return "eye.slash"
        case .locked: return "folder.badge.minus"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var vaults: VaultStore
    @EnvironmentObject private var activity: ActivityCenter
    @ObservedObject var protection: ProtectionStore
    @State private var selection: Page? = .overview
    @StateObject private var rules = RuleListModel()

    @ViewBuilder
    var body: some View {
        if !protection.hasCompletedSetup {
            SetupAssistantView(protection: protection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            dashboard
        }
    }

    private var dashboard: some View {
        HStack(spacing: 0) {
            List(Page.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page as Page?)
            }
            .listStyle(.sidebar)
            .frame(width: 196)
            Divider()
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(rules: rules)
                case .vaults: VaultsView()
                case .apps: RulesView(kind: .apps, model: rules)
                case .websites: RulesView(kind: .websites, model: rules)
                case .hidden: HiddenAppsView(protection: protection)
                case .locked: LockedItemsView(protection: protection)
                case .settings: SettingsView(rules: rules, protection: protection)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("OpenCloak", isPresented: Binding(get: { vaults.errorMessage != nil },
                                            set: { if !$0 { vaults.errorMessage = nil } })) {
            Button("OK") { vaults.errorMessage = nil }
        } message: {
            Text(vaults.errorMessage ?? "")
        }
        .alert("OpenCloak", isPresented: Binding(get: { protection.errorMessage != nil },
                                            set: { if !$0 { protection.errorMessage = nil } })) {
            Button("OK") { protection.errorMessage = nil }
        } message: {
            Text(protection.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { protection.pendingAction },
                             set: { protection.pendingAction = $0 })) { action in
            ProtectionAuthView(protection: protection, action: action)
        }
        .sheet(item: Binding(get: { vaults.recoveryCredential.map(RecoveryItem.init) },
                             set: { if $0 == nil { vaults.recoveryCredential = nil } })) { item in
            RecoveryKeyView(credential: item.value) { vaults.recoveryCredential = nil }
        }
        .alert("OpenCloak", isPresented: Binding(get: { activity.errorMessage != nil },
                                            set: { if !$0 { activity.errorMessage = nil } })) {
            Button("OK") { activity.errorMessage = nil }
        } message: {
            Text(activity.errorMessage ?? "")
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).foregroundStyle(.secondary)
        }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.opencloakAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.title.bold())
                    Text(title).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct ActivityRow: View {
    let record: EventRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary)
                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(record.category.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch record.outcome {
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .notice: return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch record.outcome {
        case .success: return .green
        case .failure: return .orange
        case .notice: return .secondary
        }
    }
}

extension Color {
    static let opencloakAccent = Color(red: 0.16, green: 0.36, blue: 0.23)
}
