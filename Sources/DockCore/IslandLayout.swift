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
    public static let resetDetailsHeight: Double = 120
    public static let messageHeight: Double = 100
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
    public static func usageHeight(rows: Int) -> Double { Double(max(1, rows)) * 46 + Double(max(0, rows - 1)) * 10 }

    public init(screen: CGRect, notchHeight: Double, notchWidth: Double, count: Int, scale: Double, hasMessage: Bool, menuBarHeight: Double = 24, showsResetDetails: Bool = false, placement: DockPlacement = .topCenter, visibleFrame: CGRect? = nil, position: FloatingPosition = FloatingPosition(), usageRows: Int = 2, showsInsights: Bool = false, compactWidth preferredCompact: Double? = nil, expandedWidth preferredExpanded: Double? = nil, terminalCount: Int? = nil) {
        self.screen = screen
        self.placement = placement
        self.notchHeight = placement == .topCenter ? max(0, notchHeight) : 0
        let available = Self.usableFrame(screen: screen, visible: visibleFrame)
        let availableHeight: Double = placement == .topCenter ? Double(screen.maxY - (visibleFrame?.minY ?? screen.minY)) - 12 - self.notchHeight : Double(available.height)
        let expandedWidth = min(placement == .topCenter ? screen.width - 32 : available.width, WidgetSizing.expanded(count: count, scale: scale, preferred: preferredExpanded, insights: showsInsights))
        let insightsHeight = showsInsights ? WidgetSizing.insightsHeight(width: expandedWidth, count: count) : 0
        let singleRowHeight = 325 + 32 * scale + Self.usageHeight(rows: usageRows) - 104 + (hasMessage ? Self.messageHeight : 0) + (showsResetDetails ? Self.resetDetailsHeight : 0) + 34
        let cardHeight = singleRowHeight - 110 - (hasMessage ? Self.messageHeight : 0)
        profileColumns = WidgetSizing.columns(count: count, available: expandedWidth - 32, scale: scale)
        let desiredRows: Int
        if let terminalCount, terminalCount > 0 {
            desiredRows = max(1, (max(0, count - terminalCount) + profileColumns - 1) / profileColumns + (terminalCount + profileColumns - 1) / profileColumns)
        } else { desiredRows = (max(1, count) + profileColumns - 1) / profileColumns }
        // Keep row count stable when reset details open, so the clicked account cannot disappear onto another page.
        let resetReserve = showsResetDetails ? 0 : Self.resetDetailsHeight
        let extraRows = max(0, Int((availableHeight - singleRowHeight - resetReserve - insightsHeight - 28) / (cardHeight + resetReserve + 10)))
        profileRows = min(desiredRows, min(2, 1 + extraRows))
        let paged = count > profileRows * profileColumns
        let contentHeight = (terminalCount == nil ? 0 : 56) + singleRowHeight + Double(profileRows - 1) * (cardHeight + 10) + insightsHeight + (paged ? 28 : 0)
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
