import AppKit
import OpenCloakCore
import SwiftUI

struct SetupAssistantView: View {
    @ObservedObject var protection: ProtectionStore
    @State private var password = ""
    @State private var confirmation = ""
    @State private var existingPassword = ""
    @State private var acknowledgedRecovery = false
    @State private var copied = false
    @State private var message: String?

    private var hasTouchID: Bool { OpenCloakDeviceKey.isBiometricOnlyAvailable() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(Color.opencloakAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up OpenCloak").font(.title2.bold())
                    Text("Your protection stays on this Mac.").foregroundStyle(.secondary)
                }
                Spacer()
                Text("1 of 1")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 22)

            if let key = protection.setupRecoveryKey {
                recoveryStep(key)
            } else if protection.hasPassword {
                existingInstallationStep
            } else {
                passwordStep
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
        }
        .padding(32)
        .frame(width: 620)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your unlock methods")
                .font(.headline)
            Label(hasTouchID ? "Touch ID is available on this Mac" : "Touch ID is unavailable; your OpenCloak password will unlock protected items",
                  systemImage: hasTouchID ? "touchid" : "key.fill")
                .foregroundStyle(.secondary)
            Text("Create a separate OpenCloak password. Your Mac account password will not unlock OpenCloak. You can use Touch ID when available and keep this password as the fallback.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("OpenCloak password (8 characters minimum)", text: $password)
                .textFieldStyle(.roundedBorder)
            SecureField("Confirm OpenCloak password", text: $confirmation)
                .textFieldStyle(.roundedBorder)
                .onSubmit(createPassword)
            HStack {
                Spacer()
                Button("Continue", action: createPassword)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.opencloakAccent)
                    .disabled(password.count < OpenCloakPasswordHasher.minimumCharacters || password != confirmation)
            }
        }
    }

    private var existingInstallationStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm your existing password")
                .font(.headline)
            Text("OpenCloak found an existing password. Enter it to show and verify your recovery key before continuing.")
                .foregroundStyle(.secondary)
            SecureField("OpenCloak password", text: $existingPassword)
                .textFieldStyle(.roundedBorder)
                .onSubmit(revealRecoveryKey)
            HStack {
                Spacer()
                Button("Continue", action: revealRecoveryKey)
                    .buttonStyle(.borderedProminent)
                    .tint(Color.opencloakAccent)
            }
        }
    }

    private func recoveryStep(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Save your recovery key", systemImage: "key.fill")
                .font(.headline)
            Text("This key can unlock your encrypted items and reset your OpenCloak password. It is shown only during setup. Store it somewhere private, separate from this Mac.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(key)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            HStack {
                Button(copied ? "Copied" : "Copy recovery key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                    copied = true
                }
                Toggle("I saved this key somewhere safe", isOn: $acknowledgedRecovery)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Finish setup") { protection.finishSetup() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.opencloakAccent)
                    .disabled(!acknowledgedRecovery)
            }
            Text("Losing both your password and recovery key means the encrypted data cannot be recovered.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func createPassword() {
        guard password == confirmation else {
            message = OpenCloakCredentialError.passwordMismatch.localizedDescription
            return
        }
        protection.setPassword(password, confirmation: confirmation)
        password = ""
        confirmation = ""
        message = protection.setupRecoveryKey == nil ? protection.errorMessage : nil
    }

    private func revealRecoveryKey() {
        if !protection.revealRecoveryKey(using: existingPassword) {
            message = protection.errorMessage
            return
        }
        existingPassword = ""
        message = nil
    }
}
