import Foundation
import DockCore

// Hooks record session metadata (never prompts or messages) and report permission requests, questions, waiting
// prompts and finished turns to the running app over a local socket; message text stays in memory and is never
// written to disk. Only a terminal (`cli`) session's PermissionRequest or AskUserQuestion may wait, and only while the
// app runs with "answer from the notch" on, for at most the hold time the app wrote. Allow, Deny or an answer prints
// Claude Code's documented decision JSON; pass-through, timeout or any error prints nothing, so Claude's own dialog
// takes over. A finished turn (Stop) of a terminal or desktop chat may wait briefly, while pop-ups are on, for a reply
// typed in the pop-up; a reply prints the documented "keep going" output with the reply as the next instruction.
// Every other hook returns at once, and no hook forwards its input anywhere else. In "codex" mode (Codex's
// hooks.json) Codex events are reported and only a finished turn may wait for a reply. In "agent <id>" mode (Gemini
// CLI, Cursor, Copilot CLI, Factory Droid, Qwen Code, OpenCode) events are only reported, never held.
signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
let mode = arguments.dropFirst().first ?? ""
let statusline = mode == "statusline"
let input = FileHandle.standardInput.readData(ofLength: 1_048_577)
let fixtureHome = arguments.firstIndex(of: "--home").flatMap { index in
    index + 1 < arguments.count && arguments[index + 1].hasPrefix("/") ? URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL : nil
}
let home = fixtureHome ?? FileManager.default.homeDirectoryForCurrentUser

/// The controlling terminal of `pid`, asked from `ps` (as before for Claude Code sessions).
func terminal(of pid: Int32) -> String? {
    let query = Process(), pipe = Pipe()
    query.executableURL = URL(fileURLWithPath: "/bin/ps")
    query.arguments = ["-o", "tty=", "-p", String(pid)]
    query.standardOutput = pipe; query.standardError = FileHandle.nullDevice
    guard (try? query.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); query.waitUntilExit()
    let name = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return ClaudeSession.validTTY("/dev/" + name) ? "/dev/" + name : nil
}

if input.count <= 1_048_576, let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
    if mode == "agent" {
        // Display-only events from other agents; nothing is recorded and nothing is printed.
        let agent = arguments.count > 2 ? arguments[2] : ""
        let process = AgentProcess.agent(in: AgentProcess.ancestors())
        let context = AgentHookContext(tty: process?.tty, pid: process?.pid)
        if let message = AgentHookAdapters.message(agent: agent, payload: payload, context: context) {
            AgentInboxClient.post(message, socket: AgentInbox.socket(home: home))
        }
    } else if mode == "codex" {
        // Codex sessions are not Claude sessions and are never recorded.
        let chain = AgentProcess.ancestors()
        let process = AgentProcess.agent(in: chain, names: ["codex"])
        // Tests with a fixture home pin the entry point instead of depending on the test runner's process tree.
        let fixtureEntrypoint = fixtureHome == nil ? nil : ProcessInfo.processInfo.environment["PROFILEDOCK_FIXTURE_ENTRYPOINT"]
        let context = CodexHookContext(codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"], tty: process?.tty, pid: process?.pid,
                                       entrypoint: fixtureEntrypoint ?? AgentProcess.codexEntrypoint(agent: process, host: AgentProcess.hostApplication(in: chain)),
                                       flags: AgentInboxFlags.read(home: home), replyMarkers: StopReplyMarkers(home: home))
        if let output = CodexAttentionHook.deliver(payload: payload, context: context, socket: AgentInbox.socket(home: home)) { print(output) }
    } else if ClaudeSession.isSessionPayload(payload) {
        let process = ClaudeProcess.ancestor()
        let tty = process.flatMap { terminal(of: $0.0) }
        let configDirectory = ClaudeBridgeSettings.configDirectory(environment: ProcessInfo.processInfo.environment, home: home)
        let saved = home.appendingPathComponent("Library/Application Support/Account Dock/ClaudeBridge/" + ClaudeBridgeSettings.originalStatuslineName(configDirectory: configDirectory))
        let original = (try? Data(contentsOf: saved)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // The "ask" group runs beside the regular PreToolUse group, which already records this call.
        if mode != "ask", let session = try? ClaudeSessionStore(home: home).record(payload: payload, statusline: statusline, process: process, tty: tty, configDirectory: configDirectory), statusline, original == nil {
            let text = session.limits.map { "\($0.duration == 18000 ? "5h" : "Week"): \(Int(min(100, $0.used)))% used" }.joined(separator: " · ")
            print(text.isEmpty ? "Claude Code · ProfileDock connected" : text)
        }
        if mode == "hook" || mode == "ask" {
            let context = ClaudeHookContext(configDirectory: configDirectory, tty: tty, pid: process?.0,
                                            entrypoint: ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"], flags: AgentInboxFlags.read(home: home),
                                            replyMarkers: StopReplyMarkers(home: home))
            if let output = ClaudeAttentionHook.deliver(payload: payload, mode: mode, context: context, socket: AgentInbox.socket(home: home)) { print(output) }
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
}
