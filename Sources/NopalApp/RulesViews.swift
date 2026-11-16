import AppKit
import NopalCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class RuleListModel: ObservableObject {
    @Published private(set) var rules: [PrivacyRule] = []
    @Published var error: String?
    private let store = PrivacyRuleStore()

    init() { reload() }

    func reload() {
        do {
            rules = try store.all()
        } catch {
            self.error = error.localizedDescription
        }
        NotificationCenter.default.post(name: .nopalRulesChanged, object: nil)
    }

    func addWebsite(_ value: String) {
        do {
            try store.add(PrivacyRule(target: .website(try WebsitePattern(value))))
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addApplication(at url: URL) {
        let bundleID = Bundle(url: url)?.bundleIdentifier
        guard let bundleID else {
            error = "Nopal could not read this app's bundle identifier."
            return
        }
        let displayName = Bundle(path: url.path)?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        do {
            try store.add(PrivacyRule(target: .application(bundleIdentifier: bundleID, displayName: displayName)))
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setEnabled(_ value: Bool, for rule: PrivacyRule) {
        do {
            try store.setEnabled(value, id: rule.id)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ rule: PrivacyRule) {
        do {
            try store.remove(id: rule.id)
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func replaceAll(_ importedRules: [PrivacyRule]) throws {
        try store.replaceAll(importedRules)
        reload()
    }
}

enum RuleKind {
    case apps
    case websites
}

struct RulesView: View {
    let kind: RuleKind
    @ObservedObject var model: RuleListModel
    @State private var website = ""
    @State private var browserStatuses: [BrowserStatus] = []

    private var isApps: Bool { kind == .apps }
    private var title: String { isApps ? "App privacy screens" : "Website privacy screens" }
    private var visibleRules: [PrivacyRule] {
        model.rules.filter { rule in
            switch (kind, rule.target) {
            case (.apps, .application): return true
            case (.websites, .website): return true
            default: return false
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: title,
                           subtitle: isApps
                           ? "Cover an app after macOS reports it has launched."
                           : "Cover a matching page in a supported browser.")

                GroupBox {
                    Label("These are privacy screens, not encryption or execution blocking.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                if isApps {
                    HStack(spacing: 12) {
                        Button { chooseApplication() } label: {
                            Label("Add app", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.nopalAccent)
                        Text("Nopal observes app activation only. Background helpers and alternate launch paths are not covered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        TextField("example.com or example.com/private", text: $website)
                            .textFieldStyle(.roundedBorder)
                        Button("Add website") {
                            model.addWebsite(website)
                            website = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.nopalAccent)
                        .disabled(website.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Matches an exact host plus an optional path prefix. Nopal reads only the active tab URL and never stores browsing history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BrowserAccessView(statuses: $browserStatuses)
                }

                if visibleRules.isEmpty {
                    EmptyStateView(title: "No rules yet",
                                   symbol: isApps ? "square.stack.3d.up" : "globe",
                                   detail: isApps
                                   ? "Add an app to cover its windows after macOS reports it is active."
                                   : "Add a host or a specific path to cover it while browsing.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleRules) { rule in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ruleTitle(rule)).font(.headline)
                                    Text(ruleSubtitle(rule)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Toggle("Enabled", isOn: Binding(get: { rule.enabled },
                                                                set: { model.setEnabled($0, for: rule) }))
                                    .labelsHidden()
                                    .help("Turn this privacy screen on or off")
                                Button(role: .destructive) {
                                    model.remove(rule)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove rule")
                            }
                            .padding(14)
                            if rule.id != visibleRules.last?.id { Divider() }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Could not update rule", isPresented: Binding(get: { model.error != nil },
                                                             set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .onAppear {
            if !isApps { browserStatuses = BrowserPermissions.currentStatuses() }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.addApplication(at: url)
        }
    }

    private func ruleTitle(_ rule: PrivacyRule) -> String {
        switch rule.target {
        case .application(_, let name): return name
        case .website(let pattern): return pattern.host
        }
    }

    private func ruleSubtitle(_ rule: PrivacyRule) -> String {
        switch rule.target {
        case .application(let id, _): return id
        case .website(let pattern):
            return pattern.pathPrefix == "/" ? "All pages on this host" : "Pages under \(pattern.pathPrefix)"
        }
    }
}

private struct BrowserAccessView: View {
    @Binding var statuses: [BrowserStatus]

    var body: some View {
        GroupBox("Browser Automation access") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(statuses) { item in
                    HStack(spacing: 8) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .frame(width: 74, alignment: .leading)
                        Image(systemName: item.status.symbol)
                            .foregroundStyle(color(for: item.status))
                        Text(item.status.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if item.status == .notDetermined {
                            Button("Request access") {
                                _ = BrowserPermissions.status(for: item.id, askUser: true)
                                statuses = BrowserPermissions.currentStatuses()
                            }
                            .controlSize(.small)
                        } else if item.status == .denied {
                            Button("Open Settings") {
                                BrowserPermissions.openAutomationSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                HStack {
                    Text("Website screens fail closed: if access is missing, no screen is shown and Nopal records that the protection is unavailable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") {
                        statuses = BrowserPermissions.currentStatuses()
                    }
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear { statuses = BrowserPermissions.currentStatuses() }
    }

    private func color(for status: BrowserAutomationStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .unknown: return .orange
        case .browserNotRunning: return .secondary
        }
    }
}
