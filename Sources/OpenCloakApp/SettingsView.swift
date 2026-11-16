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
    @AppStorage(OpenCloakPreferences.Key.appearanceTheme) private var appearanceTheme = OpenCloakAppearanceTheme.glass.rawValue
    @AppStorage(OpenCloakPreferences.Key.textSize) private var textSize = OpenCloakTextSize.standard.rawValue

    @State private var confirmingClear = false
    @State private var exportError: String?
    @State private var password = ""
    @State private var repeatedPassword = ""
    @State private var currentPassword = ""
    @State private var passwordMessage: String?
    @State private var preparingUninstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Settings", subtitle: "OpenCloak keeps vault data and history on this Mac")

                GroupBox("Appearance") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Theme", selection: $appearanceTheme) {
                            ForEach(OpenCloakAppearanceTheme.allCases, id: \.rawValue) { theme in
                                Text(theme.displayName).tag(theme.rawValue)
                            }
                        }
                        Picker("Text size", selection: $textSize) {
                            ForEach(OpenCloakTextSize.allCases, id: \.rawValue) { size in
                                Text(size.displayName).tag(size.rawValue)
                            }
                        }
                        Text("Glass follows macOS. The other themes set a coordinated accent and window appearance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

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
                            Text("This is your recovery key. It remains valid if you change your OpenCloak password.")
                                .font(.caption.weight(.medium))
                            Text(recoveryKey)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            Button("I saved the recovery key") { protection.setupRecoveryKey = nil }
                        }
                        Text("At least \(OpenCloakPasswordHasher.minimumCharacters) characters. Changing your password preserves the encryption key, so protected items stay accessible with the same recovery key.")
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
                        Picker("Lock protected items after inactivity", selection: $idleLockMinutes) {
                            ForEach(PreferenceValues.idleChoices, id: \.self) { minutes in
                                Text("\(minutes) minute\(minutes == 1 ? "" : "s")").tag(minutes)
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

                VStack(alignment: .leading, spacing: 20) {
                    GroupBox("Uninstall") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Prepare OpenCloak for removal. You can leave encrypted items and recovery data in place, or delete OpenCloak's local data after mounted images are safely closed.")
                                .foregroundStyle(.secondary)
                            Button(preparingUninstall ? "Closing protected images…" : "Prepare to uninstall…") {
                                confirmUninstall()
                            }
                            .disabled(preparingUninstall)
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

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Prepare to remove OpenCloak?"
        alert.informativeText = "This disables OpenCloak's login agent. You must move OpenCloak.app to the Trash yourself. Deleting local data removes encrypted vaults, hidden apps, locked files, settings, and intruder photos."
        alert.addButton(withTitle: "Leave Encrypted Data")
        alert.addButton(withTitle: "Delete Local Data…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            prepareForUninstall(eraseData: false)
        case .alertSecondButtonReturn:
            confirmEraseData()
        default:
            break
        }
    }

    private func confirmEraseData() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete OpenCloak's local data?"
        alert.informativeText = "Any files and apps stored only in OpenCloak's encrypted images will be lost. This deletes local files but cannot guarantee secure overwriting of APFS/SSD blocks or copies in backups and snapshots. Continue only after restoring or backing up anything you need."
        alert.addButton(withTitle: "Delete Local Data")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { prepareForUninstall(eraseData: true) }
    }

    private func prepareForUninstall(eraseData: Bool) {
        guard !preparingUninstall else { return }
        preparingUninstall = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let vaultService = VaultService.shared
                let vaultFailures = vaultService.lockAllMounted()
                let imageFailures = ProtectionStore.shared.relockAllMountedImages()
                guard vaultFailures.isEmpty && imageFailures.isEmpty else {
                    throw UninstallPreparationError.mountedImages
                }
                try LoginAgent.setEnabled(false)
                if eraseData {
                    try vaultService.clearStoredCredentials()
                    OpenCloakDeviceKey.clear()
                    let dataRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("OpenCloak", isDirectory: true)
                    if FileManager.default.fileExists(atPath: dataRoot.path) {
                        try FileManager.default.removeItem(at: dataRoot)
                    }
                    if let bundleIdentifier = Bundle.main.bundleIdentifier {
                        UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
                    }
                }
                DispatchQueue.main.async {
                    preparingUninstall = false
                    let done = NSAlert()
                    done.messageText = "OpenCloak is ready to remove."
                    done.informativeText = "Quit OpenCloak, then move OpenCloak.app to the Trash."
                    done.runModal()
                }
            } catch {
                DispatchQueue.main.async {
                    preparingUninstall = false
                    let failed = NSAlert(error: error)
                    failed.runModal()
                }
            }
        }
    }
}

private enum UninstallPreparationError: LocalizedError {
    case mountedImages

    var errorDescription: String? {
        "OpenCloak could not close every protected disk image. Nothing was erased or removed. Close files in mounted images and retry."
    }
}
