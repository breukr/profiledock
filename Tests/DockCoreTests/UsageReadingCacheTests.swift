import XCTest
@testable import DockCore

final class UsageReadingCacheTests: XCTestCase {
    private var folder: URL!
    private var url: URL { folder.appendingPathComponent("Account Dock/usage-cache.json") }
    private let identity = String(repeating: "ab", count: 32)

    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-cache-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func snapshot(_ identity: String? = nil, used: Double = 40) -> UsageSnapshot {
        UsageSnapshot(identity: identity ?? self.identity, plan: "max",
                      windows: [UsageWindow(id: "five_hour", duration: 18000, usedPercent: used, resetsAt: Date(timeIntervalSince1970: 1_900_000_000))],
                      bankedResets: 1, applicableResets: 0, resetExpiries: [Date(timeIntervalSince1970: 1_900_100_000)],
                      fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                      modelWindows: [UsageWindow(id: "seven_day_opus", duration: 604800, usedPercent: 12, resetsAt: nil)])
    }

    func testReadingsAndRemindersSurviveANewInstance() throws {
        let cache = UsageReadingCache(url: url)
        cache.store(snapshot(), for: "claude-account|claude")
        cache.setReminder(.init(lastNudgedAt: Date(timeIntervalSince1970: 1_800_000_100), snoozedUntil: Date(timeIntervalSince1970: 1_800_086_400)), for: "claude-account")
        let reloaded = UsageReadingCache(url: url)
        XCTAssertEqual(reloaded.reading(for: "claude-account|claude")?.snapshot, snapshot())
        XCTAssertEqual(reloaded.reading(for: "claude-account|claude")?.identity, identity)
        XCTAssertEqual(reloaded.reminder(for: "claude-account").snoozedUntil, Date(timeIntervalSince1970: 1_800_086_400))
        reloaded.retain(readings: [], reminders: ["claude-account"])
        XCTAssertNil(UsageReadingCache(url: url).reading(for: "claude-account|claude"))
        XCTAssertNotNil(UsageReadingCache(url: url).reminder(for: "claude-account").lastNudgedAt)
    }

    func testFileHoldsOnlyReadingFieldsAndIsPrivate() throws {
        let cache = UsageReadingCache(url: url)
        cache.store(snapshot(), for: "codex:work|work")
        cache.setReminder(.init(lastNudgedAt: Date()), for: "codex:work")
        let allowed: Set<String> = ["version", "readings", "reminders", "identity", "snapshot", "plan", "windows", "id", "duration", "usedPercent",
                                    "resetsAt", "bankedResets", "applicableResets", "resetExpiries", "fetchedAt", "hasUnparsedWindows",
                                    "modelWindows", "lastNudgedAt", "snoozedUntil"]
        var seen = Set<String>()
        func walk(_ value: Any, dynamicKeys: Bool = false) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    if !dynamicKeys { seen.insert(key) }
                    walk(child, dynamicKeys: !dynamicKeys && (key == "readings" || key == "reminders"))
                }
            } else if let array = value as? [Any] { array.forEach { walk($0) } }
        }
        walk(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        XCTAssertTrue(seen.isSubset(of: allowed), "Unexpected keys: \(seen.subtracting(allowed))")
        let text = try String(contentsOf: url, encoding: .utf8)
        for secret in ["token", "cookie", "session", "Bearer", "refresh"] { XCTAssertFalse(text.lowercased().contains(secret.lowercased())) }
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // Identities that are not one-way digests are never written.
        cache.store(snapshot("raw-account-id"), for: "codex:other|other")
        XCTAssertNil(UsageReadingCache(url: url).reading(for: "codex:other|other"))
    }

    func testCorruptOrForeignFileIsIgnoredAndReplaced() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let cache = UsageReadingCache(url: url)
        XCTAssertTrue(cache.readingKeys.isEmpty)
        cache.store(snapshot(), for: "a|a")
        XCTAssertNotNil(UsageReadingCache(url: url).reading(for: "a|a"))
        // A reading whose identity does not match its snapshot is dropped on load.
        try Data(#"{"version":1,"reminders":{},"readings":{"a|a":{"identity":"\#(String(repeating: "cd", count: 32))","snapshot":{"identity":"\#(identity)","windows":[],"fetchedAt":1}}}}"#.utf8).write(to: url)
        XCTAssertNil(UsageReadingCache(url: url).reading(for: "a|a"))
        try Data(#"{"version":2,"readings":{},"reminders":{}}"#.utf8).write(to: url)
        XCTAssertTrue(UsageReadingCache(url: url).readingKeys.isEmpty)
    }

    func testOlderSnapshotJSONWithoutModelWindowsStillDecodes() throws {
        let json = #"{"identity":"x","windows":[{"id":"seven_day","duration":604800,"usedPercent":5}],"fetchedAt":1}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let value = try decoder.decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(value.modelWindows, [])
        XCTAssertFalse(value.hasUnparsedWindows)
        XCTAssertNil(value.windows.first?.resetsAt)
    }

    func testPastResetAndModelWindowTitles() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(UsageWindow(id: "five_hour", duration: 18000, usedPercent: 90, resetsAt: now.addingTimeInterval(-1)).isPastReset(now: now))
        XCTAssertTrue(UsageWindow(id: "five_hour", duration: 18000, usedPercent: 90, resetsAt: now).isPastReset(now: now))
        XCTAssertFalse(UsageWindow(id: "five_hour", duration: 18000, usedPercent: 90, resetsAt: now.addingTimeInterval(60)).isPastReset(now: now))
        XCTAssertFalse(UsageWindow(id: "five_hour", duration: 18000, usedPercent: 90, resetsAt: nil).isPastReset(now: now))
        XCTAssertEqual(UsageWindow(id: "seven_day_opus", duration: 604800, usedPercent: 0, resetsAt: nil).title, "Opus week")
        XCTAssertEqual(UsageWindow(id: "seven_day_sonnet", duration: 604800, usedPercent: 0, resetsAt: nil).title, "Sonnet week")
        XCTAssertEqual(UsageWindow(id: "seven_day", duration: 604800, usedPercent: 0, resetsAt: nil).title, "Week")
    }
}

final class ClaudeWebUsageTests: XCTestCase {
    // Fictional ids only.
    let accountID = "11111111-1111-1111-1111-111111111111"
    let personal = "22222222-2222-2222-2222-222222222222", team = "33333333-3333-3333-3333-333333333333", api = "44444444-4444-4444-4444-444444444444"

    func testUsagePayloadParsesWindowsResetsAndPerModelWeeks() throws {
        let json = #"""
        {"five_hour":{"utilization":35,"resets_at":"2027-01-01T05:00:00.000Z"},
         "seven_day":{"utilization":61.5,"resets_at":"2027-01-06T00:00:00Z"},
         "seven_day_opus":{"utilization":20,"resets_at":"2027-01-06T00:00:00Z"},
         "seven_day_sonnet":null, "seven_day_oauth_apps":null,
         "cedar_ember":{"eligible":true,"grants":[{"id":"g1","resets_left":2,"usable_now":true}]}}
        """#
        let reading = try ClaudeWebUsage.snapshot(usage: Data(json.utf8), identity: "id", plan: nil, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(reading.windows.map(\.id), ["seven_day", "five_hour"])
        XCTAssertEqual(reading.windows.first?.usedPercent, 61.5)
        XCTAssertEqual(reading.modelWindows.map(\.id), ["seven_day_opus"])
        XCTAssertEqual(reading.modelWindows.first?.usedPercent, 20)
        XCTAssertEqual(reading.bankedResets, 2)
        XCTAssertEqual(reading.applicableResets, 2)
        XCTAssertThrowsError(try ClaudeWebUsage.snapshot(usage: Data(#"{"error":"nope"}"#.utf8), identity: "id", plan: nil, fetchedAt: Date()))
        XCTAssertEqual(ClaudeWebUsage.modelWindows(Data(#"{"seven_day_opus":{"utilization":true},"seven_day_sonnet":{"utilization":-1}}"#.utf8)), [])
    }

    func testSignedOutRedirectAndRateLimitMapping() {
        XCTAssertEqual(ClaudeWebUsage.failure(status: 401), .signedOut)
        XCTAssertEqual(ClaudeWebUsage.failure(status: 403), .signedOut)
        XCTAssertEqual(ClaudeWebUsage.failure(status: 0), .signedOut, "An opaque redirect to the login page means signed out")
        XCTAssertEqual(ClaudeWebUsage.failure(status: 429), .rateLimited)
        XCTAssertEqual(ClaudeWebUsage.failure(status: 500), .unavailable)
    }

    func testOrganizationComesFromTheWebSessionAndPrefersTheVerifiedOne() throws {
        let organizations: [[String: Any]] = [["uuid": api, "capabilities": ["api"]], ["uuid": personal, "capabilities": ["chat", "claude_max"]], ["uuid": team, "capabilities": ["chat"]], ["uuid": "not-a-uuid"]]
        let account = try XCTUnwrap(ClaudeWebUsage.account(account: ["uuid": accountID], organizations: organizations))
        XCTAssertEqual(account.organizations, [personal, team], "API-only organizations have no chat usage")
        XCTAssertEqual(ClaudeWebUsage.organization(for: account, knownIdentity: nil), personal)
        let teamIdentity = ClaudeWebUsage.identity(accountID: accountID, organizationID: team)
        XCTAssertEqual(ClaudeWebUsage.organization(for: account, knownIdentity: teamIdentity), team)
        XCTAssertNil(ClaudeWebUsage.account(account: ["uuid": "bad"], organizations: organizations))
        XCTAssertNil(ClaudeWebUsage.account(account: ["uuid": accountID], organizations: [["uuid": "bad"]]))
        XCTAssertNil(ClaudeWebUsage.account(account: nil, organizations: organizations))
    }
}
