import Foundation
import DockCore

// Hooks record session metadata (never prompts or messages) and report permission requests, questions, waiting
// prompts and finished turns to the running app over a local socket; message text stays in memory and is never
// written to disk. Only a terminal (`cli`) session's PermissionRequest or AskUserQuestion may wait, and only while the
// app runs with "answer from the notch" on, for at most the hold time the app wrote. Allow, Deny or an answer prints
// Claude Code's documented decision JSON; pass-through, timeout or any error prints nothing, so Claude's own dialog
// takes over. Every other hook returns at once, and no hook forwards its input anywhere else. In "codex" mode (Codex's
// hooks.json, never added automatically) Codex events are only reported, never held.
signal(SIGPIPE, SIG_IGN)
let mode = CommandLine.arguments.dropFirst().first ?? ""
let statusline = mode == "statusline"
let input = FileHandle.standardInput.readData(ofLength: 1_048_577)
if input.count <= 1_048_576,
   let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any], ClaudeSession.isSessionPayload(payload) {
    let process = ClaudeProcess.ancestor()
    var tty: String?
    if let process {
        let query = Process(), pipe = Pipe()
        query.executableURL = URL(fileURLWithPath: "/bin/ps")
        query.arguments = ["-o", "tty=", "-p", String(process.0)]
        query.standardOutput = pipe; query.standardError = FileHandle.nullDevice
        if (try? query.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); query.waitUntilExit()
            let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if ClaudeSession.validTTY("/dev/" + name) { tty = "/dev/" + name }
        }
    }
    let arguments = CommandLine.arguments
    let fixtureHome = arguments.firstIndex(of: "--home").flatMap { index in
        index + 1 < arguments.count && arguments[index + 1].hasPrefix("/") ? URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL : nil
    }
    let home = fixtureHome ?? FileManager.default.homeDirectoryForCurrentUser
    let configDirectory = ClaudeBridgeSettings.configDirectory(environment: ProcessInfo.processInfo.environment, home: home)
    let saved = home.appendingPathComponent("Library/Application Support/Account Dock/ClaudeBridge/" + ClaudeBridgeSettings.originalStatuslineName(configDirectory: configDirectory))
    let original = (try? Data(contentsOf: saved)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    // The "ask" group runs beside the regular PreToolUse group, which already records this call. Codex sessions are
    // not Claude sessions and are never recorded.
    if mode != "ask", mode != "codex", let session = try? ClaudeSessionStore(home: home).record(payload: payload, statusline: statusline, process: process, tty: tty, configDirectory: configDirectory), statusline, original == nil {
        let text = session.limits.map { "\($0.duration == 18000 ? "5h" : "Week"): \(Int(min(100, $0.used)))% used" }.joined(separator: " · ")
        print(text.isEmpty ? "Claude Code · ProfileDock connected" : text)
    }
    if mode == "hook" || mode == "ask" {
        let context = ClaudeHookContext(configDirectory: configDirectory, tty: tty, pid: process?.0,
                                        entrypoint: ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"], flags: AgentInboxFlags.read(home: home))
        if let output = ClaudeAttentionHook.deliver(payload: payload, mode: mode, context: context, socket: AgentInbox.socket(home: home)) { print(output) }
    }
    if mode == "codex", let message = CodexAttentionHook.message(payload: payload, codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"]) {
        AgentInboxClient.post(message, socket: AgentInbox.socket(home: home))
    }
    if statusline, let command = original?["command"] as? String {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = ["-c", command]
        child.standardInput = pipe; child.standardOutput = FileHandle.standardOutput; child.standardError = FileHandle.standardError
        if (try? child.run()) != nil {
            let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
            try? pipe.fileHandleForWriting.write(contentsOf: input); try? pipe.fileHandleForWriting.close()
            child.waitUntilExit(); timeout.cancel()
        }
    }
}
