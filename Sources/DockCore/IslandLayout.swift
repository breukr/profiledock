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
    public let screen: CGRect
    public let notchHeight: Double
    public let collapsed: CGRect
    public let expanded: CGRect
    public let placement: DockPlacement
    public var opensUpward: Bool { expanded.midY > collapsed.midY }
    public var compactOrigin: CGPoint { CGPoint(x: collapsed.minX - expanded.minX, y: collapsed.minY - expanded.minY) }
    public static func usableFrame(screen: CGRect, visible: CGRect?) -> CGRect {
        (visible ?? screen).intersection(screen).insetBy(dx: 12, dy: 12)
    }
    public static func usageHeight(rows: Int) -> Double { Double(max(1, rows)) * 46 + Double(max(0, rows - 1)) * 10 }

    public init(screen: CGRect, notchHeight: Double, notchWidth: Double, count: Int, scale: Double, hasMessage: Bool, menuBarHeight: Double = 24, showsResetDetails: Bool = false, placement: DockPlacement = .topCenter, visibleFrame: CGRect? = nil, position: FloatingPosition = FloatingPosition(), usageRows: Int = 2) {
        self.screen = screen
        self.placement = placement
        self.notchHeight = placement == .topCenter ? max(0, notchHeight) : 0
        let contentHeight = 325 + 32 * scale + Self.usageHeight(rows: usageRows) - 104 + (hasMessage ? 52 : 0) + (showsResetDetails ? Self.resetDetailsHeight : 0)
        if placement != .topCenter {
            let available = Self.usableFrame(screen: screen, visible: visibleFrame)
            let compactWidth = min(194, available.width)
            let expandedWidth = min(available.width, max(320, Double(max(1, count)) * 142 * scale + 32))
            let expandedHeight = min(available.height, contentHeight)
            if placement == .free {
                let size = CGSize(width: compactWidth, height: min(32, available.height))
                collapsed = CGRect(origin: position.origin(in: available, size: size), size: size)
                let above = available.maxY - collapsed.minY, below = collapsed.maxY - available.minY
                let upward = above >= expandedHeight || above >= below
                expanded = CGRect(x: min(available.maxX - expandedWidth, max(available.minX, collapsed.midX - expandedWidth / 2)),
                                  y: min(available.maxY - expandedHeight, max(available.minY, upward ? collapsed.minY : collapsed.maxY - expandedHeight)),
                                  width: expandedWidth, height: expandedHeight)
                return
            }
            collapsed = CGRect(x: placement == .bottomLeft ? available.minX : available.maxX - compactWidth, y: available.minY, width: compactWidth, height: 32)
            expanded = CGRect(x: placement == .bottomLeft ? available.minX : available.maxX - expandedWidth, y: available.minY, width: expandedWidth, height: expandedHeight)
            return
        }
        let compactWidth = notchHeight > 0 ? max(1, notchWidth) : 194.0
        let compactHeight = notchHeight > 0 ? notchHeight : menuBarHeight
        let expandedWidth = min(screen.width - 32, max(320, Double(max(1, count)) * 142 * scale + 32))
        let expandedHeight = notchHeight + contentHeight
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
