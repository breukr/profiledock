import Foundation
import DockCore

struct AccountSignInCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]

    static let basePath = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

    static func make(profile: Profile, home: URL, executableExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:), shellLookup: () -> ShellTools = loginShellTools) throws -> Self {
        guard Profile.validID(profile.id), profile.kind == .codex || profile.usesClaudeAccountUsage else { throw AccountSignInError.unsupported }
        var searchPath = [String]()
        let path: String
        if profile.usesClaudeAccountUsage {
            if let found = claudeCandidates(home: home).first(where: executableExists) { path = found }
            else {
                // Last resort: ask the user's login shell (it knows PATH entries from ~/.zprofile, nvm, volta, ...).
                let tools = shellLookup()
                guard let found = tools.claude, executableExists(found) else { throw AccountSignInError.missingCLI(claude: true) }
                path = found
                if let node = tools.node, executableExists(node) { searchPath.append((node as NSString).deletingLastPathComponent) }
            }
            // An npm-installed claude is a Node script (`#!/usr/bin/env node`): its own folder usually holds node too.
            searchPath.insert((path as NSString).deletingLastPathComponent, at: 0)
        } else {
            let candidates = [profile.applicationPath.map { $0 + "/Contents/Resources/codex" }, "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].compactMap { $0 }
            guard let found = candidates.first(where: executableExists) else { throw AccountSignInError.missingCLI(claude: false) }
            path = found
        }
        // Use a clean environment so another running profile cannot supply authentication overrides.
        let fullPath = (searchPath.filter { !$0.isEmpty && !basePath.split(separator: ":").contains(Substring($0)) } + [basePath]).joined(separator: ":")
        var environment = ["HOME": home.path, "USER": NSUserName(), "PATH": fullPath, "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        if !profile.usesClaudeAccountUsage { environment["CODEX_HOME"] = profile.home(in: home).path }
        // A separate Claude account signs in to its own configuration, the same CLAUDE_CONFIG_DIR its app launches with.
        if let config = profile.claudeConfigPath(in: home) { environment["CLAUDE_CONFIG_DIR"] = config }
        var arguments = profile.usesClaudeAccountUsage ? ["auth", "login", "--claudeai"] : ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        // Pre-fill the Claude app's own account, so a browser signed in to claude.ai as someone else is not used silently.
        if let account = ClaudeDesktopAccount.accountID(for: profile, home: home),
           let email = ClaudeDesktopAccount.email(for: profile, accountID: account, home: home) { arguments.append("--email=" + email) }
        return Self(executable: URL(fileURLWithPath: path), arguments: arguments, environment: environment)
    }
}

extension AccountSignInCommand {
    struct ShellTools: Equatable, Sendable { var claude: String?; var node: String? }

    /// Fixed install locations first (native installer, Homebrew, npm global, nvm, volta, bun), then the copy
    /// Claude Desktop downloads for its Code tab. Newest versions first.
    static func claudeCandidates(home: URL, fileManager: FileManager = .default) -> [String] {
        func newestFirst(_ folder: URL) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
                .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let desktop = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        let desktopCopies = newestFirst(desktop).flatMap { version in
            newestFirst(desktop.appendingPathComponent(version)).map { desktop.appendingPathComponent("\(version)/\($0)/claude.app/Contents/MacOS/claude").path }
        }
        return [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                home.appendingPathComponent(".npm-global/bin/claude").path, home.appendingPathComponent(".claude/local/claude").path]
            + newestFirst(nvm).map { nvm.appendingPathComponent("\($0)/bin/claude").path }
            + [home.appendingPathComponent(".volta/bin/claude").path, home.appendingPathComponent(".bun/bin/claude").path]
            + desktopCopies
    }

    /// `zsh -lc 'command -v claude; command -v node'` with a 3 second limit. Only absolute paths are accepted;
    /// the output is never logged.
    static func loginShellTools() -> ShellTools {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v claude; command -v node"]
        process.environment = ["HOME": NSHomeDirectory(), "USER": NSUserName(), "PATH": basePath, "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ShellTools() }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readData(ofLength: 8192)
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
        return ShellTools(claude: lines.first { $0.hasSuffix("/claude") }, node: lines.first { $0.hasSuffix("/node") })
    }
}

enum AccountSignInError: Error {
    case unsupported, missingCLI(claude: Bool), failed, timedOut
    var message: String {
        switch self {
        case .unsupported: return "This connection does not support account sign-in."
        case .missingCLI(let claude): return claude ? "Install Claude Code to reconnect account usage." : "Install Codex or the ChatGPT desktop app to reconnect this profile."
        case .failed: return "Sign-in did not finish. Close any other login flow, then reconnect again."
        case .timedOut: return "Sign-in timed out. Reconnect to open a new sign-in page."
        }
    }
}

protocol AccountSigningIn: Sendable {
    func signIn(_ command: AccountSignInCommand) async throws
}

struct AccountSignInRunner: AccountSigningIn {
    var timeout: TimeInterval = 600
    func signIn(_ command: AccountSignInCommand) async throws {
        let execution = SignInExecution(command: command, timeout: timeout)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in execution.start(continuation) }
        } onCancel: { execution.cancel() }
    }
}

/// Own only the login subprocess. Never log its output, URLs, codes or credentials.
private final class SignInExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let input = Pipe()
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var timeoutWork: DispatchWorkItem?

    init(command: AccountSignInCommand, timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        // Keep stdin open while the provider waits for its browser callback.
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        process.terminationHandler = { [self] process in
            finish(process.terminationStatus == 0 ? .success(()) : .failure(AccountSignInError.failed))
        }
        do { try process.run() }
        catch { lock.unlock(); finish(.failure(AccountSignInError.failed)); return }
        let work = DispatchWorkItem { [weak self] in self?.stop(.failure(AccountSignInError.timedOut)) }
        timeoutWork = work
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func cancel() { stop(.failure(CancellationError())) }
    private func stop(_ result: Result<Void, Error>) {
        lock.lock(); cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        finish(result)
    }
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation; continuation = nil
        timeoutWork?.cancel(); timeoutWork = nil
        process.terminationHandler = nil
        lock.unlock()
        try? input.fileHandleForWriting.close()
        pending?.resume(with: result)
    }
}
