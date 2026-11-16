import AppKit
import OpenCloakCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var activity: ActivityCenter
    @ObservedObject var rules: RuleListModel
    @ObservedObject var protection: ProtectionStore

    @AppStorage(OpenCloakPreferences.Key.idleLockMinutes) private var idleLockMinutes = 5
    @AppStorage(OpenCloakPreferences.Key.lockOnSleep) private var lockOnSleep = true
    @AppStorage(OpenCloakPreferences.Key.lockOnScreenLock) private var lockOnScreenLock = true
    @AppStorage(OpenCloakPreferences.Key.eventRetentionDays) private var eventRetentionDays = 30
    @AppStorage(OpenCloakPreferences.Key.requireBiometricOnly) private var requireBiometricOnly = false
    @AppStorage(ProtectionDefaults.captureIntruderPhotos) private var captureIntruderPhotos = false
    @AppStorage(ProtectionDefaults.requireQuitAuthentication) private var requireQuitAuthentication = true
    @AppStorage(ProtectionDefaults.startAtLogin) private var startAtLogin = false
    @AppStorage(ProtectionDefaults.hideMenuBarIcon) private var hideMenuBarIcon = false

    @State private var confirmingClear = false
    @State private var exportError: String?
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var currentPassword = ""
    @State private var passwordMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Settings", subtitle: "OpenCloak keeps vault data and history on this Mac")

                GroupBox("OpenCloak password") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(protection.hasPassword
                             ? "A OpenCloak password is set. It gates OpenCloak's prompts and unlocks hidden apps and locked files. Your Mac password no longer unlocks them."
                             : "Set a OpenCloak password so someone who knows your Mac password still cannot unlock OpenCloak, hidden apps, or locked files.")
                            .foregroundStyle(.secondary)
                        if protection.hasPassword {
                            SecureField("Current OpenCloak password", text: $currentPassword)
                                .textFieldStyle(.roundedBorder)
                            SecureField("New OpenCloak password", text: $password)
                                .textFieldStyle(.roundedBorder)
                            SecureField("Repeat new password", text: $repeatedPassword)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Change password") {
                                    protection.changePassword(current: currentPassword, next: password, confirmation: repeatedPassword)
                                    passwordMessage = protection.errorMessage
                                    password = ""; repeatedPassword = ""; currentPassword = ""
                                }
                            }
                        } else {
                            SecureField("OpenCloak password", text: $password)
                                .textFieldStyle(.roundedBorder)
                            SecureField("Repeat password", text: $repeatedPassword)
                                .textFieldStyle(.roundedBorder)
                            Button("Set password") {
                                protection.setPassword(password, confirmation: repeatedPassword)
                                passwordMessage = protection.errorMessage
                                password = ""; repeatedPassword = ""
                            }
                            .disabled(password.count < OpenCloakPasswordHasher.minimumCharacters)
                        }
                        if let passwordMessage {
                            Text(passwordMessage).font(.caption).foregroundStyle(.orange)
                        }
                        if let recoveryKey = protection.setupRecoveryKey {
                            Text("Save this new recovery key. It replaces the previous key.")
                                .font(.caption.weight(.medium))
                            Text(recoveryKey)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            Button("I saved the recovery key") { protection.setupRecoveryKey = nil }
                        }
                        Text("At least \(OpenCloakPasswordHasher.minimumCharacters) characters. Unhiding every app and unlocking every file is required before a password change, because those images use the current key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Intruder photos") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Take a photo after a failed unlock", isOn: $captureIntruderPhotos)
                        Text("Photos are JPEGs written to OpenCloak's Application Support folder with owner-only permissions and kept on a rolling \(IntruderCapturePolicy.defaultLimit)-photo limit. OpenCloak never uploads or analyses them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("\(protection.intruderPhotos.count) photo\(protection.intruderPhotos.count == 1 ? "" : "s") stored locally.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Delete all photos") { protection.deleteIntruderPhotos() }
                                .disabled(protection.intruderPhotos.isEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Vault security") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Vault keys are stored in the macOS Keychain.", systemImage: "key.horizontal")
                        Text("OpenCloak uses the data-protection Keychain with user-presence access control. Touch ID gates retrieval; it is not itself the encryption key.")
                            .foregroundStyle(.secondary)
                        Picker("Authentication", selection: $requireBiometricOnly) {
                            Text("Touch ID or Mac password").tag(false)
                            Text("Touch ID only (when available)").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        Text("Applies the next time OpenCloak saves a vault credential. Existing credentials keep the protection they were saved with.")
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
                        Text("Busy vaults stay mounted until their files are closed. OpenCloak records and shows that unresolved state instead of claiming success.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox("Quit and startup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Require authentication to quit OpenCloak", isOn: $requireQuitAuthentication)
                        Toggle("Start at login and relaunch if OpenCloak is killed", isOn: $startAtLogin)
                            .onChange(of: startAtLogin) { _ in
                                protection.applyStartupProtection()
                            }
                        Toggle("Hide the menu bar icon", isOn: $hideMenuBarIcon)
                        Text("Open the window with ⌥⌘O. Lock and quit the frontmost app with ⌥⌘L. These shortcuts work while the menu bar icon is hidden.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Startup protection installs a per-user LaunchAgent at ~/Library/LaunchAgents/app.opencloak.privacy.plist. OpenCloak launches it through launchctl; no shell command is used. Hiding apps and locking files stay encrypted while OpenCloak is not running, but nothing stops someone from uninstalling OpenCloak.")
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
                        Text("OpenCloak 0.2.0 · MIT License")
                        Text("OpenCloak is a consumer privacy utility, not an endpoint-security product. It does not stop an administrator, root, malware running as you, or anyone holding an unlocked Mac with OpenCloak disabled.")
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
            Text("This removes every locally stored OpenCloak activity record. Vaults, hidden apps, locked items, and privacy rules are not affected.")
        }
        .alert("OpenCloak", isPresented: Binding(get: { exportError != nil },
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
        panel.title = "Export OpenCloak configuration"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "OpenCloak Configuration.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let snapshot = ConfigurationArchive.snapshot(rules: rules.rules,
                                                         preferences: OpenCloakPreferences().values)
            try ConfigurationArchive.write(snapshot, to: url)
            activity.record(.system, .success, "Exported OpenCloak configuration")
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func importConfiguration() {
        let panel = NSOpenPanel()
        panel.title = "Import OpenCloak configuration"
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
            OpenCloakPreferences().store(snapshot.preferences)
            activity.prune(retentionDays: snapshot.preferences.eventRetentionDays)
            activity.record(.system, .success, "Imported OpenCloak configuration")
        } catch {
            exportError = "Could not import this configuration. No credentials or vault data were changed. \(error.localizedDescription)"
        }
    }
}
