import Foundation
import OpenCloakCore

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
        try testVaultNamingRules()
        try testPreferenceClampingAndRoundTrip()
        try testAppearanceThemeCatalog()
        try testConfigurationExportIsCredentialFree()
        try testUnreadableHistoryIsQuarantined()
        try testEquivalentTargetsAreRecognised()
        try testApplicationRuleSelection()
        try testWebsiteRuleSelection()
        try testWebsitePresentationDeduplication()
        try testLaunchGateBlocksCoveredApps()
        try testPasswordRecordRoundTrip()
        try testRecoveryKeyRoundTrip()
        try testPasswordLengthPolicy()
        try testCorruptCredentialRecordCannotBeReplaced()
        try testLockScheduleBoundaries()
        try testLockScheduleOvernight()
        try testHiddenAppPolicyBoundaries()
        try testPlaceLockPolicyBoundaries()
        try testPlaceLockImageSizing()
        try testFileTreeMeasurement()
        try testIntruderCapturePolicy()
        try testIntruderPhotoRetention()
        print("34 core tests passed")
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

    static func testVaultNamingRules() throws {
        try expect(try VaultNaming.normalize("  Personal  ") == "Personal", "trims surrounding whitespace")
        try expect(VaultNaming.isValid("Work 2026-notes_x"), "accepts letters, digits, spaces, dashes and underscores")
        let invalid = ["", "   ", "-leading", "a/b", "../etc", String(repeating: "a", count: VaultNaming.maximumLength + 1)]
        for name in invalid {
            try expect(!VaultNaming.isValid(name), "rejects invalid vault name of \(name.count) characters")
        }
    }

    static func testPreferenceClampingAndRoundTrip() throws {
        let clamped = PreferenceValues(idleLockMinutes: 5_000, eventRetentionDays: -30)
        try expect(clamped.idleLockMinutes == 60, "clamps idle lock to the 60-minute maximum")
        try expect(PreferenceValues(idleLockMinutes: 0).idleLockMinutes == 5,
                   "enforces the 5-minute minimum idle-lock interval")
        try expect(PreferenceValues.idleChoices.first == 5 && PreferenceValues.idleChoices.last == 60,
                   "offers idle lock choices only within the 5–60 minute range")
        try expect(clamped.eventRetentionDays == 0, "clamps retention below zero")
        let suite = "app.opencloak.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = OpenCloakPreferences(defaults: defaults)
        let stored = PreferenceValues(idleLockMinutes: 15, lockOnSleep: false, lockOnScreenLock: true,
                                      eventRetentionDays: 90, requireBiometricOnly: true,
                                      appearanceTheme: .sakura, textSize: .large)
        preferences.store(stored)
        try expect(preferences.values == stored, "round-trips preference values")
        let legacy = try JSONDecoder().decode(PreferenceValues.self, from: Data("{}".utf8))
        try expect(legacy.appearanceTheme == .glass && legacy.textSize == .standard,
                   "defaults appearance values when importing older configuration files")
    }

    static func testAppearanceThemeCatalog() throws {
        let themes = OpenCloakAppearanceTheme.allCases
        try expect(themes.count == 7, "offers the seven OpenCloak appearance themes")
        try expect(Set(themes.map(\.rawValue)).count == 7, "appearance theme identifiers are unique")
        try expect(themes.map(\.displayName) == ["Glass", "White", "Dark", "Bubble", "Daisies", "Night Drive", "Sakura"],
                   "keeps the published theme names in stable order")
    }

    static func testConfigurationExportIsCredentialFree() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("opencloak-config.json")
        let snapshot = ConfigurationArchive.snapshot(rules: [try PrivacyRule(target: .website(try WebsitePattern("example.com/private")))],
                                                    preferences: PreferenceValues(idleLockMinutes: 10),
                                                    date: Date(timeIntervalSince1970: 1_700_000_000))
        try ConfigurationArchive.write(snapshot, to: file)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(mode == 0o600, "restricts exported configuration permissions")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ConfigurationSnapshot.self, from: Data(contentsOf: file))
        try expect(restored == snapshot, "round-trips exported configuration")
        let text = try String(contentsOf: file, encoding: .utf8).lowercased()
        for term in ["password", "recovery", "secret", "credential"] {
            try expect(!text.contains(term), "never exports \(term) material")
        }
    }

    static func testUnreadableHistoryIsQuarantined() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("events.json")
        let original = Data("{broken".utf8)
        try original.write(to: file)
        let store = EventLog(fileURL: file)
        try expect(try store.all().isEmpty, "starts a fresh log when history is unreadable")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard let backup = names.first(where: { $0.hasPrefix("events.unreadable.") }) else {
            throw TestFailure(message: "preserves unreadable history")
        }
        try expect(try Data(contentsOf: directory.appendingPathComponent(backup)) == original, "keeps the unreadable bytes")
    }

    static func testEquivalentTargetsAreRecognised() throws {
        let left: PrivacyRuleTarget = .website(try WebsitePattern("example.com/private"))
        let withSlash: PrivacyRuleTarget = .website(try WebsitePattern("https://example.com/private/"))
        try expect(left.coversSameTarget(as: withSlash), "treats a trailing slash as the same target")
        try expect(!left.coversSameTarget(as: .website(try WebsitePattern("example.com/private2"))), "distinguishes sibling paths")
        try expect(!left.coversSameTarget(as: .website(try WebsitePattern("example.com"))), "keeps host-wide and path rules distinct")
        let mail: PrivacyRuleTarget = .application(bundleIdentifier: "com.apple.mail", displayName: "Mail")
        try expect(mail.coversSameTarget(as: .application(bundleIdentifier: "com.apple.mail", displayName: "Mail (Beta)")),
                   "matches apps by bundle identifier, not display name")
    }

    static func testApplicationRuleSelection() throws {
        let mail = try PrivacyRule(target: .application(bundleIdentifier: "com.apple.mail", displayName: "Mail"))
        var disabled = try PrivacyRule(target: .application(bundleIdentifier: "com.apple.mail", displayName: "Mail"))
        disabled.enabled = false
        let notes = try PrivacyRule(target: .application(bundleIdentifier: "com.apple.Notes", displayName: "Notes"))
        let rules = [disabled, mail, notes]
        try expect(PrivacyScreenSelection.applicationRule(forBundleIdentifier: "com.apple.mail", in: rules)?.id == mail.id,
                   "selects the enabled rule for the activated app")
        try expect(PrivacyScreenSelection.applicationRule(forBundleIdentifier: "com.apple.mail", in: rules, unlocked: mail.id) == nil,
                   "does not re-cover an app whose screen was already unlocked")
        try expect(PrivacyScreenSelection.applicationRule(forBundleIdentifier: "com.apple.Safari", in: rules) == nil,
                   "ignores apps without a rule")
    }

    static func testWebsiteRuleSelection() throws {
        let privateRule = try PrivacyRule(target: .website(try WebsitePattern("example.com/private")))
        let siteRule = try PrivacyRule(target: .website(try WebsitePattern("example.com")))
        let rules = [privateRule, siteRule]
        let url = URL(string: "https://example.com/private/doc")!
        try expect(PrivacyScreenSelection.websiteRule(for: url, in: rules)?.id == privateRule.id,
                   "selects the first matching website rule")
        try expect(PrivacyScreenSelection.websiteRule(for: url, in: rules, unlocked: privateRule.id)?.id == siteRule.id,
                   "falls through to the next matching rule after an unlock")
        try expect(PrivacyScreenSelection.websiteRule(for: URL(string: "https://example.net/")!, in: rules) == nil,
                   "ignores unmatched hosts")
    }

    static func testWebsitePresentationDeduplication() throws {
        let rule = try PrivacyRule(target: .website(try WebsitePattern("example.com/private")))
        let first = URL(string: "https://example.com/private/a")!
        let second = URL(string: "https://example.com/private/b")!
        let key = PrivacyScreenSelection.key(rule: rule, url: first)
        try expect(PrivacyScreenSelection.shouldPresent(rule: rule, url: first, lastPresentedKey: nil),
                   "presents the first covered page")
        try expect(!PrivacyScreenSelection.shouldPresent(rule: rule, url: first, lastPresentedKey: key),
                   "does not re-present the same page on the next poll")
        try expect(PrivacyScreenSelection.shouldPresent(rule: rule, url: second, lastPresentedKey: key),
                   "presents again when the covered page changes")
    }

    static func testLaunchGateBlocksCoveredApps() throws {
        let mail = try PrivacyRule(target: .application(bundleIdentifier: "com.apple.mail", displayName: "Mail"))
        var disabled = try PrivacyRule(target: .application(bundleIdentifier: "com.apple.Notes", displayName: "Notes"))
        disabled.enabled = false
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let blocked = LaunchGate.blockedApplications(running: ["com.apple.mail", "com.apple.Notes",
                                                               "app.opencloak.privacy", "com.apple.Safari"],
                                                     rules: [mail, disabled],
                                                     allowances: [],
                                                     ownBundleIdentifier: "app.opencloak.privacy",
                                                     now: now)
        try expect(blocked == ["com.apple.mail"], "blocks only running apps with an enabled rule")
        let allowance = LaunchGate.allowance(for: "com.apple.mail", now: now, duration: 60)
        try expect(LaunchGate.blockedApplications(running: ["com.apple.mail"], rules: [mail],
                                                  allowances: [allowance],
                                                  ownBundleIdentifier: "app.opencloak.privacy",
                                                  now: now.addingTimeInterval(30)).isEmpty,
                   "an active allowance unblocks a covered app")
        try expect(LaunchGate.blockedApplications(running: ["com.apple.mail"], rules: [mail],
                                                  allowances: [allowance],
                                                  ownBundleIdentifier: "app.opencloak.privacy",
                                                  now: now.addingTimeInterval(120)) == ["com.apple.mail"],
                   "an expired allowance no longer applies")
    }

    static func testPasswordRecordRoundTrip() throws {
        let password = "correct horse battery"
        let record = try OpenCloakPasswordHasher.makeRecord(password: password)
        try expect(record.verifier.count == 32, "stores a 32-byte verifier")
        try expect(record.wrappedKey.ciphertext.count == 32, "wraps a 32-byte master key")
        guard let key = OpenCloakPasswordHasher.masterKey(password: password, record: record) else {
            throw TestFailure(message: "unwraps the master key with the correct password")
        }
        try expect(key.count == 32, "master key is 32 bytes")
        try expect(OpenCloakPasswordHasher.masterKey(password: "wrong password", record: record) == nil,
                   "rejects a wrong password")
        var tampered = record
        tampered.verifier = Data(repeating: 0, count: 32)
        try expect(OpenCloakPasswordHasher.masterKey(password: password, record: tampered) == nil,
                   "rejects a tampered verifier")
        let again = try OpenCloakPasswordHasher.makeRecord(password: password)
        try expect(again.salt != record.salt && again.verifier != record.verifier,
                   "uses a fresh salt for every record")
    }

    static func testRecoveryKeyRoundTrip() throws {
        let record = try OpenCloakPasswordHasher.makeRecord(password: "correct horse battery")
        guard let master = OpenCloakPasswordHasher.masterKey(password: "correct horse battery", record: record) else {
            throw TestFailure(message: "obtains the master key for recovery-key validation")
        }
        let recoveryKey = OpenCloakKeyFormatting.hex(master)
        try expect(OpenCloakPasswordHasher.masterKey(recoveryKey: recoveryKey, record: record) == master,
                   "recovery key restores the same master key")
        let replacementNibble = recoveryKey.last == "0" ? "1" : "0"
        try expect(OpenCloakPasswordHasher.masterKey(recoveryKey: String(recoveryKey.dropLast()) + replacementNibble, record: record) == nil,
                   "rejects a modified recovery key")
    }

    static func testLockScheduleBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = try AppLockSchedule(weekdays: [2], startMinute: 18 * 60, endMinute: 21 * 60)
        let inside = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 20))!
        let atEnd = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 21))!
        let wrongDay = calendar.date(from: DateComponents(year: 2026, month: 1, day: 6, hour: 20))!
        try expect(monday.isActive(at: inside, calendar: calendar), "locks within the selected weekday range")
        try expect(!monday.isActive(at: atEnd, calendar: calendar), "treats the schedule end as exclusive")
        try expect(!monday.isActive(at: wrongDay, calendar: calendar), "does not lock on unselected weekdays")
    }

    static func testLockScheduleOvernight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fridayNight = try AppLockSchedule(weekdays: [6], startMinute: 22 * 60, endMinute: 2 * 60)
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 1))!
        let saturdayEvening = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 23))!
        try expect(fridayNight.isActive(at: saturday, calendar: calendar), "carries an overnight range into the next day")
        try expect(!fridayNight.isActive(at: saturdayEvening, calendar: calendar), "does not start the range on an unselected day")
    }

    static func testPasswordLengthPolicy() throws {
        try expectThrows("rejects passwords below the minimum") {
            _ = try OpenCloakPasswordHasher.makeRecord(password: "short")
        }
    }

    static func testCorruptCredentialRecordCannotBeReplaced() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let damaged = Data("{damaged credential".utf8)
        try damaged.write(to: file)
        let identity = OpenCloakIdentity(fileURL: file)
        try expect(identity.hasPassword, "treats an existing credential record as configured even if damaged")
        try expectThrows("does not replace a damaged credential record") {
            _ = try identity.setPassword("new secure password")
        }
        try expect(try Data(contentsOf: file) == damaged, "preserves damaged credential data for recovery")
    }

    static func testHiddenAppPolicyBoundaries() throws {
        try expect(HiddenAppPolicy.isHideable(path: "/Applications/Notes.app", bundleIdentifier: "com.apple.Notes"),
                   "hides a normal app bundle")
        try expect(!HiddenAppPolicy.isHideable(path: "/System/Applications/Mail.app", bundleIdentifier: "com.apple.mail"),
                   "refuses system apps")
        try expect(!HiddenAppPolicy.isHideable(path: "/Applications/OpenCloak.app",
                                              bundleIdentifier: "app.opencloak.privacy",
                                              ownBundleIdentifier: "app.opencloak.privacy"),
                   "refuses to hide OpenCloak itself")
        try expect(!HiddenAppPolicy.isHideable(path: "/Applications/Notes.app/Contents", bundleIdentifier: "com.apple.Notes"),
                   "requires the bundle root")
        try expect(!HiddenAppPolicy.isHideable(path: "/Users/mac/notes.txt", bundleIdentifier: "com.example.notes"),
                   "rejects non-bundles")
    }

    static func testPlaceLockPolicyBoundaries() throws {
        let home = "/Users/tester"
        try expect(!PlaceLockPolicy.isAllowed(path: "/System/Library", home: home), "refuses system folders")
        try expect(!PlaceLockPolicy.isAllowed(path: "/", home: home), "refuses the filesystem root")
        try expect(!PlaceLockPolicy.isAllowed(path: "/Users/tester/Documents", home: home),
                   "refuses the Documents folder itself")
        try expect(PlaceLockPolicy.isAllowed(path: "/Users/tester/Documents/taxes", home: home),
                   "allows a folder inside Documents")
        try expect(PlaceLockPolicy.isAllowed(path: "/Volumes/USB/private", home: home),
                   "allows external volumes")
        try expect(!PlaceLockPolicy.isAllowed(path: "/Users/tester/Library", home: home),
                   "refuses the Library folder")
    }

    static func testPlaceLockImageSizing() throws {
        try expect(PlaceLockPolicy.imageSize(forBytes: 0) == "100m", "uses a 100 MB floor")
        try expect(PlaceLockPolicy.imageSize(forBytes: 100 * 1_048_576) == "182m",
                   "leaves headroom above the data size")
        try expect(PlaceLockPolicy.imageSize(forBytes: 500_000_000_000) == "200000m",
                   "caps the image at 200 GB")
    }

    static func testFileTreeMeasurement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 3).write(to: directory.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 5).write(to: directory.appendingPathComponent("b.bin"))
        let stats = FileTreeStats.measure(directory)
        try expect(stats?.files == 2 && stats?.bytes == 8, "measures file count and byte count")
    }

    static func testIntruderCapturePolicy() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try expect(!IntruderCapturePolicy.shouldCapture(isEnabled: false, authenticationSucceeded: false,
                                                        lastCapture: nil, now: now),
                   "does nothing when intruder photos are off")
        try expect(!IntruderCapturePolicy.shouldCapture(isEnabled: true, authenticationSucceeded: true,
                                                        lastCapture: nil, now: now),
                   "never captures after a successful unlock")
        try expect(IntruderCapturePolicy.shouldCapture(isEnabled: true, authenticationSucceeded: false,
                                                       lastCapture: nil, now: now),
                   "captures a failed unlock")
        try expect(!IntruderCapturePolicy.shouldCapture(isEnabled: true, authenticationSucceeded: false,
                                                        lastCapture: now.addingTimeInterval(-1), now: now),
                   "applies a minimum interval between photos")
    }

    static func testIntruderPhotoRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = IntruderPhotoStore(directory: directory)
        for _ in 0..<5 {
            try store.record(Data([0xFF, 0xD8, 0xFF]), limit: 3)
        }
        try expect(store.all().count == 3, "keeps only the newest intruder photos")
        try store.deleteAll()
        try expect(store.all().isEmpty, "deletes every intruder photo")
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
