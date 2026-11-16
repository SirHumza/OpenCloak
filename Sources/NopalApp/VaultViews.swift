import AppKit
import NopalCore
import SwiftUI
import UniformTypeIdentifiers

struct OverviewView: View {
    @EnvironmentObject private var vaults: VaultStore
    @EnvironmentObject private var activity: ActivityCenter
    @ObservedObject var rules: RuleListModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Overview", subtitle: "Your privacy tools at a glance")

                HStack(spacing: 14) {
                    MetricCard(title: "Vaults", value: "\(vaults.items.filter { !$0.pending }.count)", symbol: "lock.shield")
                    MetricCard(title: "Mounted", value: "\(vaults.items.filter(\.mounted).count)", symbol: "externaldrive")
                    MetricCard(title: "Privacy rules", value: "\(rules.rules.filter(\.enabled).count)", symbol: "hand.raised")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Everything stays on this Mac", systemImage: "checkmark.shield.fill")
                            .font(.headline)
                        Text("Nopal has no account, telemetry, analytics, or network requirement. A vault's contents are protected while it is locked. A mounted vault stays readable until you eject it.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Recent activity", systemImage: "clock")
                            Spacer()
                            Text("Stored locally · no file names or URLs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if activity.events.isEmpty {
                            Text("No activity yet.").foregroundStyle(.secondary)
                        } else {
                            ForEach(activity.events.prefix(6)) { record in
                                ActivityRow(record: record)
                                if record.id != activity.events.prefix(6).last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("What Nopal does not do", systemImage: "exclamationmark.shield")
                            .font(.headline)
                        Text("Privacy screens cover the screen after macOS reports an app activation or a matching page in a supported browser. They do not stop apps or their background helpers from running, and they cannot protect against an administrator, malware running as you, or someone using a Mac that is already unlocked.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VaultsView: View {
    @EnvironmentObject private var vaults: VaultStore
    @State private var showingCreate = false
    @State private var importSource: ImportSource?
    @State private var credentialPrompt: CredentialPrompt?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    PageHeader(title: "Your vaults", subtitle: "Encrypted spaces for private files and data")
                    Spacer()
                    Button {
                        showingCreate = true
                    } label: {
                        Label("New vault", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.nopalAccent)

                    Button {
                        chooseImportSource()
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }

                if vaults.items.isEmpty {
                    EmptyStateView(title: "No vaults yet",
                                   symbol: "lock.shield",
                                   detail: "Create an encrypted vault on this Mac, or import a copy of an existing Nopal sparse bundle.")
                    HStack(spacing: 12) {
                        Button("Create your first vault") { showingCreate = true }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.nopalAccent)
                        Button("Import a vault…") { chooseImportSource() }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(vaults.items) { item in
                            VaultRow(item: item) { prompt in credentialPrompt = prompt }
                            if item.id != vaults.items.last?.id { Divider() }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))

                    GroupBox {
                        Label("A mounted vault stays accessible until it is ejected. Nopal never claims a vault is protected while it is mounted.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingCreate) {
            CreateVaultView()
        }
        .sheet(item: $importSource) { source in
            ImportVaultView(source: source.url)
        }
        .sheet(item: $credentialPrompt) { prompt in
            CredentialPromptView(prompt: prompt)
        }
    }

    private func chooseImportSource() {
        let panel = NSOpenPanel()
        panel.title = "Choose an encrypted sparse bundle"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "sparsebundle") {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let url = panel.url {
            importSource = ImportSource(url: url)
        }
    }
}

private struct ImportSource: Identifiable {
    let id = UUID()
    let url: URL
}

private struct VaultRow: View {
    @EnvironmentObject private var vaults: VaultStore
    let item: VaultItem
    let onCredentialPrompt: (CredentialPrompt) -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.nopalAccent)
                .frame(width: 42, height: 42)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            StatusBadge(text: badgeText, tint: badgeTint)

            controls
        }
        .padding(14)
    }

    @ViewBuilder
    private var controls: some View {
        if item.pending {
            Button("Finish setup") {
                vaults.finishInterrupted(item, credential: nil)
            }
            .help("Verify the temporary vault with the Keychain credential and finish setup")
            Menu {
                Button("Finish with recovery key…") {
                    onCredentialPrompt(CredentialPrompt(item: item, purpose: .finish))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            .disabled(vaults.busy)
        } else if item.mounted {
            Button("Reveal") { vaults.reveal(item) }
            Button("Eject") { vaults.lock(item) }
                .disabled(vaults.busy)
        } else {
            Menu {
                if item.hasStoredCredential {
                    Button("Unlock with Touch ID or password") { vaults.unlock(item) }
                } else {
                    Button("Unlock with vault password…") {
                        onCredentialPrompt(CredentialPrompt(item: item, purpose: .unlock))
                    }
                }
                Button("Unlock with recovery key…") {
                    onCredentialPrompt(CredentialPrompt(item: item, purpose: .unlock))
                }
                Divider()
                Button("Reveal in Finder") { vaults.reveal(item) }
                Button("Export verified copy…") { exportCopy() }
            } label: {
                Label("Unlock", systemImage: "lock.open")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 92)
            .disabled(vaults.busy)
        }
    }

    private func exportCopy() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for the exported copy"
        panel.prompt = "Export here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let directory = panel.url {
            vaults.export(item, to: directory)
        }
    }

    private var symbol: String {
        if item.pending { return "exclamationmark.triangle.fill" }
        return item.mounted ? "externaldrive.fill" : "lock.fill"
    }

    private var detail: String {
        if item.pending {
            return "Interrupted setup. Nopal kept the temporary vault so nothing is lost."
        }
        if item.mounted {
            return "Mounted at \(item.mountPoint?.path ?? "a volume")"
        }
        if item.hasStoredCredential {
            return "APFS · AES-256 encrypted · Keychain credential"
        }
        return "APFS · AES-256 encrypted · Vault password required"
    }

    private var badgeText: String {
        if item.pending { return "Needs setup" }
        return item.mounted ? "Mounted" : "Locked"
    }

    private var badgeTint: Color {
        if item.pending { return .orange }
        return item.mounted ? .green : .secondary
    }
}

private struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct CreateVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vaults: VaultStore
    @State private var name = ""
    @State private var size = "4g"

    private let sizes = ["1g", "2g", "4g", "8g", "16g", "32g"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create an encrypted vault").font(.title2.bold())
            Text("Nopal uses Apple's encrypted sparse disk image format (APFS, AES-256). The vault grows as you add files, up to the maximum size you choose.")
                .foregroundStyle(.secondary)

            TextField("Vault name", text: $name)
                .textFieldStyle(.roundedBorder)

            Picker("Maximum size", selection: $size) {
                ForEach(sizes, id: \.self) { value in
                    Text(value.uppercased()).tag(value)
                }
            }

            Text("Nopal generates a 256-bit key, stores it in the macOS Keychain behind Touch ID or your Mac password, and shows it once as a recovery key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create vault") {
                    vaults.create(name: name, size: size)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!VaultNaming.isValid(name) || vaults.busy)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

struct ImportVaultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vaults: VaultStore
    let source: URL
    @State private var name: String

    init(source: URL) {
        self.source = source
        _name = State(initialValue: source.deletingPathExtension().lastPathComponent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import a vault").font(.title2.bold())
            Text("Nopal copies the encrypted sparse bundle into its vault folder and verifies the copy. The original is never moved, replaced, or deleted.")
                .foregroundStyle(.secondary)
            Text(source.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            TextField("Vault name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("The imported vault needs its existing password the first time you unlock it. Nopal then saves that credential in the Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    vaults.importVault(from: source, as: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!VaultNaming.isValid(name) || vaults.busy)
            }
        }
        .padding(24)
        .frame(width: 540)
    }
}

struct CredentialPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var vaults: VaultStore
    let prompt: CredentialPrompt
    @State private var credential = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.purpose == .finish ? "Finish interrupted setup" : "Unlock \(prompt.item.name)")
                .font(.title2.bold())
            Text(prompt.purpose == .finish
                 ? "Enter the recovery key saved when this vault was created. Nopal verifies it by opening the temporary vault before finishing setup."
                 : "Enter the vault password or the recovery key saved when this vault was created. Nopal verifies it before saving it in the Keychain.")
                .foregroundStyle(.secondary)
            SecureField("Vault password or recovery key", text: $credential)
                .textFieldStyle(.roundedBorder)
            Text("Neither value is stored in logs, activity history, or process arguments.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(prompt.purpose == .finish ? "Finish setup" : "Unlock") {
                    switch prompt.purpose {
                    case .unlock: vaults.unlock(prompt.item, credential: credential)
                    case .finish: vaults.finishInterrupted(prompt.item, credential: credential)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(credential.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct RecoveryItem: Identifiable {
    let value: String
    var id: String { value }
    init(_ value: String) { self.value = value }
}

struct RecoveryKeyView: View {
    let credential: String
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Save your recovery key", systemImage: "key.fill").font(.title2.bold())
            Text("This key can open your vault if the Keychain credential is lost. Nopal cannot recover it for you, and there is no second copy. Store it somewhere private and separate from this Mac.")
                .foregroundStyle(.secondary)
            Text(credential)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            Text("Losing both Keychain access and this key makes the vault unrecoverable.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Copied" : "Copy key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(credential, forType: .string)
                    copied = true
                }
                Spacer()
                Button("I saved it") { done() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}
