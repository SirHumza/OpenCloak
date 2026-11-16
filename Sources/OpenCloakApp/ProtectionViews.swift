import AppKit
import OpenCloakCore
import SwiftUI
import UniformTypeIdentifiers

struct HiddenAppsView: View {
    @ObservedObject var protection: ProtectionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Hidden apps",
                           subtitle: "An app moved into OpenCloak's encrypted image disappears from Spotlight, Launchpad, and the Applications folder")

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Hiding moves the app bundle into an AES-256 encrypted image.",
                              systemImage: "eye.slash")
                        Text("The app is verified inside the image before the original is removed. Unhiding copies it back to the exact path it came from. A Dock tile clears on the next Dock refresh, and a Spotlight entry may linger until macOS finishes reindexing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        chooseApp()
                    } label: {
                        Label("Hide an app…", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.opencloakAccent)
                    .disabled(protection.busy)
                    Text("Run apps from the Applications folder so OpenCloak can put them back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if protection.hiddenApps.isEmpty {
                    EmptyStateView(title: "No hidden apps",
                                   symbol: "eye.slash",
                                   detail: "Choose an app to move it into the encrypted image. OpenCloak does not delete it.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(protection.hiddenApps) { app in
                            HStack(spacing: 12) {
                                Image(systemName: "app.dashed")
                                    .font(.title3)
                                    .foregroundStyle(Color.opencloakAccent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.name).font(.headline)
                                    Text(app.originalPath).font(.caption).foregroundStyle(.secondary)
                                    Text("Hidden \(app.hiddenAt.formatted(date: .abbreviated, time: .shortened)) · \(byteText(app.byteCount))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open while hidden") { protection.begin(.openHidden(app)) }
                                    .controlSize(.small)
                                    .disabled(protection.busy)
                                Button("Unhide") { protection.begin(.unhide(app)) }
                                    .controlSize(.small)
                                    .disabled(protection.busy)
                            }
                            .padding(14)
                            if app.id != protection.hiddenApps.last?.id { Divider() }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an app to hide"
        panel.prompt = "Hide"
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        protection.begin(.hide(url))
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct LockedItemsView: View {
    @ObservedObject var protection: ProtectionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(title: "Locked files",
                           subtitle: "Encrypt a folder or a single file in place; it comes back to the same path when you unlock it")

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("The original is removed only after the encrypted copy is verified.",
                              systemImage: "checkmark.shield")
                        Text("While locked, the item is gone from Finder and Spotlight and lives inside an AES-256 sparse bundle. Unlocking copies it back to its original location, so while it is unlocked the data is plaintext on disk, exactly as it was before.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button {
                        chooseItem()
                    } label: {
                        Label("Lock a folder or file…", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.opencloakAccent)
                    .disabled(protection.busy)
                    Text("System locations, your home folder itself, and the standard top-level folders are refused.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if protection.lockedItems.isEmpty {
                    EmptyStateView(title: "Nothing locked",
                                   symbol: "folder.badge.minus",
                                   detail: "Choose a folder or file to encrypt it in place.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(protection.lockedItems) { item in
                            HStack(spacing: 12) {
                                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                                    .font(.title3)
                                    .foregroundStyle(Color.opencloakAccent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name).font(.headline)
                                    Text(item.originalPath).font(.caption).foregroundStyle(.secondary)
                                    Text("\(item.fileCount) file\(item.fileCount == 1 ? "" : "s") · \(byteText(item.byteCount)) · locked \(item.lockedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Unlock") { protection.begin(.unlock(item)) }
                                    .controlSize(.small)
                                    .disabled(protection.busy)
                            }
                            .padding(14)
                            if item.id != protection.lockedItems.last?.id { Divider() }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chooseItem() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder or file to lock"
        panel.prompt = "Lock"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        protection.begin(.lock(url))
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ProtectionAuthView: View {
    @ObservedObject var protection: ProtectionStore
    let action: ProtectionStore.ProtectionAction

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var recoveryKey = ""
    @State private var enteringRecoveryKey = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(action.title).font(.title2.bold())
            Text("Enter your OpenCloak password or recovery key, or use Touch ID when it is available. Your Mac account password is not used.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if enteringRecoveryKey {
                SecureField("64-character recovery key", text: $recoveryKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { continueWithRecoveryKey() }
            } else {
                SecureField("OpenCloak password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { continueWithPassword() }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel") {
                    protection.pendingAction = nil
                    dismiss()
                }
                Spacer()
                Button("Use recovery key") {
                    enteringRecoveryKey.toggle()
                    password = ""
                    recoveryKey = ""
                }
                if OpenCloakDeviceKey.isBiometricOnlyAvailable() {
                    Button("Use Touch ID") { useTouchID() }
                }
                if enteringRecoveryKey {
                    Button("Unlock") { continueWithRecoveryKey() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.opencloakAccent)
                } else {
                    Button("Continue") {
                        continueWithPassword()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.opencloakAccent)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func useTouchID() {
        protection.authenticateUsingTouchID { success in
            guard success, let credential = protection.credential else {
                message = "Authentication did not complete. Try again or enter the password."
                return
            }
            protection.perform(action, credential: credential)
            dismiss()
        }
    }

    private func continueWithPassword() {
        guard protection.hasPassword else { return }
        guard !password.isEmpty else {
            message = "Enter the OpenCloak password."
            return
        }
        guard protection.authenticate(password: password) else {
            message = OpenCloakCredentialError.incorrectPassword.errorDescription
            return
        }
        guard let credential = protection.credential else {
            message = "OpenCloak could not unlock its key. Try Touch ID."
            return
        }
        protection.perform(action, credential: credential)
        dismiss()
    }

    private func continueWithRecoveryKey() {
        guard protection.authenticate(recoveryKey: recoveryKey),
              let credential = protection.credential else {
            message = OpenCloakCredentialError.incorrectPassword.errorDescription
            return
        }
        protection.perform(action, credential: credential)
        dismiss()
    }
}
