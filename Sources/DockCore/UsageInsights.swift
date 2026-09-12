import Foundation

public enum InsightsExpansion: String, Codable, CaseIterable, Sendable {
    case button, hover, always
    public var label: String {
        switch self { case .button: return "On click"; case .hover: return "On hover"; case .always: return "Always expanded" }
    }
}

public enum InsightsPeriod: Int, CaseIterable, Sendable {
    case today = 1, week = 7, month = 30
    public var label: String { self == .today ? "Today" : "\(rawValue) days" }
    public func start(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1 - rawValue, to: calendar.startOfDay(for: now))!
    }
}

public struct InsightTokens: Equatable, Hashable, Codable, Sendable {
    public var input: Int64
    public var cached: Int64
    public var written: Int64
    public var output: Int64
    public var total: Int64 { input + output }
    public init(input: Int64 = 0, cached: Int64 = 0, written: Int64 = 0, output: Int64 = 0) {
        self.input = input; self.cached = cached; self.written = written; self.output = output
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached,
             written: lhs.written + rhs.written, output: lhs.output + rhs.output)
    }
    public func delta(from previous: Self) -> Self? {
        guard input >= previous.input, cached >= previous.cached, written >= previous.written, output >= previous.output else { return nil }
        let value = Self(input: input - previous.input, cached: cached - previous.cached,
                         written: written - previous.written, output: output - previous.output)
        return value.valid ? value : nil
    }
    public var valid: Bool {
        [input, cached, written, output].allSatisfy { $0 >= 0 && $0 <= 1_000_000_000_000 }
            && cached + written <= input
    }
}

/// A current-rate text-token comparison, not historical billing or subscription spend.
public enum InsightPricing {
    public static let checkedOn = "12 September 2026"
    public static let source = "https://developers.openai.com/api/docs/pricing"
    private struct Rate {
        let input: Double, cached: Double, written: Double?, output: Double
        var longContext = false
    }
    private static let rates: [String: Rate] = [
        "gpt-6-astra": Rate(input: 10, cached: 1, written: 12.5, output: 50, longContext: true),
        "gpt-5.6-sol": Rate(input: 4, cached: 0.4, written: 5, output: 20, longContext: true),
        "gpt-5.6": Rate(input: 4, cached: 0.4, written: 5, output: 20, longContext: true),
        "gpt-5.6-terra": Rate(input: 2, cached: 0.2, written: 2.5, output: 12, longContext: true),
        "gpt-5.6-luna": Rate(input: 0.2, cached: 0.02, written: 0.25, output: 1.2, longContext: true),
        "gpt-5.5": Rate(input: 5, cached: 0.5, written: nil, output: 30, longContext: true),
        "gpt-5.4": Rate(input: 2.5, cached: 0.25, written: nil, output: 15, longContext: true),
        "gpt-5.4-mini": Rate(input: 0.75, cached: 0.075, written: nil, output: 4.5),
        "gpt-5.4-nano": Rate(input: 0.2, cached: 0.02, written: nil, output: 1.25),
        "gpt-5.3-codex": Rate(input: 1.75, cached: 0.175, written: nil, output: 14),
        "gpt-5.2": Rate(input: 1.75, cached: 0.175, written: nil, output: 14),
        "gpt-5.1": Rate(input: 1.25, cached: 0.125, written: nil, output: 10),
        "gpt-5": Rate(input: 1.25, cached: 0.125, written: nil, output: 10),
        "gpt-5-mini": Rate(input: 0.25, cached: 0.025, written: nil, output: 2),
        "gpt-5-nano": Rate(input: 0.05, cached: 0.005, written: nil, output: 0.4)
    ]
    public static func estimate(model: String?, tokens: InsightTokens) -> Double? {
        guard tokens.valid, let model, model.utf8.count < 128 else { return nil }
        let key = model.replacingOccurrences(of: "-[0-9]{4}-[0-9]{2}-[0-9]{2}$", with: "", options: .regularExpression)
        guard let rate = rates[key], tokens.written == 0 || rate.written != nil else { return nil }
        let long = rate.longContext && tokens.input > 272_000
        let input = Double(tokens.input - tokens.cached - tokens.written) * rate.input
            + Double(tokens.cached) * rate.cached + Double(tokens.written) * (rate.written ?? 0)
        return (input * (long ? 2 : 1) + Double(tokens.output) * rate.output * (long ? 1.5 : 1)) / 1_000_000
    }
}

public struct InsightSample: Codable, Sendable {
    public let id: String
    public let profileID: String
    public let sessionID: String
    public let date: Date
    public let model: String?
    public let tokens: InsightTokens
    public let estimatedCost: Double?
    public init(id: String, profileID: String, sessionID: String, date: Date, model: String?, tokens: InsightTokens, estimatedCost: Double?) {
        self.id = id; self.profileID = profileID; self.sessionID = sessionID; self.date = date
        self.model = model; self.tokens = tokens; self.estimatedCost = estimatedCost
    }
}

public struct InsightBucket: Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public var tokens = InsightTokens()
    public var cost: Double = 0
    public var sessions: Set<String> = []
    public var unpricedTokens: Int64 = 0
    public var accounts: [String: InsightAccountSlice] = [:]
}

public struct InsightAccountSlice: Identifiable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970):\(profileID)" }
    public let profileID: String
    public let date: Date
    public var tokens = InsightTokens()
    public var cost: Double = 0
    public var sessions: Set<String> = []
    public var unpricedTokens: Int64 = 0
}

public struct InsightReport: Sendable {
    public var tokens = InsightTokens()
    public var cost: Double = 0
    public var sessions: Set<String> = []
    public var unpricedTokens: Int64 = 0
    public var unknownModels: Set<String> = []
    public var buckets: [InsightBucket] = []
    public var averageCost: Double? { sessions.isEmpty || unpricedTokens > 0 ? nil : cost / Double(sessions.count) }
    public static func make(samples: [InsightSample], profileID: String?, period: InsightsPeriod, now: Date, calendar: Calendar = .current) -> Self {
        let start = period.start(now: now, calendar: calendar)
        let component: Calendar.Component = period == .today ? .hour : .day
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        var report = Self(), cursor = start
        while cursor < end {
            report.buckets.append(InsightBucket(date: cursor))
            cursor = calendar.date(byAdding: component, value: 1, to: cursor)!
        }
        var seen: Set<String> = []
        for sample in samples where (profileID == nil || sample.profileID == profileID) && sample.date >= start && sample.date <= now {
            guard seen.insert(sample.id).inserted,
                  let index = report.buckets.lastIndex(where: { $0.date <= sample.date }) else { continue }
            report.tokens = report.tokens + sample.tokens
            report.sessions.insert(sample.sessionID)
            report.buckets[index].tokens = report.buckets[index].tokens + sample.tokens
            var account = report.buckets[index].accounts[sample.profileID]
                ?? InsightAccountSlice(profileID: sample.profileID, date: report.buckets[index].date)
            account.tokens = account.tokens + sample.tokens
            if report.buckets[index].sessions.insert(sample.sessionID).inserted { account.sessions.insert(sample.sessionID) }
            if let cost = sample.estimatedCost {
                report.cost += cost; report.buckets[index].cost += cost
                account.cost += cost
            } else {
                report.unpricedTokens += sample.tokens.total
                report.buckets[index].unpricedTokens += sample.tokens.total
                report.unknownModels.insert(sample.model ?? "Unknown model")
                account.unpricedTokens += sample.tokens.total
            }
            report.buckets[index].accounts[sample.profileID] = account
        }
        return report
    }
}
