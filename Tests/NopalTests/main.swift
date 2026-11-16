import Foundation
import NopalCore

struct TestRunner {
    static func main() throws {
        try testLockedVaultCanBeginUnlocking()
        try testLockedVaultCannotSkipUnlock()
        try testMountedVaultMustLockInOrder()
        try testFailedVaultRequiresRecoveryTransition()
        try testWebsiteExactHostMatching()
        try testWebsitePathBoundaries()
        try testInvalidWebsitesAreRejected()
        try testRulesPersistWithPrivatePermissions()
        try testCorruptRulesAreNeverSilentlyOverwritten()
        try testDuplicateRulesAreRejected()
        try testLocalEventsAreCappedAndCleared()
        try testWebsiteMatcherStress()
        print("12 core tests passed")
    }

    static func testLockedVaultCanBeginUnlocking() throws {
        var state = VaultState(name: "Personal")
        try state.transition(to: .unlocking)
        try expect(state.phase == .unlocking, "locked vault enters unlocking")
    }

    static func testLockedVaultCannotSkipUnlock() throws {
        var state = VaultState(name: "Personal")
        try expectThrows("locked vault cannot become mounted") {
            try state.transition(to: .mounted)
        }
        try expect(state.phase == .locked, "rejected transition preserves state")
    }

    static func testMountedVaultMustLockInOrder() throws {
        var state = VaultState(name: "Personal", phase: .mounted)
        try expectThrows("mounted vault cannot jump to locked") {
            try state.transition(to: .locked)
        }
        try state.transition(to: .locking)
        try state.transition(to: .locked)
    }

    static func testFailedVaultRequiresRecoveryTransition() throws {
        var state = VaultState(name: "Personal", phase: .failed)
        try expectThrows("failed vault cannot become mounted") {
            try state.transition(to: .mounted)
        }
        try state.transition(to: .recoveryRequired)
        try state.transition(to: .locked)
    }

    static func testWebsiteExactHostMatching() throws {
        let pattern = try WebsitePattern("example.com")
        try expect(pattern.matches(URL(string: "https://example.com/account")!), "matches exact website host")
        try expect(!pattern.matches(URL(string: "https://sub.example.com/account")!), "does not broaden exact host to subdomains")
    }

    static func testWebsitePathBoundaries() throws {
        let pattern = try WebsitePattern("example.com/drive/abc")
        try expect(pattern.matches(URL(string: "https://example.com/drive/abc/child")!), "matches nested path")
        try expect(!pattern.matches(URL(string: "https://example.com/drive/abcdef")!), "does not match path prefix collision")
    }

    static func testInvalidWebsitesAreRejected() throws {
        try expectThrows("rejects unsupported URL schemes") { _ = try WebsitePattern("file:///etc/passwd") }
        try expectThrows("rejects URL credentials") { _ = try WebsitePattern("https://user@example.com") }
    }

    static func testRulesPersistWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rules.json")
        let store = PrivacyRuleStore(fileURL: file)
        let rule = try PrivacyRule(target: .website(WebsitePattern("example.com/private")))
        try store.add(rule)
        try expect(try store.all() == [rule], "persists rules")
        let fileMode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(fileMode == 0o600 && directoryMode == 0o700, "restricts local rule file permissions")
    }

    static func testCorruptRulesAreNeverSilentlyOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rules.json")
        let original = Data("{broken".utf8)
        try original.write(to: file)
        let store = PrivacyRuleStore(fileURL: file)
        try expectThrows("reports corrupt rules") { try store.add(PrivacyRule(target: .website(WebsitePattern("example.org")))) }
        try expect(try Data(contentsOf: file) == original, "preserves corrupt file for recovery")
    }

    static func testDuplicateRulesAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivacyRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
        try store.add(PrivacyRule(target: .website(WebsitePattern("example.net"))))
        try expectThrows("rejects duplicates") { try store.add(PrivacyRule(target: .website(WebsitePattern("https://example.net/")))) }
        try expect(try store.all().count == 1, "keeps one rule")
    }

    static func testLocalEventsAreCappedAndCleared() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EventLog(fileURL: directory.appendingPathComponent("events.json"))
        for index in 0..<300 {
            try store.record(EventRecord(category: .vault, outcome: .success, summary: "event-\(index)"))
        }
        let events = try store.all()
        try expect(events.count == EventLog.maximumEntries, "caps activity history")
        try expect(events.first?.summary == "event-299", "keeps newest activity first")
        try store.clear()
        try expect(try store.all().isEmpty, "clears local events")
    }

    static func testWebsiteMatcherStress() throws {
        let patterns = try (0..<50).map { try WebsitePattern("site\($0).example.com/private") }
        for round in 0..<200 {
            let url = URL(string: "https://site\(round % 50).example.com/private/document")!
            let matches = patterns.filter { $0.matches(url) }
            try expect(matches.count == 1, "matches exactly one rule in stress set")
        }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw TestFailure(message: message) }
    }

    static func expectThrows(_ message: String, _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw TestFailure(message: "expected error: \(message)")
        } catch is TestFailure {
            throw TestFailure(message: "expected error: \(message)")
        } catch { }
    }
}

try TestRunner.main()

struct TestFailure: Error {
    let message: String
}
