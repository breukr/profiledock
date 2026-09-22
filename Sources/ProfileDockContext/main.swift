import Foundation
import ContextCore
import Darwin

func writeJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
}

do {
    var args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else { throw ContextError.message("Usage: ProfileDockContext mcp|profiles|search|read --profile ID [--query TOPIC --sources ID,ID | --source ID --session ID]") }
    args.removeFirst()
    var values: [String: String] = [:]
    while !args.isEmpty {
        let key = args.removeFirst()
        guard key.hasPrefix("--"), !args.isEmpty, values[key] == nil else { throw ContextError.message("Invalid command arguments.") }
        values[key] = args.removeFirst()
    }
    let common: Set<String> = ["--profile", "--home"]
    let allowed = common.union(command == "search" ? ["--query", "--sources", "--days"] : command == "read" ? ["--source", "--session", "--cursor", "--message"] : [])
    guard Set(values.keys).isSubset(of: allowed) else { throw ContextError.message("Unknown command option.") }
    let registry = ContextRegistry(home: values["--home"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser)
    let caller: String
    if let id = values["--profile"] { caller = id }
    else if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], let profile = try registry.profiles().first(where: { $0.root(in: registry.home).path == URL(fileURLWithPath: codexHome).standardizedFileURL.path }) { caller = profile.id }
    else { throw ContextError.message("A calling profile is required. Connect this profile in ProfileDock → Context.") }
    let server = ContextMCP(service: ContextService(registry: registry, caller: caller))
    switch command {
    case "mcp":
        guard Set(values.keys).isSubset(of: ["--profile", "--home"]) else { throw ContextError.message("Unknown MCP option.") }
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            // FileHandle.read(upToCount:) can wait to fill the buffer on a pipe.
            // A single POSIX read returns each available request while stdin stays open.
            let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw ContextError.message("Could not read the MCP input stream.") }
            buffer.append(contentsOf: bytes.prefix(count))
            guard buffer.count <= 1024 * 1024 else { throw ContextError.message("MCP request is too large.") }
            while let newline = buffer.firstIndex(of: 10) {
                let raw = Data(buffer[..<newline]); buffer.removeFirst(buffer.distance(from: buffer.startIndex, to: newline) + 1)
                do {
                    guard let request = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw ContextError.message("Invalid request.") }
                    if let response = server.response(to: request) { try writeJSON(response) }
                } catch { try writeJSON(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON request."]]) }
            }
        }
    case "profiles": try writeJSON(server.call("list_profiles", arguments: [:]))
    case "search":
        guard let query = values["--query"], let sources = values["--sources"] else { throw ContextError.message("Search requires --query and --sources (comma-separated profile IDs or aliases).") }
        var options: [String: Any] = ["query": query, "profiles": sources.split(separator: ",").map(String.init)]
        if let raw = values["--days"] {
            guard let days = Int(raw) else { throw ContextError.message("--days must be a whole number.") }
            options["days_back"] = days
        }
        try writeJSON(server.call("search_sessions", arguments: options))
    case "read":
        guard let source = values["--source"], let session = values["--session"] else { throw ContextError.message("Read requires --source and --session.") }
        var options: [String: Any] = ["profile": source, "session_id": session]
        if let cursor = values["--cursor"] { options["cursor"] = cursor }
        if let message = values["--message"] { options["message_id"] = message }
        try writeJSON(server.call("read_session", arguments: options))
    default: throw ContextError.message("Unknown command: \(command)")
    }
} catch {
    try? FileHandle.standardError.write(contentsOf: Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
