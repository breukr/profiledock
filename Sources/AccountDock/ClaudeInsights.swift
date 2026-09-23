import Foundation
import DockCore

enum ClaudePricing {
    static let source = "https://platform.claude.com/docs/en/about-claude/pricing"
    static let checkedOn = "23 September 2026"
    static func estimate(model: String?, usage: [String: Any], tokens: InsightTokens) -> Double? {
        guard let model, tokens.valid else { return nil }
        let key = model.replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)
        let rates: [String: (Double, Double, Double)] = [
            "claude-opus-4-5": (5, 25, 0.5), "claude-opus-4-6": (5, 25, 0.5),
            "claude-opus-4-7": (5, 25, 0.5), "claude-opus-4-8": (5, 25, 0.5),
            "claude-opus-5": (5, 25, 0.5), "claude-opus-5-5": (4, 20, 0.2),
            "claude-sonnet-4-5": (3, 15, 0.3), "claude-sonnet-4-6": (3, 15, 0.3),
            "claude-sonnet-5": (2, 10, 0.2), "claude-haiku-4-5": (1, 5, 0.1),
            "claude-fable-5": (10, 50, 1), "claude-fable-5-1": (10, 50, 0.25)
        ]
        guard let rate = rates[key], usage["speed"] as? String != "fast" else { return nil }
        // Legacy extended-context pricing varies; do not silently price it at the base rate.
        if key == "claude-sonnet-4-5", tokens.input > 200_000 { return nil }
        let cache = usage["cache_creation"] as? [String: Any]
        let hour = (cache?["ephemeral_1h_input_tokens"] as? Int64) ?? 0
        guard hour >= 0, hour <= tokens.written else { return nil }
        let ordinary = Double(tokens.input - tokens.cached - tokens.written) * rate.0
        let written = Double(tokens.written - hour) * rate.0 * 1.25 + Double(hour) * rate.0 * 2
        return (ordinary + written + Double(tokens.cached) * rate.2 + Double(tokens.output) * rate.1) / 1_000_000
    }
}

enum ClaudeInsights {
    static func scan(profiles: [Profile], home: URL, cutoff: Date) throws -> InsightsScan {
        let entries = profiles.filter { $0.kind != .codex }.sorted { $0.id < $1.id }
        guard !entries.isEmpty else { return InsightsScan() }
        var result = InsightsScan(), samples: [String: InsightSample] = [:]
        let files = try ClaudeHistory.files(home: home, since: cutoff)
        let deadline = Date().addingTimeInterval(20)
        for file in files {
            try Task.checkCancellation()
            let id = file.deletingPathExtension().lastPathComponent
            var owner: Profile?
            do {
            let limited = try ClaudeHistory.records(file: file, deadline: deadline) { row, _ in
                guard row["isSidechain"] as? Bool != true, let cwd = row["cwd"] as? String else { return true }
                if owner == nil {
                    owner = entries.first { $0.claudeSessionID == id }
                        ?? entries.first { $0.kind.usesTerminal && $0.projectPath == cwd }
                        ?? entries.first { $0.kind == .claude }
                }
                guard let owner, row["type"] as? String == "assistant", let message = row["message"] as? [String: Any],
                      let messageID = message["id"] as? String, let usage = message["usage"] as? [String: Any],
                      let date = ClaudeHistory.timestamp(row["timestamp"] as? String ?? ""), date >= cutoff else { return true }
                func count(_ key: String) -> Int64 { usage[key] as? Int64 ?? 0 }
                let cached = count("cache_read_input_tokens"), written = count("cache_creation_input_tokens"), input = count("input_tokens"), output = count("output_tokens")
                guard [input, cached, written, output].allSatisfy({ $0 >= 0 && $0 <= 1_000_000_000_000 }) else { return true }
                let tokens = InsightTokens(input: input + cached + written, cached: cached, written: written, output: output)
                guard tokens.valid else { return true }
                let key = "claude:" + id + ":" + messageID
                // Streaming can repeat one API response. Keep its most complete counters once.
                if let old = samples[key], old.tokens.total >= tokens.total { return true }
                let model = message["model"] as? String
                samples[key] = InsightSample(id: key, profileID: owner.id, sessionID: "claude:" + id, date: date, model: model, tokens: tokens,
                    estimatedCost: ClaudePricing.estimate(model: model, usage: usage, tokens: tokens))
                return true
            }
            result.files += 1
            if limited || files.count >= 5000 {
                for entry in entries { result.warnings[entry.id] = "Claude history reached a reading limit. Totals cover readable local Code sessions." }
            }
            } catch is CancellationError { throw CancellationError() }
            catch {
                for entry in entries { result.warnings[entry.id] = "Some local Claude transcripts could not be read. Totals cover readable Code records only." }
            }
            if Date() >= deadline { break }
        }
        result.samples = Array(samples.values)
        for entry in entries where result.warnings[entry.id] == nil {
            result.warnings[entry.id] = "Local Claude Code history only; Chat, Cowork, cloud-only and subagent transcripts are excluded. Project entries take precedence over Claude Desktop to avoid counting a session twice."
        }
        return result
    }
}
