import AppKit
import WebKit
import SwiftUI
import DockCore

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
        enabled = true
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
        revision += 1; enabled = false
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
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard enabled, webView.url?.host == "claude.ai" else { return }
        postChanged()
    }

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
