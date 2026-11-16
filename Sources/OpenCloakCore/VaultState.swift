import Foundation

public enum VaultPhase: String, Codable, Equatable {
    case locked
    case unlocking
    case mounted
    case locking
    case recoveryRequired
    case failed
}

public struct VaultState: Equatable {
    public let name: String
    public private(set) var phase: VaultPhase

    public init(name: String, phase: VaultPhase = .locked) {
        self.name = name
        self.phase = phase
    }

    public mutating func transition(to next: VaultPhase) throws {
        let allowed: Bool
        switch (phase, next) {
        case (.locked, .unlocking),
             (.unlocking, .mounted), (.unlocking, .locked), (.unlocking, .failed),
             (.mounted, .locking),
             (.locking, .locked), (.locking, .mounted), (.locking, .failed),
             (.failed, .recoveryRequired), (.failed, .locked),
             (.recoveryRequired, .locked), (.recoveryRequired, .failed):
            allowed = true
        default:
            allowed = false
        }
        guard allowed else { throw VaultStateError.invalidTransition(from: phase, to: next) }
        phase = next
    }
}

public enum VaultStateError: Error, Equatable {
    case invalidTransition(from: VaultPhase, to: VaultPhase)
}
