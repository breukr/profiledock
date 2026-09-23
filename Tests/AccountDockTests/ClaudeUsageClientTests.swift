import XCTest
import DockCore
@testable import AccountDock

private final class ClaudeResponseProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data, [String: String]))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data, headers) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ClaudeUsageCredential
    init(_ value: ClaudeUsageCredential) { self.value = value }
    func read() -> ClaudeUsageCredential { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: ClaudeUsageCredential) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

final class ClaudeUsageClientTests: XCTestCase {
    let profile = { var p = Profile(id: "claude", name: "Claude", color: "377CF6"); p.provider = .claude; return p }()
    let account = Data(#"{"account":{"uuid":"11111111-1111-1111-1111-111111111111"},"organization":{"uuid":"22222222-2222-2222-2222-222222222222"}}"#.utf8)
    let usage = Data(#"{"five_hour":{"utilization":35,"resets_at":"2027-01-01T00:00:00Z"}}"#.utf8)
    func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ClaudeResponseProtocol.self]
        return URLSession(configuration: config)
    }
    func credential(_ token: String = "fixture") -> ClaudeUsageCredential { .init(token: token, fingerprint: token, plan: "max") }

    func testCredentialRequiresLiveSubscriptionSignInAndProfileScope() throws {
        let valid = Data(#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000,"scopes":["user:profile"],"subscriptionType":"max"}}"#.utf8)
        XCTAssertEqual(try ClaudeUsageCredential.parse(valid).plan, "max")
        XCTAssertThrowsError(try ClaudeUsageCredential.parse(valid, now: Date(timeIntervalSince1970: 4102444801)))
        XCTAssertThrowsError(try ClaudeUsageCredential.parse(Data(#"{"apiKey":"fixture"}"#.utf8)))
    }

    func testMultipleTilesShareAccountRequestAndUnknownResetBalanceStaysUnknown() async throws {
        var requests: [String] = []
        let account = account, usage = usage, credential = credential()
        ClaudeResponseProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "api.anthropic.com")
            let path = request.url!.path; requests.append(path)
            return (200, path.hasSuffix("profile") ? account : usage, [:])
        }
        let client = ClaudeUsageClient(session: session(), credentials: { credential }, resetFetcher: { _ in nil })
        let identity = try await client.identity(for: profile)
        async let a = client.fetch(profile, expectedIdentity: identity)
        async let b = client.fetch(profile, expectedIdentity: identity)
        let (first, second) = try await (a, b)
        XCTAssertEqual(first, second)
        XCTAssertEqual(requests.filter { $0.hasSuffix("usage") }.count, 1)
        XCTAssertNil(first.bankedResets)
        do { _ = try await client.fetch(profile, expectedIdentity: "another-account"); XCTFail("Must reject identity mismatch") }
        catch { XCTAssertEqual(error as? UsageLoadError, .accountChanged) }
    }

    func testRateLimitPausesAutomaticAndManualRetries() async throws {
        var usageRequests = 0
        let account = account, credential = credential()
        ClaudeResponseProtocol.handler = { request in
            if request.url!.path.hasSuffix("profile") { return (200, account, [:]) }
            usageRequests += 1; return (429, Data(), ["Retry-After": "600"])
        }
        let client = ClaudeUsageClient(session: session(), credentials: { credential }, resetFetcher: { _ in nil })
        let identity = try await client.identity(for: profile)
        for _ in 0..<3 {
            do { _ = try await client.fetch(profile, expectedIdentity: identity); XCTFail("Must respect rate limiting") }
            catch { guard case .rateLimited = error as? UsageLoadError else { return XCTFail("Wrong failure") } }
        }
        XCTAssertEqual(usageRequests, 1)
    }

    func testAccountSwitchDuringRequestDiscardsResponse() async throws {
        let account = account, usage = usage, box = CredentialBox(credential()), next = credential("new-account")
        ClaudeResponseProtocol.handler = { request in
            if request.url!.path.hasSuffix("profile") { return (200, account, [:]) }
            box.set(next)
            return (200, usage, [:])
        }
        let client = ClaudeUsageClient(session: session(), credentials: { box.read() }, resetFetcher: { _ in nil })
        let identity = try await client.identity(for: profile)
        do { _ = try await client.fetch(profile, expectedIdentity: identity); XCTFail("Must discard previous account response") }
        catch { XCTAssertEqual(error as? UsageLoadError, .accountChanged) }
    }

    func testSavedResetEnrichmentAndDisconnectInvalidatesCachedBalance() async throws {
        let account = account, usage = usage, credential = credential()
        let connected = CredentialBox(credential)
        ClaudeResponseProtocol.handler = { request in (200, request.url!.path.hasSuffix("profile") ? account : usage, [:]) }
        let client = ClaudeUsageClient(session: session(), credentials: { credential }, resetFetcher: { account in
            XCTAssertEqual(account.organizationID, "22222222-2222-2222-2222-222222222222")
            guard connected.read().token != "disconnected" else { return nil }
            return ClaudeUsageParser.resets(["eligible": true, "grants": [["id": "fixture", "resets_left": 1, "usable_now": false]]], now: Date())
        })
        let identity = try await client.identity(for: profile)
        let first = try await client.fetch(profile, expectedIdentity: identity)
        XCTAssertEqual(first.bankedResets, 1)
        XCTAssertEqual(first.applicableResets, 0)
        connected.set(self.credential("disconnected"))
        await client.invalidate()
        let second = try await client.fetch(profile, expectedIdentity: identity)
        XCTAssertNil(second.bankedResets)
        XCTAssertEqual(second.windows, first.windows)
    }
}
