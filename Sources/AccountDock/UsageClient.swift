import Foundation
import CryptoKit
import DockCore

enum UsageLoadError: Error, Equatable {
    case notSignedIn, authorizationRequired, accountChanged, wrongAccount, invalidResponse, network, http(Int)
    var message: String {
        switch self {
        case .notSignedIn, .authorizationRequired: return "Open this profile and check that you are signed in."
        case .accountChanged: return "Account changed. Refresh usage again."
        case .wrongAccount: return "The response belongs to a different account."
        case .invalidResponse: return "Usage data could not be read."
        case .network: return "No connection. Try again."
        case .http: return "Usage data is temporarily unavailable."
        }
    }
    var clearsSnapshot: Bool {
        switch self {
        case .notSignedIn, .authorizationRequired, .accountChanged, .wrongAccount: return true
        default: return false
        }
    }
}

protocol UsageFetching: Sendable {
    func identity(for profile: Profile) async throws -> String
    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot
}

struct UsageCredentials: Sendable {
    let accessToken: String
    let accountID: String
    let identity: String

    static func read(profile: Profile, home: URL) throws -> UsageCredentials {
        guard Profile.validID(profile.id) else { throw UsageLoadError.notSignedIn }
        let file = profile.home(in: home).appendingPathComponent("auth.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: file) else { throw UsageLoadError.notSignedIn }
        return try parse(data: data, source: file)
    }

    static func parse(data: Data, source: URL) throws -> UsageCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["auth_mode"] as? String == "chatgpt",
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty,
              token.rangeOfCharacter(from: .controlCharacters) == nil,
              account.rangeOfCharacter(from: .controlCharacters) == nil else { throw UsageLoadError.notSignedIn }
        let claims = [tokens["id_token"] as? String, token].compactMap { $0 }.compactMap(jwtClaims)
        guard let subject = claims.compactMap({ $0["sub"] as? String }).first(where: { !$0.isEmpty }) else { throw UsageLoadError.notSignedIn }
        let key = source.standardizedFileURL.path + "\n" + account + "\n" + subject
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return UsageCredentials(accessToken: token, accountID: account, identity: digest)
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A credential-bearing request never follows a redirect to any other location.
        completionHandler(nil)
    }
}

actor UsageClient: UsageFetching {
    private let home: URL
    private let session: URLSession
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, session: URLSession? = nil) {
        self.home = home
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.httpMaximumConnectionsPerHost = 3
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 12
            self.session = URLSession(configuration: config, delegate: NoUsageRedirects(), delegateQueue: nil)
        }
    }

    func identity(for profile: Profile) async throws -> String { try UsageCredentials.read(profile: profile, home: home).identity }

    func fetch(_ profile: Profile, expectedIdentity: String) async throws -> UsageSnapshot {
        let credential = try UsageCredentials.read(profile: profile, home: home)
        guard credential.identity == expectedIdentity else { throw UsageLoadError.accountChanged }
        async let usage = request(path: "usage", credential: credential, timeout: 10)
        async let inventory = optionalInventory(credential)
        let data = try await usage
        let resetData = await inventory
        try Task.checkCancellation()
        // Signing into a different account while a request is in flight must invalidate that response.
        let current = try UsageCredentials.read(profile: profile, home: home)
        guard current.identity == credential.identity else { throw UsageLoadError.accountChanged }
        do {
            return try UsageParser.parse(usage: data, resets: resetData, expectedAccount: credential.accountID, identity: credential.identity, fetchedAt: Date())
        } catch UsageParseError.wrongAccount { throw UsageLoadError.wrongAccount }
        catch { throw UsageLoadError.invalidResponse }
    }

    private func optionalInventory(_ credential: UsageCredentials) async -> Data? {
        try? await request(path: "rate-limit-reset-credits", credential: credential, timeout: 4)
    }

    private func request(path: String, credential: UsageCredentials, timeout: TimeInterval) async throws -> Data {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/\(path)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AccountDock/1.3", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw UsageLoadError.network }
        guard let http = response as? HTTPURLResponse else { throw UsageLoadError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageLoadError.authorizationRequired }
        guard http.statusCode == 200 else { throw UsageLoadError.http(http.statusCode) }
        guard data.count <= 1_048_576 else { throw UsageLoadError.invalidResponse }
        return data
    }
}
