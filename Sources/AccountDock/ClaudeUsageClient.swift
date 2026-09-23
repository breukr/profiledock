import Foundation
import CryptoKit
import DockCore

struct ClaudeUsageCredential: Sendable {
    let token: String
    let fingerprint: String
    let plan: String?

    static func parse(_ data: Data, now: Date = Date()) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty,
              token.rangeOfCharacter(from: .controlCharacters) == nil,
              let expires = oauth["expiresAt"] as? Double, expires.isFinite, expires / 1000 > now.timeIntervalSince1970,
              let scopes = oauth["scopes"] as? [String], scopes.contains("user:profile") else { throw UsageLoadError.claudeSignInRequired }
        return Self(token: token, fingerprint: digest(token), plan: oauth["subscriptionType"] as? String)
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func read() throws -> Self {
        // Use the same narrowly scoped Keychain reader as Claude Code; never log or persist its output.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readData(ofLength: 65537)
        if data.count > 65536, process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 65536 else { throw UsageLoadError.claudeSignInRequired }
        return try parse(data)
    }
}

struct ClaudeUsageAccount: Sendable {
    let identity: String
    let organizationID: String
    let accountID: String
    static func parse(_ data: Data) throws -> Self {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["account"] as? [String: Any], let accountID = account["uuid"] as? String, UUID(uuidString: accountID) != nil,
              let organization = root["organization"] as? [String: Any], let organizationID = organization["uuid"] as? String, UUID(uuidString: organizationID) != nil else { throw UsageLoadError.invalidResponse }
        return Self(identity: ClaudeUsageCredential.digest("claude\n\(accountID)\n\(organizationID)"), organizationID: organizationID, accountID: accountID)
    }
}

actor ClaudeUsageClient: UsageFetching {
    typealias Credentials = @Sendable () throws -> ClaudeUsageCredential
    typealias ResetFetcher = @Sendable (ClaudeUsageAccount) async throws -> ClaudeUsageParser.ResetInventory?
    private let resetFetcher: ResetFetcher
    private let credentials: Credentials
    private let session: URLSession
    private let clock: @Sendable () -> Date
    private var accountCache: (fingerprint: String, account: ClaudeUsageAccount)?
    private var accountTask: (fingerprint: String, task: Task<ClaudeUsageAccount, Error>)?
    private var snapshot: UsageSnapshot?
    private var pending: (identity: String, id: UUID, task: Task<UsageSnapshot, Error>)?
    private var retryAfter: Date?

    init(session: URLSession? = nil, credentials: @escaping Credentials = { try ClaudeUsageCredential.read() }, clock: @escaping @Sendable () -> Date = { Date() }, resetFetcher: @escaping ResetFetcher = { try await ClaudeResetConnection.shared.inventory(for: $0) }) {
        self.credentials = credentials; self.clock = clock; self.resetFetcher = resetFetcher
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: config, delegate: NoUsageRedirects(), delegateQueue: nil)
        }
    }

    func invalidate() async {
        snapshot = nil
        pending?.task.cancel(); pending = nil
    }

    func identity(for profile: Profile) async throws -> String {
        let credential = try credentials()
        return try await account(for: credential).identity
    }

    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot {
        let credential = try credentials(), account = try await account(for: credential)
        guard account.identity == expectedIdentity else { throw UsageLoadError.accountChanged }
        if let retryAfter, retryAfter > clock() { throw UsageLoadError.rateLimited(retryAfter) }
        // Shared Desktop/project tiles coalesce onto one account request, including manual refresh.
        if let snapshot, snapshot.identity == expectedIdentity, clock().timeIntervalSince(snapshot.fetchedAt) < 15 { return snapshot }
        if let pending, pending.identity == expectedIdentity { return try await pending.task.value }
        let id = UUID()
        let task = Task { try await self.load(credential: credential, account: account) }
        pending = (expectedIdentity, id, task)
        defer { if pending?.id == id { pending = nil } }
        let value = try await task.value
        try Task.checkCancellation()
        snapshot = value; return value
    }

    private func account(for credential: ClaudeUsageCredential) async throws -> ClaudeUsageAccount {
        if let accountCache, accountCache.fingerprint == credential.fingerprint { return accountCache.account }
        if let accountTask, accountTask.fingerprint == credential.fingerprint { return try await accountTask.task.value }
        let task = Task { try ClaudeUsageAccount.parse(await self.request(path: "/api/oauth/profile", credential: credential)) }
        accountTask = (credential.fingerprint, task)
        defer { if accountTask?.fingerprint == credential.fingerprint { accountTask = nil } }
        let value = try await task.value
        guard try credentials().fingerprint == credential.fingerprint else { throw UsageLoadError.accountChanged }
        if accountCache?.account.identity != value.identity { snapshot = nil; retryAfter = nil }
        accountCache = (credential.fingerprint, value)
        return value
    }

    private func load(credential: ClaudeUsageCredential, account: ClaudeUsageAccount) async throws -> UsageSnapshot {
        let data = try await request(path: "/api/oauth/usage?cedar_ember=1&skip_spend=1", credential: credential)
        guard try credentials().fingerprint == credential.fingerprint else { throw UsageLoadError.accountChanged }
        let parsed: UsageSnapshot
        do { parsed = try ClaudeUsageParser.parse(data, identity: account.identity, plan: credential.plan, fetchedAt: clock()) }
        catch { throw UsageLoadError.invalidResponse }
        let inventory = parsed.bankedResets == nil ? try? await resetFetcher(account) : nil
        guard try credentials().fingerprint == credential.fingerprint else { throw UsageLoadError.accountChanged }
        try Task.checkCancellation()
        guard let inventory else { return parsed }
        return UsageSnapshot(identity: parsed.identity, plan: parsed.plan, windows: parsed.windows,
                             bankedResets: inventory.count, applicableResets: inventory.usable, resetExpiries: inventory.expiries,
                             fetchedAt: parsed.fetchedAt, hasUnparsedWindows: parsed.hasUnparsedWindows)
    }

    private func request(path: String, credential: ClaudeUsageCredential) async throws -> Data {
        if let retryAfter, retryAfter > clock() { throw UsageLoadError.rateLimited(retryAfter) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer " + credential.token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw UsageLoadError.network }
        guard let http = response as? HTTPURLResponse else { throw UsageLoadError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageLoadError.claudeSignInRequired }
        if http.statusCode == 429 {
            let delay = max(300, min(3600, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300))
            let until = clock().addingTimeInterval(delay); retryAfter = until
            throw UsageLoadError.rateLimited(until)
        }
        guard http.statusCode == 200 else { throw UsageLoadError.http(http.statusCode) }
        guard data.count <= 1_048_576 else { throw UsageLoadError.invalidResponse }
        return data
    }
}

extension Profile {
    var usesClaudeAccountUsage: Bool { kind == .claude || kind == .claudeCode || (kind == .terminal && terminalAgent == .claude) }
}
