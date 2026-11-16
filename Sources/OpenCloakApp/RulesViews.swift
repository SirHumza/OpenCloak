import AppKit
import OpenCloakCore
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
        NotificationCenter.default.post(name: .opencloakRulesChanged, object: nil)
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
            error = "OpenCloak could not read this app's bundle identifier."
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

    func setAppOptions(_ options: AppRuleOptions, for rule: PrivacyRule) {
        do {
            try store.setAppOptions(options, id: rule.id)
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
    @State private var editingSchedule: PrivacyRule?

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
                           ? "Stop a covered app until you authenticate."
                           : "Cover a matching page in a supported browser.")

                GroupBox {
                    Label(isApps
                          ? "OpenCloak checks running apps four times a second and terminates a covered app until you unlock it."
                          : "Website screens are privacy screens, not execution blocking.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }

                if isApps {
                    HStack(spacing: 12) {
                        Button { chooseApplication() } label: {
                            Label("Add app", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.opencloakAccent)
                        Text("Background helpers and alternate launch paths are not covered, and the guard depends on OpenCloak running. Silence it from the menu bar only if you mean to.")
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
                        .tint(Color.opencloakAccent)
                        .disabled(website.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Text("Matches an exact host plus an optional path prefix. OpenCloak reads only the active tab URL and never stores browsing history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BrowserAccessView(statuses: $browserStatuses)
                }

                if visibleRules.isEmpty {
                    EmptyStateView(title: "No rules yet",
                                   symbol: isApps ? "square.stack.3d.up" : "globe",
                                   detail: isApps
                                   ? "Add an app to stop it until you authenticate."
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
                                if case .application = rule.target {
                                    Menu {
                                        Toggle("Fake crash dialog", isOn: Binding(
                                            get: { rule.fakeCrashEnabled },
                                            set: { enabled in
                                                var options = rule.appOptions ?? AppRuleOptions()
                                                options.fakeCrash = enabled
                                                model.setAppOptions(options, for: rule)
                                            }))
                                        Button(rule.appOptions?.schedule == nil ? "Set schedule…" : "Edit schedule…") {
                                            editingSchedule = rule
                                        }
                                        if rule.appOptions?.schedule != nil {
                                            Button("Clear schedule") {
                                                var options = rule.appOptions ?? AppRuleOptions()
                                                options.schedule = nil
                                                model.setAppOptions(options, for: rule)
                                            }
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                    .menuStyle(.borderlessButton)
                                }
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
        .sheet(item: $editingSchedule) { rule in
            AppScheduleView(rule: rule) { options in model.setAppOptions(options, for: rule) }
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

private struct AppScheduleView: View {
    @Environment(\.dismiss) private var dismiss
    let rule: PrivacyRule
    let save: (AppRuleOptions) -> Void
    @State private var weekdays: Set<Int>
    @State private var startMinute: Int
    @State private var endMinute: Int

    private let days = [(2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S")]

    init(rule: PrivacyRule, save: @escaping (AppRuleOptions) -> Void) {
        self.rule = rule
        self.save = save
        _weekdays = State(initialValue: rule.appOptions?.schedule?.weekdays ?? Set(1...7))
        _startMinute = State(initialValue: rule.appOptions?.schedule?.startMinute ?? 18 * 60)
        _endMinute = State(initialValue: rule.appOptions?.schedule?.endMinute ?? 8 * 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Schedule (ruleTitle)").font(.title2.bold())
            Text("The app is locked during this time range. Outside it, the app opens without an OpenCloak prompt.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(days, id: \.0) { day in
                    Toggle(day.1, isOn: Binding(get: { weekdays.contains(day.0) }, set: { selected in
                        if selected { weekdays.insert(day.0) } else { weekdays.remove(day.0) }
                    }))
                    .toggleStyle(.button)
                    .frame(width: 42)
                }
            }
            HStack {
                minutePicker("Starts", value: $startMinute)
                minutePicker("Ends", value: $endMinute)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save schedule") {
                    do {
                        let schedule = try AppLockSchedule(weekdays: weekdays,
                                                           startMinute: startMinute,
                                                           endMinute: endMinute)
                        var options = rule.appOptions ?? AppRuleOptions()
                        options.schedule = schedule
                        save(options)
                        dismiss()
                    } catch { }
                }
                .buttonStyle(.borderedProminent)
                .disabled(weekdays.isEmpty || startMinute == endMinute)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var ruleTitle: String {
        if case .application(_, let name) = rule.target { return name }
        return "App"
    }

    private func minutePicker(_ title: String, value: Binding<Int>) -> some View {
        DatePicker(title,
                   selection: Binding(get: {
                       Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(value.wrappedValue * 60))
                   }, set: { date in
                       let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                       value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                   }),
                   displayedComponents: .hourAndMinute)
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
                    Text("Website screens fail closed: if access is missing, no screen is shown and OpenCloak records that the protection is unavailable.")
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
