import XCTest
@testable import DockCore

final class GrokBotUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)
    private let account = "grok|user_01FIXTURE"

    private func grokBot(isolated: Bool = false) -> Profile {
        var profile = Profile(id: "profile-grok", name: "Grok Bot", color: "8E8E93")
        profile.provider = .agent; profile.agentID = GrokBotUsage.toolID
        if isolated { profile.isolatedAgentHome = true }
        return profile
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("grok-usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sand-client-persistence"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func write(_ json: String, key: String, in folder: URL) throws {
        try Data(json.utf8).write(to: folder.appendingPathComponent("sand-client-persistence").appendingPathComponent(GrokBotUsage.fileName(key: key)))
    }

    private func usage(_ fields: String = #""percentUsed":12.5,"nextResetMs":1793696948091"#, schema: Int = 2, kind: String = "present", readAt: String = "1793098809613", expires: String = "1793185209614") -> String {
        #"{"schemaVersion":\#(schema),"value":{"kind":"\#(kind)","selectedTeamId":null,"reading":{"usage":{\#(fields),"isSandTrial":false,"hasNonZeroIncludedLimit":true,"unifiedPlanName":"Super"},"readAtMs":\#(readAt)},"expiresAtMs":\#(expires)}}"#
    }

    private func signIn(_ account: String, in folder: URL) throws {
        try write(#"{"schemaVersion":1,"value":"\#(account)"}"#, key: "sand.client.slice.client-meta.account-slot", in: folder)
    }

    func testFileNamesMatchGrokBotsBase32Keys() {
        // Taken from a real Grok Bot data folder; the key itself holds no account data.
        XCTAssertEqual(GrokBotUsage.fileName(key: "sand.client.slice.client-meta.account-slot"),
                       "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob")
        XCTAssertEqual(GrokBotUsage.fileName(key: "f"), "my.blob")
        XCTAssertEqual(GrokBotUsage.fileName(key: "foobar"), "mzxw6ytboi.blob")
    }

    func testSignedInAccountsWeeklyReadingBecomesOneWeekWindow() throws {
        let folder = try folder()
        try signIn(account, in: folder)
        try write(usage(), key: "sand.client.slice.account.grok%7Cuser_01FIXTURE.weekly-usage.cache", in: folder)
        let snapshot = try XCTUnwrap(GrokBotUsage.snapshot(in: folder, now: now))
        XCTAssertEqual(snapshot.identity, "grok-bot:" + account)
        XCTAssertEqual(snapshot.plan, "Super")
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSince1970: 1_793_098_809.613))
        let window = try XCTUnwrap(snapshot.windows.first)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(window.title, "Week")
        XCTAssertEqual(window.usedPercent, 12.5)
        XCTAssertEqual(window.remainingPercent, 87.5)
        XCTAssertEqual(window.resetsAt, Date(timeIntervalSince1970: 1_793_696_948.091))
        XCTAssertNil(snapshot.bankedResets, "Grok Bot has no saved resets; unknown, never zero")
    }

    func testOnlyTheSignedInAccountIsRead() throws {
        let folder = try folder()
        try write(usage(), key: "sand.client.slice.account.grok%7Cuser_01OTHER.weekly-usage.cache", in: folder)
        XCTAssertNil(GrokBotUsage.snapshot(in: folder, now: now), "No account slot")
        try signIn(account, in: folder)
        XCTAssertNil(GrokBotUsage.snapshot(in: folder, now: now), "Another account's cache never stands in")
    }

    func testUnrecognizedExpiredOrPastResetReadingsAreUnknown() {
        func reading(_ json: String) -> UsageSnapshot? {
            GrokBotUsage.parse((try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:], account: account, now: now)
        }
        XCTAssertNotNil(reading(usage()))
        XCTAssertNil(reading(usage(schema: 3)))
        XCTAssertNil(reading(usage(kind: "absent")))
        XCTAssertNil(reading(usage(#""percentUsed":-1,"nextResetMs":1793696948091"#)))
        XCTAssertNil(reading(usage(#""percentUsed":"12","nextResetMs":1793696948091"#)))
        XCTAssertNil(reading(usage(#""percentUsed":true,"nextResetMs":1793696948091"#)))
        XCTAssertNil(reading(usage(expires: "1793099000000")), "Past Grok Bot's own expiry")
        XCTAssertNil(reading(usage(#""percentUsed":12.5,"nextResetMs":1793099000000"#)), "From before the weekly reset")
        XCTAssertNil(reading(usage(readAt: "null")))
        // No reset time is still a reading, and values above the limit stay at 100%.
        XCTAssertNil(reading(usage(#""percentUsed":12.5,"nextResetMs":null"#))?.windows.first?.resetsAt)
        XCTAssertEqual(reading(usage(#""percentUsed":140,"nextResetMs":null"#))?.windows.first?.usedPercent, 100)
    }

    func testDataFolderIsTheSharedAppFolderOrTheSeparateAccountsOwn() {
        let home = URL(fileURLWithPath: "/Users/example")
        XCTAssertEqual(GrokBotUsage.dataDirectory(for: grokBot(), home: home)?.path, "/Users/example/Library/Application Support/Grok Bot")
        XCTAssertEqual(GrokBotUsage.dataDirectory(for: grokBot(isolated: true), home: home), grokBot(isolated: true).agentUserDataDirectory(in: home))
        var other = grokBot(); other.agentID = "grok"
        XCTAssertNil(GrokBotUsage.dataDirectory(for: other, home: home))
        var claude = Profile(id: "claude", name: "Claude", color: "C97B5D"); claude.provider = .claude
        XCTAssertNil(GrokBotUsage.dataDirectory(for: claude, home: home))
    }
}
