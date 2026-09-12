import Foundation
import CoreGraphics

public enum DockPlacement: String, Codable, CaseIterable, Sendable {
    case topCenter, bottomLeft, bottomRight
    public var label: String {
        switch self { case .topCenter: return "Top center"; case .bottomLeft: return "Bottom left"; case .bottomRight: return "Bottom right" }
    }
    public var instruction: String {
        self == .topCenter ? "Hover at the top center of any screen to open your profiles." : "Hover over the floating launcher in the lower corner to open your profiles."
    }
}

public struct IslandLayout: Equatable, Sendable {
    public static let resetDetailsHeight: Double = 120
    public let screen: CGRect
    public let notchHeight: Double
    public let collapsed: CGRect
    public let expanded: CGRect
    public let placement: DockPlacement
    public var compactOrigin: CGPoint { CGPoint(x: collapsed.minX - expanded.minX, y: collapsed.minY - expanded.minY) }

    public init(screen: CGRect, notchHeight: Double, notchWidth: Double, count: Int, scale: Double, hasMessage: Bool, menuBarHeight: Double = 24, showsResetDetails: Bool = false, placement: DockPlacement = .topCenter, visibleFrame: CGRect? = nil) {
        self.screen = screen
        self.placement = placement
        self.notchHeight = placement == .topCenter ? max(0, notchHeight) : 0
        if placement != .topCenter {
            let available = (visibleFrame ?? screen).intersection(screen).insetBy(dx: 12, dy: 12)
            let compactWidth = min(194, available.width)
            let expandedWidth = min(available.width, max(320, Double(max(1, count)) * 142 * scale + 32))
            let expandedHeight = min(available.height, 313 + 32 * scale + (hasMessage ? 52 : 0) + (showsResetDetails ? Self.resetDetailsHeight : 0))
            collapsed = CGRect(x: placement == .bottomLeft ? available.minX : available.maxX - compactWidth, y: available.minY, width: compactWidth, height: 32)
            expanded = CGRect(x: placement == .bottomLeft ? available.minX : available.maxX - expandedWidth, y: available.minY, width: expandedWidth, height: expandedHeight)
            return
        }
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
            && point.y >= region.minY && point.y <= (placement == .topCenter ? screen.maxY + 1 : region.maxY)
    }
}
