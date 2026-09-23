import Foundation
import DockCore

// Hooks never block a Claude action, print decisions, or forward their input.
let statusline = CommandLine.arguments.dropFirst().first == "statusline"
let input = FileHandle.standardInput.readData(ofLength: 1_048_577)
if input.count <= 1_048_576,
   let payload = try? JSONSerialization.jsonObject(with: input) as? [String: Any], payload["agent_id"] == nil {
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
    let saved = home.appendingPathComponent("Library/Application Support/Account Dock/ClaudeBridge/original-statusline.json")
    let original = (try? Data(contentsOf: saved)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    if let session = try? ClaudeSessionStore(home: home).record(payload: payload, statusline: statusline, process: process, tty: tty), statusline, original == nil {
        let text = session.limits.map { "\($0.duration == 18000 ? "5h" : "Week"): \(Int(min(100, $0.used)))% used" }.joined(separator: " · ")
        print(text.isEmpty ? "Claude Code · ProfileDock connected" : text)
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
