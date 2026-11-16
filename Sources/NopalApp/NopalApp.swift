import AppKit
import NopalCore
import SwiftUI

@main
enum NopalMain {
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
    private let vaults = VaultStore()
    private let activity = ActivityCenter.shared
    private lazy var privacyCoordinator = PrivacyCoordinator(activity: activity)

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        privacyCoordinator.start()
        activity.prune(retentionDays: NopalPreferences().values.eventRetentionDays)

        if !UserDefaults.standard.bool(forKey: "hasOpenedNopal") {
            UserDefaults.standard.set(true, forKey: "hasOpenedNopal")
            openMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        privacyCoordinator.stop()
        // Best effort only: a forced termination or power loss can still leave a vault mounted.
        _ = VaultService.shared.lockAllMounted()
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

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: "Nopal")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Nopal privacy"
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Nopal", action: #selector(openMainWindow), keyEquivalent: "n")
        open.target = self
        menu.addItem(open)
        let lock = NSMenuItem(title: "Lock All Vaults", action: #selector(lockAllVaults), keyEquivalent: "l")
        lock.target = self
        menu.addItem(lock)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Nopal", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openMainWindow() {
        if window == nil { window = makeMainWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func lockAllVaults() {
        vaults.lockAll()
    }

    private func makeMainWindow() -> NSWindow {
        let content = MainView()
            .environmentObject(vaults)
            .environmentObject(activity)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Nopal"
        window.contentView = NSHostingView(rootView: content)
        window.minSize = NSSize(width: 840, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NopalMainWindow")
        return window
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case vaults = "Vaults"
    case apps = "Apps"
    case websites = "Websites"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .vaults: return "lock"
        case .apps: return "square.stack.3d.up"
        case .websites: return "globe"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject private var vaults: VaultStore
    @EnvironmentObject private var activity: ActivityCenter
    @State private var selection: Page? = .overview
    @StateObject private var rules = RuleListModel()

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $selection) { page in
                Label(page.rawValue, systemImage: page.symbol).tag(page as Page?)
            }
            .listStyle(.sidebar)
            .navigationTitle("Nopal")
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(rules: rules)
                case .vaults: VaultsView()
                case .apps: RulesView(kind: .apps, model: rules)
                case .websites: RulesView(kind: .websites, model: rules)
                case .settings: SettingsView(rules: rules)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 840, minHeight: 560)
        .alert("Nopal", isPresented: Binding(get: { vaults.errorMessage != nil },
                                            set: { if !$0 { vaults.errorMessage = nil } })) {
            Button("OK") { vaults.errorMessage = nil }
        } message: {
            Text(vaults.errorMessage ?? "")
        }
        .sheet(item: Binding(get: { vaults.recoveryCredential.map(RecoveryItem.init) },
                             set: { if $0 == nil { vaults.recoveryCredential = nil } })) { item in
            RecoveryKeyView(credential: item.value) { vaults.recoveryCredential = nil }
        }
        .alert("Nopal", isPresented: Binding(get: { activity.errorMessage != nil },
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
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.nopalAccent)
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
    static let nopalAccent = Color(red: 0.16, green: 0.36, blue: 0.23)
}
