import XCTest
import DockCore
@testable import AccountDock

@MainActor
final class AttentionCenterTests: XCTestCase {
    private func item(_ id: String, session: String = "s1", kind: AttentionKind, at seconds: Double, decides: Bool = false) -> AgentAttention {
        AgentAttention(id: id, source: "claude", sessionID: session, kind: kind, title: kind.rawValue, message: "",
                       receivedAt: Date(timeIntervalSince1970: seconds), deadline: decides ? Date(timeIntervalSince1970: seconds + 90) : nil)
    }

    func testRequestsThatHoldAnAgentComeFirstOldestFirst() {
        let center = AttentionCenter()
        center.post(item("done", session: "a", kind: .finished, at: 1))
        center.post(item("wait", session: "b", kind: .waiting, at: 2))
        center.post(item("perm-new", session: "c", kind: .permission, at: 5, decides: true))
        center.post(item("perm-old", session: "d", kind: .permission, at: 3, decides: true))
        XCTAssertEqual(center.items.map(\.id), ["perm-old", "perm-new", "wait", "done"])
        XCTAssertEqual(center.needsDecisionCount, 2)
    }

    func testANewItemReplacesAnUnanswerableOneFromTheSameSessionButNeverADecision() {
        let center = AttentionCenter()
        center.post(item("done-1", kind: .finished, at: 1))
        center.post(item("done-2", kind: .finished, at: 2))
        XCTAssertEqual(center.items.map(\.id), ["done-2"])
        center.post(item("perm", kind: .permission, at: 3, decides: true))
        center.post(item("done-3", kind: .finished, at: 4))
        XCTAssertEqual(Set(center.items.map(\.id)), ["perm", "done-3"])
    }

    func testADecisionIsDeliveredOnceAndOnlyForRequestsThatWait() {
        let center = AttentionCenter()
        var delivered: [(String, AttentionDecision)] = []
        center.onDecision = { delivered.append(($0, $1)) }
        center.post(item("perm", kind: .permission, at: 1, decides: true))
        center.post(item("done", session: "other", kind: .finished, at: 2))
        center.respond("perm", .allow)
        center.respond("perm", .deny(message: nil))
        center.dismiss("done")
        XCTAssertEqual(delivered.map(\.0), ["perm"])
        XCTAssertEqual(delivered.first?.1, .allow)
        XCTAssertTrue(center.items.isEmpty)
        // An answered id posted again (for example a retried frame) is ignored.
        center.post(item("perm", kind: .permission, at: 3, decides: true))
        XCTAssertTrue(center.items.isEmpty)
    }

    func testExpiredAndClearedRequestsLeaveTheQueue() {
        let center = AttentionCenter()
        var delivered: [AttentionDecision] = []
        center.onDecision = { delivered.append($1) }
        center.post(item("a", session: "x", kind: .permission, at: 1, decides: true))
        center.post(item("b", session: "y", kind: .question, at: 2, decides: true))
        center.expire("a")
        XCTAssertEqual(center.items.map(\.id), ["b"])
        XCTAssertTrue(delivered.isEmpty, "The hook already gave up; nothing is sent")
        center.clear(source: "claude", sessionID: "y")
        XCTAssertTrue(center.items.isEmpty)
        XCTAssertEqual(delivered, [.passThrough], "A cleared request releases the waiting hook so the agent's own dialog shows")
    }

    func testTextIsCleanedAndTruncated() {
        let long = String(repeating: "a", count: 600)
        let value = AgentAttention(source: "claude", sessionID: "s", kind: .finished, title: "Done\u{0007}", message: "\u{001B}[31m" + long, preview: "rm -rf build\n\n\n\nok")
        XCTAssertEqual(value.title, "Done")
        XCTAssertEqual(value.message.count, 500)
        XCTAssertTrue(value.message.hasSuffix("…"))
        XCTAssertFalse(value.message.unicodeScalars.contains { $0.value == 0x1B })
        XCTAssertEqual(value.preview, "rm -rf build\n\nok")
        XCTAssertNil(value.projectName)
        XCTAssertEqual(AgentAttention(source: "claude", sessionID: "s", kind: .waiting, title: "", message: "", cwd: "/Users/me/Code/Atlas").projectName, "Atlas")
    }
}
