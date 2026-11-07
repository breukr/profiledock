import AppKit
import WebKit
import SwiftUI
import DockCore
import os

/// Web-usage diagnostics: outcome and HTTP status only, never cookies, tokens or response bodies.
let claudeWebLog = WebUsageLog()
/// Last web-usage outcome per connection, for the live diagnostics file (status words only).
enum ClaudeWebDiagnostics { nonisolated(unsafe) static var outcomes: [String: String] = [:] }
struct WebUsageLog {
    let logger = Logger(subsystem: "nl.breukr.account-dock", category: "claude-web-usage")
    func notice(_ message: String, key: String = "last") {
        logger.notice("\(message)")
        DispatchQueue.main.async { ClaudeWebDiagnostics.outcomes[key] = "\(Date()) \(message)" }
    }
}

/// A first-party sign-in in ProfileDock's own WebKit store. No browser cookies are imported.
/// The shared account keeps the default store; each separate Claude account gets its own persistent store.
@MainActor
final class ClaudeResetConnection: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = ClaudeResetConnection(configDirectory: nil)
    static let changed = Notification.Name("ProfileDock.ClaudeUsageConnectionChanged")
    /// userInfo key on `changed`; absent for the shared account.
    static let configDirectoryKey = "configDirectory"
    private static var accounts: [String: ClaudeResetConnection] = [:]
    static func connection(configDirectory: String?) -> ClaudeResetConnection {
        guard let configDirectory else { return shared }
        if let existing = accounts[configDirectory] { return existing }
        let created = ClaudeResetConnection(configDirectory: configDirectory)
        accounts[configDirectory] = created
        return created
    }

    let configDirectory: String?
    @Published private(set) var message = "Connect once to check saved resets automatically."
    @Published private(set) var enabled: Bool
    private let enabledKey: String
    private let dataStore: WKWebsiteDataStore
    private var webView: WKWebView?
    private var window: NSWindow?
    private var retryAfter = Date.distantPast
    private var revision = 0
    /// Set by `connect()`: the first finished claude.ai page after it (the user signed in) announces the change once.
    /// Routine page loads and the quiet keep-alive reloads never do.
    private var announcePending = false
    private var keepAlive: Timer?

    private init(configDirectory: String?) {
        self.configDirectory = configDirectory
        if let configDirectory {
            let identifier = ClaudeCredentialService.webDataStoreIdentifier(configDirectory: configDirectory)
            enabledKey = "ClaudeResetConnectionEnabled." + identifier.uuidString
            dataStore = WKWebsiteDataStore(forIdentifier: identifier)
        } else { enabledKey = "ClaudeResetConnectionEnabled"; dataStore = .default() }
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
        super.init()
    }

    private var claudeCode: String { configDirectory == nil ? "Claude Code" : "this profile's Claude Code" }

    func connect() {
        enabled = true; announcePending = true
        UserDefaults.standard.set(true, forKey: enabledKey)
        let web = prepareWebView()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = configDirectory == nil ? "Connect Claude saved resets" : "Connect saved resets for a separate Claude account"
            window.isReleasedWhenClosed = false
            window.contentView = web
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
        message = "Sign in to the same Claude account as \(claudeCode). This connection only reads usage."
    }

    func disconnect() {
        revision += 1; enabled = false; announcePending = false
        keepAlive?.invalidate(); keepAlive = nil
        UserDefaults.standard.set(false, forKey: enabledKey)
        window?.close(); window = nil
        webView?.stopLoading(); webView = nil
        message = "Disconnected. Saved reset tracking is off."
        // Remove this account's isolated web session, without touching Safari, Claude Desktop or other accounts.
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        postChanged()
    }

    private func postChanged() {
        NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: configDirectory.map { [Self.configDirectoryKey: $0] })
    }

    private func prepareWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        webView = web
        web.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
        scheduleKeepAlive()
        return web
    }

    /// About every 6 hours the hidden page reloads quietly so claude.ai keeps the web session fresh.
    /// Skipped while the connect window is on screen, so it never interrupts a sign-in.
    private func scheduleKeepAlive() {
        guard keepAlive == nil else { return }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, self.window?.isVisible != true, let web = self.webView, !web.isLoading else { return }
                web.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
            }
        }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard enabled, announcePending, webView.url?.host == "claude.ai", !(webView.url?.path.hasPrefix("/login") ?? true) else { return }
        announcePending = false
        postChanged()
    }

    /// Waits up to `limit` seconds for a page load in progress, so the first read after launch does not miss.
    private func settled(_ web: WKWebView, limit: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        while web.isLoading, Date() < deadline { try? await Task.sleep(for: .milliseconds(200)) }
        return !web.isLoading && web.url?.scheme == "https" && web.url?.host == "claude.ai"
    }

    /// Usage windows through this account's claude.ai sign-in. The organization comes from the web session itself,
    /// never from the OAuth token; with `expectedAccount` (the tile's Claude app account) a different account is refused.
    /// Cookie and token values never leave the web view: the page's own fetch sends them, Swift sees only JSON.
    func usage(expectedAccount: String?, knownIdentity: String?) async -> ClaudeWebUsage.Outcome {
        guard enabled else { claudeWebLog.notice("web usage: not connected"); return .notConnected }
        guard Date() >= retryAfter else { claudeWebLog.notice("web usage: paused after a rate limit"); return .rateLimited }
        let web = prepareWebView(), currentRevision = revision
        guard await settled(web), enabled, revision == currentRevision else { claudeWebLog.notice("web usage: page did not settle"); return .unavailable }
        guard let first = await run(Self.accountScript, arguments: [:], in: web) else { claudeWebLog.notice("web usage: account script failed"); return .unavailable }
        guard let status = first["status"] as? Int else { claudeWebLog.notice("web usage: account response without status"); return .unavailable }
        guard status == 200 else { claudeWebLog.notice("web usage: account status \(status)"); return outcome(status) }
        guard let account = ClaudeWebUsage.account(account: first["account"], organizations: first["organizations"]),
              let organization = ClaudeWebUsage.organization(for: account, knownIdentity: knownIdentity) else {
            claudeWebLog.notice("web usage: account or organization not recognized (account present: \(first["account"] != nil), organizations: \((first["organizations"] as? [Any])?.count ?? -1))")
            return .unavailable
        }
        if let expectedAccount, expectedAccount != account.accountID.lowercased() { claudeWebLog.notice("web usage: signed in to another account"); return .otherAccount }
        guard let second = await run(Self.usageScript, arguments: ["organization": organization], in: web),
              let usageStatus = second["status"] as? Int, enabled, revision == currentRevision else { claudeWebLog.notice("web usage: usage script failed"); return .unavailable }
        guard usageStatus == 200 else { claudeWebLog.notice("web usage: usage status \(usageStatus)"); return outcome(usageStatus) }
        guard let text = second["usage"] as? String, let data = text.data(using: .utf8) else { claudeWebLog.notice("web usage: empty usage body"); return .unavailable }
        let identity = ClaudeWebUsage.identity(accountID: account.accountID, organizationID: organization)
        guard let reading = try? ClaudeWebUsage.snapshot(usage: data, identity: identity, plan: nil, fetchedAt: Date()) else {
            let keys = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).map { $0.keys.sorted().joined(separator: ",") } ?? "not an object"
            claudeWebLog.notice("web usage: usage payload not recognized (keys: \(keys))")
            return .unavailable
        }
        claudeWebLog.notice("web usage: reading with \(reading.windows.count) windows")
        message = "Connected. Usage and saved resets refresh automatically, even when Claude Code's sign-in is stale."
        return .reading(reading)
    }

    private func outcome(_ status: Int) -> ClaudeWebUsage.Outcome {
        let value = ClaudeWebUsage.failure(status: status)
        switch value {
        case .rateLimited: retryAfter = Date().addingTimeInterval(300); message = "Claude requested a pause. Usage will retry automatically."
        case .signedOut: message = "The claude.ai sign-in ended. Reconnect to keep reading usage when Claude Code's sign-in is stale."
        default: break
        }
        return value
    }

    private func run(_ script: String, arguments: [String: Any], in web: WKWebView) async -> [String: Any]? {
        guard let result = try? await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .defaultClient),
              let text = result as? String, text.utf8.count <= 2_097_152, let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Shared JS helper: same-origin requests only, no redirects followed (a redirect means the session ended:
    /// `redirect: 'manual'` reports it as status 0), 8 s timeout, 1 MB limit.
    private static let readHelper = """
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    async function read(path, raw) {
      const response = await fetch(path, {credentials: 'same-origin', redirect: 'manual', cache: 'no-store', signal: controller.signal});
      if (response.type === 'opaqueredirect') return {status: 0};
      if (!response.ok) return {status: response.status};
      const text = await response.text();
      if (text.length > 1048576) return {status: 502};
      if (raw) return {status: 200, text};
      try { return {status: 200, value: JSON.parse(text)}; } catch { return {status: 502}; }
    }
    """
    private static let accountScript = readHelper + """
    try {
      const account = await read('/api/account');
      if (account.status !== 200) return JSON.stringify({status: account.status});
      const organizations = await read('/api/organizations');
      if (organizations.status !== 200) return JSON.stringify({status: organizations.status});
      const a = account.value || {};
      return JSON.stringify({status: 200, account: {uuid: a.uuid ?? a.account_uuid ?? a.account?.uuid ?? null},
        organizations: (Array.isArray(organizations.value) ? organizations.value : []).map(o => ({uuid: o.uuid, capabilities: o.capabilities}))});
    } finally { clearTimeout(timeout); }
    """
    private static let usageScript = readHelper + """
    try {
      const usage = await read('/api/organizations/' + encodeURIComponent(organization) + '/usage?cedar_ember=1&skip_spend=1', true);
      return JSON.stringify({status: usage.status, usage: usage.text ?? null});
    } finally { clearTimeout(timeout); }
    """

    func inventory(for account: ClaudeUsageAccount) async throws -> ClaudeUsageParser.ResetInventory? {
        guard enabled, Date() >= retryAfter else { return nil }
        let web = prepareWebView(), currentRevision = revision
        guard !web.isLoading, web.url?.scheme == "https", web.url?.host == "claude.ai" else { return nil }
        // Requests run on the first-party origin and use only this web view's sign-in.
        // The organization must match the identity verified through this account's Claude Code OAuth.
        let script = """
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 8000);
        async function read(path) {
          const response = await fetch(path, {credentials: 'same-origin', redirect: 'error', cache: 'no-store', signal: controller.signal});
          if (!response.ok) return {status: response.status};
          const text = await response.text();
          if (text.length > 1048576) return {status: 502};
          try { return {status: 200, value: JSON.parse(text)}; } catch { return {status: 502}; }
        }
        try {
          const organizations = await read('/api/organizations');
          if (organizations.status !== 200) return JSON.stringify(organizations);
          if (!Array.isArray(organizations.value) || !organizations.value.some(o => o.uuid === organization)) return JSON.stringify({status: 409});
          const usage = await read('/api/organizations/' + encodeURIComponent(organization) + '/usage?cedar_ember=1&skip_spend=1');
          return JSON.stringify({status: usage.status, inventory: usage.value?.cedar_ember ?? null});
        } finally { clearTimeout(timeout); }
        """
        do {
            let result = try await web.callAsyncJavaScript(script, arguments: ["organization": account.organizationID], in: nil, contentWorld: .defaultClient)
            guard enabled, revision == currentRevision else { return nil }
            guard let text = result as? String, let data = text.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let status = value["status"] as? Int else { throw UsageLoadError.invalidResponse }
            if status == 429 { retryAfter = Date().addingTimeInterval(300); message = "Claude requested a pause. Saved resets will retry automatically."; return nil }
            if status == 409 { message = "Use the same Claude account as \(claudeCode) to track its saved resets."; return nil }
            guard status == 200 else { message = "Reconnect Claude to refresh saved resets."; return nil }
            let inventory = ClaudeUsageParser.resets(value["inventory"], now: Date())
            message = inventory == nil ? "Claude has not exposed saved resets for this connection. Your balance is unknown." : "Connected. Saved resets refresh automatically with account usage."
            return inventory
        } catch {
            message = "Saved resets could not be refreshed. ProfileDock will retry automatically."
            return nil
        }
    }
}

struct ClaudeAccountConnectionView: View {
    @ObservedObject private var connection = ClaudeResetConnection.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude usage connector", systemImage: "chart.bar").font(.headline)
            Text("Account usage and reset times refresh automatically from your Claude Code sign-in, every minute while the strip is open and every five minutes in the background. If sign-in expires, ProfileDock nudges you with a Reconnect link. Claude tiles share that account; a separate Claude account reads its own Claude Code sign-in and connects its saved resets from its own tile.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Saved resets need a separate Claude web sign-in. ProfileDock only reads your balance and expiry dates; it never uses a reset.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(connection.enabled ? "Reconnect saved resets…" : "Connect saved resets…") { connection.connect() }
                if connection.enabled { Button("Disconnect") { connection.disconnect() } }
            }
            Text(connection.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
