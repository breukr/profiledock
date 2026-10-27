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
              let scopes = oauth["scopes"] as? [String], scopes.contains("user:profile"),
              let expires = oauth["expiresAt"] as? Double, expires.isFinite else { throw UsageLoadError.claudeSignInRequired }
        // Claude Code renews an expired access token itself the next time it runs (the Desktop Code tab does not).
        // Only the refresh token's presence is checked; ProfileDock never uses or rotates it.
        guard expires / 1000 > now.timeIntervalSince1970 else {
            let renewable = (oauth["refreshToken"] as? String).map { !$0.isEmpty } ?? false
            throw renewable ? UsageLoadError.claudeTokenStale : UsageLoadError.claudeSignInRequired
        }
        return Self(token: token, fingerprint: digest(token), plan: oauth["subscriptionType"] as? String)
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// Reads the credential Claude Code keeps for `configDirectory` (nil: the shared ~/.claude sign-in).
    /// A separate account falls back to Claude Code's documented `<config>/.credentials.json` file.
    /// Claude Code keeps MCP server logins in the same item, so for a separate account an item without
    /// a Claude login means usage was never connected, not that a sign-in failed.
    static func read(configDirectory: String? = nil, keychain: (String) throws -> Data? = keychainItem) throws -> Self {
        let item = try keychain(ClaudeCredentialService.name(configDirectory: configDirectory))
        guard let configDirectory else {
            guard let item else { throw UsageLoadError.claudeSignInRequired }
            return try parse(item)
        }
        if let item, hasClaudeLogin(item) { return try parse(item) }
        let file = URL(fileURLWithPath: configDirectory).appendingPathComponent(".credentials.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536,
              let data = try? Data(contentsOf: file), hasClaudeLogin(data) else { throw UsageLoadError.claudeConnectionNeeded }
        return try parse(data)
    }

    private static func hasClaudeLogin(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["claudeAiOauth"] is [String: Any]
    }

    /// Use the same narrowly scoped Keychain reader as Claude Code; never log or persist its output. Nil when absent or unreadable.
    static func keychainItem(service: String) throws -> Data? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", NSUserName(), "-s", service, "-w"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readData(ofLength: 65537)
        if data.count > 65536, process.isRunning { process.terminate() }
        process.waitUntilExit()
        return process.terminationStatus == 0 && data.count <= 65536 ? data : nil
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
    /// The account a tile's own Claude app is signed in to, or nil when the tile has no app of its own to compare with.
    typealias ExpectedAccount = @Sendable (Profile) -> String?
    static let desktopAccount: ExpectedAccount = { ClaudeDesktopAccount.accountID(for: $0, home: FileManager.default.homeDirectoryForCurrentUser) }
    private let resetFetcher: ResetFetcher
    private let credentials: Credentials
    private let expectedAccount: ExpectedAccount?
    private let session: URLSession
    private let clock: @Sendable () -> Date
    private var accountCache: (fingerprint: String, account: ClaudeUsageAccount)?
    private var accountTask: (fingerprint: String, task: Task<ClaudeUsageAccount, Error>)?
    private var snapshot: UsageSnapshot?
    private var pending: (identity: String, id: UUID, task: Task<UsageSnapshot, Error>)?
    private var retryAfter: Date?

    /// One client per Claude Code configuration: nil is the shared ~/.claude sign-in, otherwise a separate account's CLAUDE_CONFIG_DIR.
    init(configDirectory: String? = nil, session: URLSession? = nil, credentials: Credentials? = nil, clock: @escaping @Sendable () -> Date = { Date() }, resetFetcher: ResetFetcher? = nil, expectedAccount: ExpectedAccount? = nil) {
        self.credentials = credentials ?? { try ClaudeUsageCredential.read(configDirectory: configDirectory) }
        self.resetFetcher = resetFetcher ?? { try await ClaudeResetConnection.connection(configDirectory: configDirectory).inventory(for: $0) }
        self.expectedAccount = expectedAccount
        self.clock = clock
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
        let account = try await account(for: credential)
        guard try credentials().fingerprint == credential.fingerprint else { throw UsageLoadError.accountChanged }
        try verify(account, for: profile)
        return account.identity
    }

    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot {
        let credential = try credentials(), account = try await account(for: credential)
        guard try credentials().fingerprint == credential.fingerprint else { throw UsageLoadError.accountChanged }
        try verify(account, for: profile)
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

    /// A Claude app tile shows only its own account's usage. Claude Code's sign-in can belong to another account,
    /// for example after `claude auth login` in a browser that was signed in to claude.ai as someone else.
    private func verify(_ account: ClaudeUsageAccount, for profile: Profile) throws {
        guard let expected = expectedAccount?(profile), expected != account.accountID.lowercased() else { return }
        throw UsageLoadError.claudeOtherAccount
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
    /// Separate Claude accounts read their own CLAUDE_CONFIG_DIR sign-in; all other Claude tiles share ~/.claude.
    var usesClaudeAccountUsage: Bool { kind == .claude || kind == .claudeCode || (kind == .terminal && terminalAgent == .claude) }
}
