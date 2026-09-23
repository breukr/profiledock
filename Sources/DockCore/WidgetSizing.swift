import Foundation

public enum WidgetSizing {
    public static func compact(count: Int, preferred: Double?) -> Double {
        bounded(preferred, in: 160...480) ?? min(360, 194 + Double(max(0, count - 5)) * 12)
    }
    public static func expanded(count: Int, scale: Double, preferred: Double?, insights: Bool) -> Double {
        max(insights ? 520 : 320, bounded(preferred, in: 320...1400) ?? min(880, Double(max(1, count)) * 142 * scale + 32))
    }
    public static func tile(count: Int, available: Double, scale: Double) -> Double {
        let count = max(1, count), gap = 10 * scale
        return min(132 * scale, max(104 * scale, (available - Double(count - 1) * gap) / Double(count)))
    }
    public static func columns(count: Int, available: Double, scale: Double) -> Int {
        min(max(1, count), max(1, Int((available + 10 * scale) / (114 * scale))))
    }
    public static func insightsHeight(width: Double, count: Int) -> Double {
        let columns = max(1, Int((width - 60 + 10) / 155))
        let rows = max(1, (max(1, count) + columns - 1) / columns)
        return 400 + Double(rows) * 52 - 20
    }
    public static func visibleDots(count: Int, width: Double, floating: Bool) -> Int {
        let reserved = floating ? 138.0 : 108.0
        let capacity = max(1, Int(max(0, width - reserved) / 11))
        return min(count, max(1, capacity - (count > capacity ? 2 : 0)))
    }
    private static func bounded(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Explicit page dimensions; nil in preferences retains automatic sizing.
public struct ProfileGrid: Codable, Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public init(columns: Int, rows: Int) {
        self.columns = min(12, max(1, columns)); self.rows = min(12, max(1, rows))
    }
    private enum CodingKeys: String, CodingKey { case columns, rows }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(columns: try values.decode(Int.self, forKey: .columns), rows: try values.decode(Int.self, forKey: .rows))
    }
    public var capacity: Int { columns * rows }
    public var label: String { "\(columns) × \(rows)" }
    public static let presets = [ProfileGrid(columns: 2, rows: 2), ProfileGrid(columns: 3, rows: 3), ProfileGrid(columns: 6, rows: 1), ProfileGrid(columns: 1, rows: 6)]
}
