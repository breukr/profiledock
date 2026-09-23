import AppKit
import WebKit
import SwiftUI
import DockCore

/// A first-party sign-in in ProfileDock's own WebKit store. No browser cookies are imported.
@MainActor
final class ClaudeResetConnection: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = ClaudeResetConnection()
    static let changed = Notification.Name("ProfileDock.ClaudeUsageConnectionChanged")
    @Published private(set) var message = "Connect once to check saved resets automatically."
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "ClaudeResetConnectionEnabled")
    private var webView: WKWebView?
    private var window: NSWindow?
    private var retryAfter = Date.distantPast
    private var revision = 0

    func connect() {
        enabled = true
        UserDefaults.standard.set(true, forKey: "ClaudeResetConnectionEnabled")
        let web = prepareWebView()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Connect Claude saved resets"
            window.isReleasedWhenClosed = false
            window.contentView = web
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
        message = "Sign in to the same Claude account as Claude Code. This connection only reads usage."
    }

    func disconnect() {
        revision += 1; enabled = false
        UserDefaults.standard.set(false, forKey: "ClaudeResetConnectionEnabled")
        window?.close(); window = nil
        webView?.stopLoading(); webView = nil
        message = "Disconnected. Saved reset tracking is off."
        // Remove this app's isolated web session, without touching Safari or Claude Desktop.
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func prepareWebView() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        webView = web
        web.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard enabled, webView.url?.host == "claude.ai" else { return }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func inventory(for account: ClaudeUsageAccount) async throws -> ClaudeUsageParser.ResetInventory? {
        guard enabled, Date() >= retryAfter else { return nil }
        let web = prepareWebView(), currentRevision = revision
        guard !web.isLoading, web.url?.scheme == "https", web.url?.host == "claude.ai" else { return nil }
        // Requests run on the first-party origin and use only this web view's sign-in.
        // The organization must match the identity verified through Claude Code OAuth.
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
            if status == 409 { message = "Use the same Claude account as Claude Code to track its saved resets."; return nil }
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
            Text("Account usage and reset times refresh automatically from your Claude Code sign-in, every minute while the strip is open and every five minutes in the background. All Claude tiles share that account.")
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
