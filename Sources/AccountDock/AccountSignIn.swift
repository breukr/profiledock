import Foundation
import DockCore

struct AccountSignInCommand: Sendable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]

    static func make(profile: Profile, home: URL, executableExists: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) throws -> Self {
        guard Profile.validID(profile.id), profile.kind == .codex || profile.usesClaudeAccountUsage else { throw AccountSignInError.unsupported }
        let candidates = profile.usesClaudeAccountUsage
            ? [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            : [profile.applicationPath.map { $0 + "/Contents/Resources/codex" }, "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"].compactMap { $0 }
        guard let path = candidates.first(where: executableExists) else {
            throw AccountSignInError.missingCLI(claude: profile.usesClaudeAccountUsage)
        }
        // Use a clean environment so another running profile cannot supply authentication overrides.
        var environment = ["HOME": home.path, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin", "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
        if !profile.usesClaudeAccountUsage { environment["CODEX_HOME"] = profile.home(in: home).path }
        return Self(executable: URL(fileURLWithPath: path),
                    arguments: profile.usesClaudeAccountUsage ? ["auth", "login", "--claudeai"] : ["-c", "cli_auth_credentials_store=\"file\"", "login"],
                    environment: environment)
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
