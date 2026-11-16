import AppKit
import NopalCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var activity: ActivityCenter
    @ObservedObject var rules: RuleListModel

    @AppStorage(NopalPreferences.Key.idleLockMinutes) private var idleLockMinutes = 5
    @AppStorage(NopalPreferences.Key.lockOnSleep) private var lockOnSleep = true
    @AppStorage(NopalPreferences.Key.lockOnScreenLock) private var lockOnScreenLock = true
    @AppStorage(NopalPreferences.Key.eventRetentionDays) private var eventRetentionDays = 30
    @AppStorage(NopalPreferences.Key.requireBiometricOnly) private var requireBiometricOnly = false

    @State private var confirmingClear = false
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Settings", subtitle: "Nopal keeps vault data and history on this Mac")

                GroupBox("Vault security") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Vault keys are stored in the macOS Keychain.", systemImage: "key.horizontal")
                        Text("Nopal uses the data-protection Keychain with user-presence access control. Touch ID gates retrieval; it is not itself the encryption key.")
                            .foregroundStyle(.secondary)
                        Picker("Authentication", selection: $requireBiometricOnly) {
                            Text("Touch ID or Mac password").tag(false)
                            Text("Touch ID only (when available)").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        Text("Applies the next time Nopal saves a vault credential. Existing credentials keep the protection they were saved with.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Automatic locking") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Lock mounted vaults after inactivity", selection: $idleLockMinutes) {
                            ForEach(PreferenceValues.idleChoices, id: \.self) { minutes in
                                Text(minutes == 0 ? "Never" : "\(minutes) minute\(minutes == 1 ? "" : "s")")
                                    .tag(minutes)
                            }
                        }
                        Toggle("Lock when the Mac sleeps", isOn: $lockOnSleep)
                        Toggle("Lock when the screen locks", isOn: $lockOnScreenLock)
                        Text("Busy vaults stay mounted until their files are closed. Nopal records and shows that unresolved state instead of claiming success.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Local activity history") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Keep history", selection: $eventRetentionDays) {
                            ForEach(PreferenceValues.retentionChoices, id: \.self) { days in
                                Text(days == 0 ? "Until cleared" : "\(days) days").tag(days)
                            }
                        }
                        Text("History records actions and outcomes only. It never stores file names, vault names, URLs, or credentials. \(activity.events.count) record(s) are currently stored locally.")
                            .foregroundStyle(.secondary)
                        Button("Clear history") { confirmingClear = true }
                            .disabled(activity.events.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Export privacy rules and preferences as JSON. Passwords, keys, vault credentials, and activity history are never included.")
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Export configuration…") { exportConfiguration() }
                            Button("Import configuration…") { importConfiguration() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("About") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nopal 0.1.0 · MIT License")
                        Text("Nopal is a privacy-screen utility, not an endpoint-security product. It does not claim to stop an administrator, malware running as you, or anyone using an unlocked Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Clear activity history?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { activity.clear() }
        } message: {
            Text("This removes every locally stored Nopal activity record. Vaults and privacy rules are not affected.")
        }
        .alert("Nopal", isPresented: Binding(get: { exportError != nil },
                                            set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onChange(of: eventRetentionDays) { newValue in
            activity.prune(retentionDays: newValue)
        }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel()
        panel.title = "Export Nopal configuration"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Nopal Configuration.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = ConfigurationArchive.snapshot(rules: rules.rules,
                                                         preferences: NopalPreferences().values)
            try ConfigurationArchive.write(snapshot, to: url)
            activity.record(.system, .success, "Exported Nopal configuration")
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Import Nopal configuration"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(ConfigurationSnapshot.self, from: data)
            guard snapshot.schema == 1 else { throw CocoaError(.fileReadCorruptFile) }
            try rules.replaceAll(snapshot.rules)
            NopalPreferences().store(snapshot.preferences)
            activity.prune(retentionDays: snapshot.preferences.eventRetentionDays)
            activity.record(.system, .success, "Imported Nopal configuration")
        } catch {
            exportError = "Could not import this configuration. No credentials or vault data were changed. \(error.localizedDescription)"
        }
    }
}
