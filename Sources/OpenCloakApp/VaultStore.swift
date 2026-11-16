import AppKit
import Foundation
import OpenCloakCore

extension Notification.Name {
    static let opencloakVaultsChanged = Notification.Name("app.opencloak.vaultsChanged")
    static let opencloakRulesChanged = Notification.Name("app.opencloak.rulesChanged")
}

struct CredentialPrompt: Identifiable {
    enum Purpose: Equatable {
        case unlock
        case finish
    }

    let id = UUID()
    let item: VaultItem
    let purpose: Purpose
}

/// Observable wrapper around the local event log. All mutations happen on the main thread.
final class ActivityCenter: ObservableObject {
    static let shared = ActivityCenter()

    @Published private(set) var events: [EventRecord] = []
    @Published var errorMessage: String?

    private let log: EventLog

    init(log: EventLog = EventLog()) {
        self.log = log
        reload()
    }

    func reload() {
        do {
            events = try log.recent(limit: 25)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func record(_ category: EventCategory, _ outcome: EventOutcome, _ summary: String) {
        do {
            try log.record(EventRecord(category: category, outcome: outcome, summary: summary))
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        do {
            try log.clear()
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prune(retentionDays: Int) {
        guard retentionDays > 0 else { return }
        do {
            try log.prune(olderThanDays: retentionDays)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var items: [VaultItem] = []
    @Published private(set) var busy = false
    @Published var errorMessage: String?
    @Published var recoveryCredential: String?
    @Published var credentialPrompt: CredentialPrompt?

    private let service: VaultService
    private let activity: ActivityCenter
    private var vaultsObserver: NSObjectProtocol?

    init(service: VaultService = .shared, activity: ActivityCenter = .shared) {
        self.service = service
        self.activity = activity
        refresh()
        vaultsObserver = NotificationCenter.default.addObserver(forName: .opencloakVaultsChanged,
                                                                object: nil,
                                                                queue: .main) { [weak self] _ in
            guard let owner = self else { return }
            DispatchQueue.main.async { [weak owner] in owner?.refresh() }
        }
    }

    func refresh() {
        items = service.list()
    }

    func create(name: String, size: String) {
        guard !busy else { return }
        busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let outcome: Result<String, Error>
            do {
                outcome = .success(try service.create(name: name, size: size))
            } catch {
                outcome = .failure(error)
            }
            await MainActor.run {
                self.busy = false
                switch outcome {
                case .success(let credential):
                    self.recoveryCredential = credential
                    self.activity.record(.vault, .success, "Created an encrypted vault")
                case .failure(let error):
                    self.errorMessage = error.localizedDescription
                    self.activity.record(.vault, .failure, "Could not create an encrypted vault")
                }
                self.refresh()
            }
        }
    }

    func unlock(_ item: VaultItem, credential: String? = nil) {
        guard !busy else { return }
        busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let failure: Error?
            do {
                try service.unlock(item, credential: credential)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                self.busy = false
                if let failure {
                    self.errorMessage = failure.localizedDescription
                    self.activity.record(.vault, .failure, "Could not unlock a vault")
                } else {
                    self.activity.record(.vault, .success, "Unlocked a vault")
                }
                self.refresh()
            }
        }
    }

    func lock(_ item: VaultItem) {
        guard !busy else { return }
        busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let failure: Error?
            do {
                try service.lockVault(item)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                self.busy = false
                if let failure {
                    self.errorMessage = failure.localizedDescription
                    self.activity.record(.vault, .failure, "Could not eject a vault; it is still mounted")
                } else {
                    self.activity.record(.vault, .success, "Ejected a vault")
                }
                self.refresh()
            }
        }
    }

    func lockAll() {
        guard !busy, items.contains(where: \.mounted) else { return }
        busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let failures = service.lockAllMounted()
            await MainActor.run {
                self.busy = false
                if failures.isEmpty {
                    self.activity.record(.vault, .success, "Locked all mounted vaults")
                } else {
                    self.activity.record(.vault, .failure,
                                         "\(failures.count) mounted vault could not be ejected and is still mounted")
                    self.errorMessage = "One or more vaults are in use. Close their files and try again."
                }
                self.refresh()
            }
        }
    }

    func importVault(from source: URL, as name: String) {
        guard !busy else { return }
        busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let failure: Error?
            do {
                _ = try service.importVault(from: source, as: name)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                self.busy = false
                if let failure {
                    self.errorMessage = failure.localizedDescription
                    self.activity.record(.vault, .failure, "Could not import a vault")
                } else {
                    self.activity.record(.vault, .success, "Imported a copy of an encrypted vault")
                }
                self.refresh()
            }
        }
    }

    func export(_ item: VaultItem, to directory: URL) {
        guard !busy else { return }
        busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let failure: Error?
            do {
                _ = try service.export(item, to: directory)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                self.busy = false
                if let failure {
                    self.errorMessage = failure.localizedDescription
                    self.activity.record(.vault, .failure, "Could not export a vault copy")
                } else {
                    self.activity.record(.vault, .success, "Exported a verified vault copy")
                }
                self.refresh()
            }
        }
    }

    func finishInterrupted(_ item: VaultItem, credential: String?) {
        guard !busy else { return }
        busy = true
        let service = service
        Task.detached(priority: .userInitiated) {
            let failure: Error?
            do {
                _ = try service.finishInterruptedCreation(item, credential: credential)
                failure = nil
            } catch {
                failure = error
            }
            await MainActor.run {
                self.busy = false
                if let failure {
                    self.errorMessage = failure.localizedDescription
                    self.activity.record(.vault, .failure, "Could not finish an interrupted vault")
                } else {
                    self.activity.record(.vault, .success, "Finished an interrupted vault setup")
                }
                self.refresh()
            }
        }
    }

    func reveal(_ item: VaultItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
    }
}
