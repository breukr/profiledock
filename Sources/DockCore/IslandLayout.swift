import Foundation
import CoreGraphics

public struct IslandLayout: Equatable, Sendable {
    public static let resetDetailsHeight: Double = 120
    public let screen: CGRect
    public let notchHeight: Double
    public let collapsed: CGRect
    public let expanded: CGRect

    public init(screen: CGRect, notchHeight: Double, notchWidth: Double, count: Int, scale: Double, hasMessage: Bool, menuBarHeight: Double = 24, showsResetDetails: Bool = false) {
        self.screen = screen
        self.notchHeight = max(0, notchHeight)
        let compactWidth = notchHeight > 0 ? max(1, notchWidth) : 194.0
        let compactHeight = notchHeight > 0 ? notchHeight : menuBarHeight
        let expandedWidth = min(screen.width - 32, max(320, Double(max(1, count)) * 142 * scale + 32))
        let expandedHeight = notchHeight + 313 + 32 * scale + (hasMessage ? 52 : 0) + (showsResetDetails ? Self.resetDetailsHeight : 0)
        collapsed = CGRect(x: screen.midX - compactWidth / 2, y: screen.maxY - compactHeight, width: compactWidth, height: compactHeight)
        expanded = CGRect(x: screen.midX - expandedWidth / 2, y: screen.maxY - expandedHeight, width: expandedWidth, height: expandedHeight)
    }

    public func containsPointer(_ point: CGPoint, expandedOrClosing: Bool) -> Bool {
        let region = expandedOrClosing ? expanded.insetBy(dx: -6, dy: 0) : collapsed
        // CGRect.contains excludes its max edges. The top pixel of a screen must remain a valid hover.
        return point.x >= region.minX && point.x <= region.maxX
            && point.y >= region.minY && point.y <= screen.maxY + 1
    }
}
