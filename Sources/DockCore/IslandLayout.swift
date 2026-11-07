import Foundation
import CoreGraphics

public enum DockPlacement: String, Codable, CaseIterable, Sendable {
    case topCenter, free, bottomLeft, bottomRight
    // Retain legacy values for saved 1.1 preferences; only two choices are shown now.
    public static let allCases: [Self] = [.topCenter, .free]
    public var label: String {
        switch self { case .topCenter: return "Top center"; case .free: return "Free position"; case .bottomLeft: return "Bottom left"; case .bottomRight: return "Bottom right" }
    }
    public var instruction: String {
        self == .topCenter ? "Hover at the top center of any screen to open your profiles." : "Drag the grip to move the strip. Hover over the rest to open your profiles."
    }
}

public struct FloatingPosition: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double = 0.5, y: Double = 0.1) {
        self.x = x.isFinite ? min(1, max(0, x)) : 0.5
        self.y = y.isFinite ? min(1, max(0, y)) : 0.1
    }
    public init(origin: CGPoint, available: CGRect, size: CGSize) {
        self.init(x: (origin.x - available.minX) / max(1, available.width - size.width),
                  y: (origin.y - available.minY) / max(1, available.height - size.height))
    }
    public func origin(in available: CGRect, size: CGSize) -> CGPoint {
        let safe = Self(x: x, y: y)
        return CGPoint(x: available.minX + safe.x * max(0, available.width - size.width),
                       y: available.minY + safe.y * max(0, available.height - size.height))
    }
}

public struct IslandLayout: Equatable, Sendable {
    /// Height a card grows by while its saved-reset expiry list is open (reserved only while open).
    public static let resetDetailsHeight: Double = 96
    public static let messageHeight: Double = 100
    /// Strip chrome shared with `IslandView`, so the panel height matches its content exactly (no empty band).
    public static let topInset: Double = 12
    public static let bottomInset: Double = 16
    public static let sectionGap: Double = 12
    public static let headerHeight: Double = 28
    public static let sectionHeaderHeight: Double = 20
    public static let insightsHeaderHeight: Double = 24
    public static let pagerHeight: Double = 20
    public static let emptyStateHeight: Double = 56
    public static let maxAutomaticRows = 4
    public let screen: CGRect
    public let notchHeight: Double
    public let collapsed: CGRect
    public let expanded: CGRect
    public let placement: DockPlacement
    public let profileColumns: Int
    public let profileRows: Int
    public var opensUpward: Bool { expanded.midY > collapsed.midY }
    public var compactOrigin: CGPoint { CGPoint(x: collapsed.minX - expanded.minX, y: collapsed.minY - expanded.minY) }
    public static func usableFrame(screen: CGRect, visible: CGRect?) -> CGRect {
        (visible ?? screen).intersection(screen).insetBy(dx: 12, dy: 12)
    }
    /// Height of `rows` card rows with the grid gap between them.
    public static func gridHeight(rows: Int, usageRows: Int, scale: Double) -> Double {
        rows <= 0 ? 0 : Double(rows) * CardMetrics.height(usageRows: usageRows, scale: scale) + Double(rows - 1) * WidgetSizing.gridGap
    }

    public init(screen: CGRect, notchHeight: Double, notchWidth: Double, count: Int, scale: Double, hasMessage: Bool, menuBarHeight: Double = 24, showsResetDetails: Bool = false, placement: DockPlacement = .topCenter, visibleFrame: CGRect? = nil, position: FloatingPosition = FloatingPosition(), usageRows: Int = 2, showsInsights: Bool = false, compactWidth preferredCompact: Double? = nil, expandedWidth preferredExpanded: Double? = nil, terminalCount: Int? = nil, grid: ProfileGrid? = nil, showsInsightsSection: Bool = true) {
        self.screen = screen
        self.placement = placement
        self.notchHeight = placement == .topCenter ? max(0, notchHeight) : 0
        let available = Self.usableFrame(screen: screen, visible: visibleFrame)
        let availableHeight: Double = placement == .topCenter ? Double(screen.maxY - (visibleFrame?.minY ?? screen.minY)) - 12 - self.notchHeight : Double(available.height)
        let insightsOpen = showsInsights && showsInsightsSection
        let requestedWidth = grid.map { max(insightsOpen ? 520 : 320, WidgetSizing.gridWidth(columns: $0.columns, scale: scale)) }
            ?? WidgetSizing.expanded(count: count, scale: scale, preferred: preferredExpanded, insights: insightsOpen)
        let expandedWidth = min(placement == .topCenter ? screen.width - 32 : available.width, requestedWidth)
        let insightsHeight = insightsOpen ? WidgetSizing.insightsHeight(width: expandedWidth, count: count) : 0
        let columns = WidgetSizing.columns(count: grid?.columns ?? count, available: expandedWidth - 2 * WidgetSizing.stripPadding, scale: scale)
        profileColumns = columns
        let desktops = max(0, count - (terminalCount ?? 0)), terminals = max(0, terminalCount ?? 0)
        let desktopRows = (desktops + columns - 1) / columns, terminalRows = (terminals + columns - 1) / columns
        // Everything except the card rows: header, notices, section headers, empty state and insights.
        var chrome = Self.topInset + Self.headerHeight + Self.bottomInset + (hasMessage ? Self.messageHeight : 0)
        if terminalCount != nil { chrome += Self.sectionGap + Self.sectionHeaderHeight }
        if showsInsightsSection { chrome += Self.sectionGap + Self.insightsHeaderHeight }
        if count == 0 { chrome += Self.sectionGap + Self.emptyStateHeight }
        func occupied(_ rows: Int) -> Int { min(rows, desktopRows) + min(rows, terminalRows) }
        if let grid { profileRows = grid.rows } else {
            // Rows come from the screen budget with reset details always counted, so opening them never moves
            // the clicked account to another page. One pager per section is reserved as well.
            let card = CardMetrics.height(usageRows: usageRows, scale: scale)
            let pagers = (terminalCount == nil ? 1.0 : 2.0) * (Self.sectionGap + Self.pagerHeight)
            let sections = terminalCount == nil || terminals == 0 ? 1.0 : 2.0
            let budget = availableHeight - chrome - insightsHeight - Self.resetDetailsHeight - pagers - sections * Self.sectionGap
            let fitting = max(1, Int((budget + WidgetSizing.gridGap * sections) / (card + WidgetSizing.gridGap)))
            var rows = 1
            while rows < Self.maxAutomaticRows, occupied(rows + 1) > occupied(rows), occupied(rows + 1) <= fitting { rows += 1 }
            profileRows = rows
        }
        let capacity = profileRows * columns
        var contentHeight = chrome + insightsHeight + (showsResetDetails ? Self.resetDetailsHeight : 0)
        let shownDesktopRows = min(profileRows, desktopRows), shownTerminalRows = terminalCount == nil ? 0 : min(profileRows, terminalRows)
        if shownDesktopRows > 0 { contentHeight += Self.sectionGap + Self.gridHeight(rows: shownDesktopRows, usageRows: usageRows, scale: scale) }
        if desktops > capacity { contentHeight += Self.sectionGap + Self.pagerHeight }
        if shownTerminalRows > 0 { contentHeight += Self.sectionGap + Self.gridHeight(rows: shownTerminalRows, usageRows: usageRows, scale: scale) }
        if terminalCount != nil, terminals > capacity { contentHeight += Self.sectionGap + Self.pagerHeight }
        if placement != .topCenter {
            let compactWidth = min(WidgetSizing.compact(count: count, preferred: preferredCompact), available.width)
            let expandedHeight = min(available.height, contentHeight)
            if placement == .free {
                let size = CGSize(width: compactWidth, height: min(32, available.height))
                collapsed = CGRect(origin: position.origin(in: available, size: size), size: size)
                let above = available.maxY - collapsed.minY, below = collapsed.maxY - available.minY
                let upward = above >= expandedHeight || above >= below
                expanded = CGRect(x: min(available.maxX - expandedWidth, max(available.minX, collapsed.midX - expandedWidth / 2)),
                                  y: min(available.maxY - expandedHeight, max(available.minY, upward ? collapsed.minY : collapsed.maxY - CGFloat(expandedHeight))),
                                  width: expandedWidth, height: expandedHeight)
                return
            }
            collapsed = CGRect(x: placement == .bottomLeft ? available.minX : available.maxX - compactWidth, y: available.minY, width: compactWidth, height: 32)
            expanded = CGRect(x: placement == .bottomLeft ? available.minX : available.maxX - expandedWidth, y: available.minY, width: expandedWidth, height: expandedHeight)
            return
        }
        let compactWidth = notchHeight > 0 ? max(1, notchWidth) : min(screen.width - 32, WidgetSizing.compact(count: count, preferred: preferredCompact))
        let compactHeight = notchHeight > 0 ? notchHeight : menuBarHeight
        let expandedHeight = min(self.notchHeight + contentHeight, availableHeight + self.notchHeight)
        collapsed = CGRect(x: screen.midX - compactWidth / 2, y: screen.maxY - compactHeight, width: compactWidth, height: compactHeight)
        expanded = CGRect(x: screen.midX - expandedWidth / 2, y: screen.maxY - expandedHeight, width: expandedWidth, height: expandedHeight)
    }

    public func containsPointer(_ point: CGPoint, expandedOrClosing: Bool) -> Bool {
        let region = expandedOrClosing ? expanded.insetBy(dx: -6, dy: 0) : collapsed
        // CGRect.contains excludes its max edges. The top pixel of a screen must remain a valid hover.
        return point.x >= region.minX && point.x <= region.maxX
            && point.y >= region.minY && point.y <= (placement == .topCenter ? screen.maxY + 1 : region.maxY)
    }
}
