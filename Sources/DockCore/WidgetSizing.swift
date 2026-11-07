import Foundation

public enum WidgetSizing {
    /// Horizontal strip padding and the gap between cards (rows and columns).
    public static let stripPadding = 16.0
    public static let gridGap = 10.0

    public static func compact(count: Int, preferred: Double?) -> Double {
        bounded(preferred, in: 160...480) ?? min(360, 194 + Double(max(0, count - 5)) * 12)
    }
    /// Automatic width fits balanced card columns at their ideal width; a chosen width is kept within 320 to 1400.
    public static func expanded(count: Int, scale: Double, preferred: Double?, insights: Bool) -> Double {
        max(insights ? 520 : 320, bounded(preferred, in: 320...1400) ?? min(1200, gridWidth(columns: automaticColumns(count: count), scale: scale)))
    }
    /// Strip width for `columns` cards at their ideal width.
    public static func gridWidth(columns: Int, scale: Double) -> Double {
        let columns = Double(max(1, columns))
        return columns * CardMetrics.idealWidth(scale: scale) + (columns - 1) * gridGap + 2 * stripPadding
    }
    /// At most four columns, filled as evenly as possible: 5 profiles are 3 + 2, 10 are 4 + 4 + 2.
    public static func automaticColumns(count: Int) -> Int {
        let count = max(1, count), rows = (count + 3) / 4
        return (count + rows - 1) / rows
    }
    /// How many minimum-width cards fit, never more than there are profiles (or chosen columns).
    public static func columns(count: Int, available: Double, scale: Double) -> Int {
        min(max(1, count), max(1, Int((available + gridGap) / (CardMetrics.minWidth(scale: scale) + gridGap))))
    }
    /// Equal-width cards that share the row, capped at the maximum card width (the grid stays leading-aligned).
    public static func cardWidth(columns: Int, available: Double, scale: Double) -> Double {
        let columns = Double(max(1, columns))
        return max(0, min(CardMetrics.maxWidth(scale: scale), ((available - (columns - 1) * gridGap) / columns).rounded(.down)))
    }
    public static func insightsHeight(width: Double, count: Int) -> Double {
        let columns = max(1, Int((width - 60 + 10) / 155))
        let rows = max(1, (max(1, count) + columns - 1) / columns)
        return 400 + Double(rows) * 52 - 20
    }
    /// Collapsed strip: brand mark, the attention or "Agents" label and the chevron take `reserved`; dots fill the rest.
    public static func visibleDots(count: Int, width: Double, floating: Bool) -> Int {
        let reserved = floating ? 154.0 : 124.0
        let capacity = max(1, Int(max(0, width - reserved) / 11))
        return min(count, max(1, capacity - (count > capacity ? 2 : 0)))
    }
    private static func bounded(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// Geometry of one horizontal profile card in the strip. `IslandView` frames every part with these values,
/// so `IslandLayout` can size the panel to the cards exactly.
public enum CardMetrics {
    public static let padding = 12.0
    public static let cornerRadius = 16.0
    /// Name (13 pt) over the status line (11 pt).
    public static let textHeight = 32.0
    public static let usageGap = 10.0
    public static let rowHeight = 14.0
    public static let rowGap = 6.0
    public static let footerGap = 6.0
    /// The saved-resets line is a button, so it keeps a 20 pt hit target.
    public static let footerHeight = 20.0
    public static func minWidth(scale: Double) -> Double { 240 * scale }
    public static func idealWidth(scale: Double) -> Double { 264 * scale }
    public static func maxWidth(scale: Double) -> Double { 340 * scale }
    public static func badge(scale: Double) -> Double { (36 * scale).rounded() }
    public static func headerHeight(scale: Double) -> Double { max(badge(scale: scale), textHeight) }
    public static func usageHeight(rows: Int) -> Double {
        let rows = Double(max(1, rows))
        return rows * rowHeight + (rows - 1) * rowGap
    }
    /// Every card in the strip has this height, so rows line up; only an open reset list adds `resetDetailsHeight`.
    public static func height(usageRows: Int, scale: Double) -> Double {
        2 * padding + headerHeight(scale: scale) + usageGap + usageHeight(rows: usageRows) + footerGap + footerHeight
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
