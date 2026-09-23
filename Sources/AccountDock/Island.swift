import AppKit
import SwiftUI
import QuartzCore
import DockCore
import Combine

final class AccountPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class IslandPresentation: ObservableObject {
    @Published var expanded: Bool
    @Published var opensUpward = false
    @Published var profileColumns = 1
    @Published var profileRows = 1
    @Published private(set) var resetDetails: Set<String> = []
    @Published private(set) var insightsExpanded = false
    var insightsPopoverPresented = false
    var onResetDetailsChange: (() -> Void)?
    var onInsightsWillChange: (() -> Void)?
    var onInsightsChange: (() -> Void)?
    init(expanded: Bool = false) { self.expanded = expanded }
    func setInsightsExpanded(_ value: Bool) {
        guard value != insightsExpanded else { return }
        onInsightsWillChange?()
        insightsExpanded = value; onInsightsChange?()
    }
    func toggleResetDetails(_ profileID: String) {
        if !resetDetails.insert(profileID).inserted { resetDetails.remove(profileID) }
        onResetDetailsChange?()
    }
}

@MainActor
final class IslandController {
    let screen: NSScreen
    let panel: AccountPanel
    let compactPanel: AccountPanel
    let model: DockModel
    let usage: UsageStore
    let presentation = IslandPresentation()
    private let presentWindows: Bool
    private let reduceMotion: () -> Bool
    private(set) var layout: IslandLayout
    private(set) var expanded = false
    private(set) var animating = false
    private let surface = IslandSurface()
    private var collapseTimer: Timer?
    private var scheduledCollapse: TimeInterval?
    private var hoverIntent = HoverIntent()
    private var animationGeneration = 0
    private var insightsSnapshot: CGImage?
    private var usageSubscription: AnyCancellable?
    private var menuSubscriptions = Set<AnyCancellable>()
    private var trackedMenus: Set<ObjectIdentifier> = []
    private var dragStart: (pointer: CGPoint, origin: CGPoint)?
    private var draggedPosition: FloatingPosition?
    private let frameMeter = AnimationFrameMeter()
    var measureAnimations = false
    private var screenKey: String { String(describing: screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? screen.localizedName) }

    static func positionKey(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return screen.localizedName
    }

    static func layout(screen: NSScreen, model: DockModel, showsResetDetails: Bool = false, position: FloatingPosition? = nil, usageRows: Int = 2, showsInsights: Bool = false) -> IslandLayout {
        let notchWidth: CGFloat
        if screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notchWidth = right.minX - left.maxX
        } else { notchWidth = 180 }
        let topInset = screen.frame.maxY - screen.visibleFrame.maxY
        let menuBarHeight = topInset > 0 ? topInset : NSStatusBar.system.thickness
        return IslandLayout(screen: screen.frame, notchHeight: screen.safeAreaInsets.top, notchWidth: notchWidth, count: model.displayedProfiles.count, scale: model.preferences.scale, hasMessage: model.message != nil, menuBarHeight: menuBarHeight, showsResetDetails: showsResetDetails, placement: model.placement, visibleFrame: screen.visibleFrame, position: position ?? model.floatingPosition(for: positionKey(for: screen)), usageRows: usageRows, showsInsights: model.preferences.showInsightsSection != false && (showsInsights || model.preferences.insightsExpansion == .always), compactWidth: model.preferences.compactWidth, expandedWidth: model.preferences.expandedWidth, terminalCount: model.preferences.showTerminalsSection == false ? nil : model.preferences.terminalsExpanded == false ? 0 : model.liveTerminalProfiles.count, grid: model.preferences.profileGrid, showsInsightsSection: model.preferences.showInsightsSection != false)
    }

    init(screen: NSScreen, model: DockModel, usage: UsageStore, activity: ActivityMonitor? = nil, insights: InsightsStore? = nil, presentWindows: Bool = true,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }, settings: @escaping () -> Void) {
        self.screen = screen; self.model = model; self.usage = usage
        self.presentWindows = presentWindows
        self.reduceMotion = reduceMotion
        let activity = activity ?? ActivityMonitor(home: model.home)
        layout = Self.layout(screen: screen, model: model, usageRows: usage.cardUsageRows)
        presentation.profileColumns = layout.profileColumns; presentation.profileRows = layout.profileRows
        panel = Self.makePanel(frame: layout.expanded, title: "Account Dock · \(screen.localizedName)")
        compactPanel = Self.makePanel(frame: layout.collapsed, title: "Account Dock · \(screen.localizedName)")
        compactPanel.hasShadow = false
        if layout.notchHeight == 0 {
            let compact = NSHostingView(rootView: CompactIslandView(model: model, activity: activity, presentation: presentation, drag: { [weak self] phase, point in self?.drag(phase, at: point) }))
            compact.sizingOptions = []
            compactPanel.contentView = compact
        } else {
            compactPanel.alphaValue = 0
            compactPanel.ignoresMouseEvents = true
        }
        let content = NSHostingView(rootView: IslandView(model: model, usage: usage, activity: activity, insights: insights ?? InsightsStore(), presentation: presentation, notchHeight: layout.notchHeight, settings: settings, drag: { [weak self] phase, point in self?.drag(phase, at: point) }))
        content.sizingOptions = []
        surface.install(content)
        panel.contentView = surface
        // The complete account layout is prepared once; hover animates only composited layer properties.
        panel.setFrame(layout.expanded, display: false)
        compactPanel.setFrame(layout.collapsed, display: false)
        surface.layoutSubtreeIfNeeded()
        surface.compactOrigin = layout.compactOrigin; surface.floating = layout.placement != .topCenter
        surface.reveal(expanded: false, compactSize: layout.collapsed.size, duration: 0, fps: preferredFPS)
        presentation.onResetDetailsChange = { [weak self] in self?.updateLayout() }
        presentation.onInsightsWillChange = { [weak self] in
            guard let self, self.expanded, !self.reduceMotion() else { return }
            self.insightsSnapshot = self.surface.contentSnapshot()
        }
        presentation.onInsightsChange = { [weak self] in self?.updateLayout(animateInsights: true) }
        presentation.opensUpward = layout.opensUpward
        usageSubscription = usage.$entries.receive(on: RunLoop.main).map { _ in usage.cardUsageRows }.removeDuplicates().sink { [weak self] _ in self?.updateLayout() }
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification).sink { [weak self] notice in
            guard let self, let menu = notice.object as? NSMenu else { return }
            self.trackedMenus.insert(ObjectIdentifier(menu))
            self.cancelCollapseForInteraction()
        }.store(in: &menuSubscriptions)
        NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification).sink { [weak self] notice in
            guard let self, let menu = notice.object as? NSMenu else { return }
            self.trackedMenus.remove(ObjectIdentifier(menu))
            if self.trackedMenus.isEmpty { self.checkHover() }
        }.store(in: &menuSubscriptions)
        showPanel()
    }

    private static func makePanel(frame: NSRect, title: String) -> AccountPanel {
        let panel = AccountPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.isMovable = false; panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        return panel
    }

    var preferredFPS: Float { Float(max(60, min(120, screen.maximumFramesPerSecond))) }

    func showPanel() {
        guard presentWindows else { return }
        if expanded { panel.orderFrontRegardless() }
        else if layout.notchHeight == 0 { compactPanel.orderFrontRegardless() }
    }

    func shutdown() {
        usageSubscription?.cancel()
        menuSubscriptions.removeAll(); trackedMenus.removeAll()
        presentation.expanded = false
        animationGeneration += 1
        collapseTimer?.invalidate(); frameMeter.stop()
        surface.reveal(expanded: false, compactSize: layout.collapsed.size, duration: 0, fps: preferredFPS)
        usage.setVisible(false, screen: screenKey)
        panel.orderOut(nil); compactPanel.orderOut(nil)
    }

    func updateLayout(animateInsights: Bool = false) {
        defer { insightsSnapshot = nil }
        let next = Self.layout(screen: screen, model: model, showsResetDetails: !presentation.resetDetails.isEmpty, position: draggedPosition, usageRows: usage.cardUsageRows, showsInsights: presentation.insightsExpanded)
        guard next != layout else { return }
        let animate = animateInsights && expanded && !reduceMotion()
        let oldFrame = panel.frame
        let oldVisible = (surface.presentationBounds ?? surface.bounds).offsetBy(dx: oldFrame.minX, dy: oldFrame.minY)
        let oldContent = surface.contentFrame.offsetBy(dx: oldFrame.minX, dy: oldFrame.minY)
        let snapshot = animate ? insightsSnapshot : nil
        animationGeneration += 1; animating = false; frameMeter.stop()
        let generation = animationGeneration
        layout = next
        presentation.profileColumns = layout.profileColumns; presentation.profileRows = layout.profileRows
        presentation.opensUpward = next.opensUpward
        surface.compactOrigin = layout.compactOrigin; surface.floating = layout.placement != .topCenter
        // Resize the native window once; animate its mask and content layers on a fixed canvas.
        let canvas = animate ? oldFrame.union(next.expanded) : next.expanded
        panel.setFrame(canvas, display: false)
        surface.contentRect = next.expanded.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        compactPanel.setFrame(layout.collapsed, display: false)
        surface.layoutSubtreeIfNeeded()
        if animate {
            animating = true
            if measureAnimations { frameMeter.start(screen: screen, fps: preferredFPS, surface: surface) }
            surface.resize(from: oldVisible.offsetBy(dx: -canvas.minX, dy: -canvas.minY),
                           to: surface.contentRect!, snapshot: snapshot,
                           snapshotRect: oldContent.offsetBy(dx: -canvas.minX, dy: -canvas.minY),
                           opening: presentation.insightsExpanded, fps: preferredFPS) { [weak self] in
                guard let self, self.animationGeneration == generation else { return }
                self.finishLayoutResize()
            }
            return
        }
        surface.contentRect = nil
        surface.reveal(expanded: expanded, compactSize: layout.collapsed.size, duration: 0, fps: preferredFPS)
        if !expanded { panel.orderOut(nil) }
        showPanel()
    }

    private func finishLayoutResize() {
        animating = false; frameMeter.stop()
        panel.setFrame(layout.expanded, display: false)
        surface.contentRect = nil
        surface.layoutSubtreeIfNeeded()
        surface.reveal(expanded: expanded, compactSize: layout.collapsed.size, duration: 0, fps: preferredFPS)
    }

    func pointerMoved(to point: NSPoint) {
        guard dragStart == nil else { return }
        if model.draggingProfileID != nil { cancelCollapseForInteraction(); return }
        if model.placement != .topCenter { updateLayout() }
        checkHover(at: point)
    }

    private func checkHover(at point: NSPoint = NSEvent.mouseLocation) {
        guard dragStart == nil else { return }
        if presentation.insightsPopoverPresented || !trackedMenus.isEmpty {
            cancelCollapseForInteraction()
            return
        }
        // Keep the collapsed grip under the pointer so pressing it can begin a drag.
        if model.placement == .free, !expanded,
           CGRect(x: layout.collapsed.minX, y: layout.collapsed.minY, width: 30, height: layout.collapsed.height).contains(point) { return }
        // One stable source of pointer truth; animated SwiftUI enter/exit events cannot toggle the island.
        let inside = layout.containsPointer(point, expandedOrClosing: expanded || animating)
            || (surface.isResizing && panel.frame.contains(point))
        setExpanded(hoverIntent.update(inside: inside, now: ProcessInfo.processInfo.systemUptime))
        guard scheduledCollapse != hoverIntent.collapseDeadline else { return }
        collapseTimer?.invalidate(); collapseTimer = nil
        scheduledCollapse = hoverIntent.collapseDeadline
        if let deadline = scheduledCollapse {
            let timer = Timer(timeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduledCollapse = nil; self?.checkHover() }
            }
            collapseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func cancelCollapseForInteraction() {
        collapseTimer?.invalidate(); collapseTimer = nil; scheduledCollapse = nil
        if expanded { _ = hoverIntent.update(inside: true, now: ProcessInfo.processInfo.systemUptime) }
    }

    func drag(_ phase: DockDragPhase, at point: CGPoint) {
        guard model.placement == .free else { return }
        if phase == .began {
            dragStart = (point, layout.collapsed.origin)
            collapseTimer?.invalidate(); collapseTimer = nil; scheduledCollapse = nil
        }
        guard let start = dragStart else { return }
        let origin = CGPoint(x: start.origin.x + point.x - start.pointer.x, y: start.origin.y + point.y - start.pointer.y)
        let position = FloatingPosition(origin: origin, available: IslandLayout.usableFrame(screen: screen.frame, visible: screen.visibleFrame), size: layout.collapsed.size)
        draggedPosition = position
        updateLayout()
        if phase == .ended {
            dragStart = nil
            model.savePosition(position, for: Self.positionKey(for: screen))
            draggedPosition = nil
            checkHover(at: point)
        }
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        if surface.isResizing {
            let visible = surface.presentationBounds?.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
            animationGeneration += 1
            finishLayoutResize()
            if let visible { surface.setVisibleRect(visible.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)) }
        }
        expanded = value
        presentation.expanded = value
        animationGeneration += 1
        let generation = animationGeneration
        let duration = reduceMotion() ? 0 : (value ? 0.16 : 0.14)
        animating = duration > 0
        if value {
            compactPanel.orderOut(nil)
            panel.ignoresMouseEvents = false
            if presentWindows { panel.orderFrontRegardless() }
        } else { panel.ignoresMouseEvents = true }
        if measureAnimations && duration > 0 { frameMeter.start(screen: screen, fps: preferredFPS, surface: surface) }
        surface.reveal(expanded: value, compactSize: layout.collapsed.size, duration: duration, fps: preferredFPS) { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            self.animating = false
            self.frameMeter.stop()
            if !self.expanded {
                self.panel.orderOut(nil)
                if self.model.preferences.insightsExpansion != .always { self.presentation.setInsightsExpanded(false) }
                self.showPanel()
            }
        }
        usage.setVisible(value, screen: screenKey)
    }

    var diagnostics: [String: Any] {
        ["screen": screen.localizedName, "actualFrame": NSStringFromRect(expanded ? panel.frame : compactPanel.frame),
         "expandedPanelFrame": NSStringFromRect(panel.frame), "contentFrame": NSStringFromRect(surface.bounds),
         "collapsedFrame": NSStringFromRect(layout.collapsed), "expanded": expanded, "animating": animating,
         "terminalsSection": model.preferences.showTerminalsSection != false, "insightsSection": model.preferences.showInsightsSection != false, "profileColumns": layout.profileColumns, "profileRows": layout.profileRows, "resetDetails": presentation.resetDetails.sorted(), "placement": model.placement.rawValue,
         "alpha": expanded ? panel.alphaValue : compactPanel.alphaValue,
         "maximumScreenFPS": screen.maximumFramesPerSecond, "requestedAnimationFPS": preferredFPS,
         "frameMeasurement": frameMeter.report, "animationCount": animationGeneration]
    }
}

@MainActor
final class IslandSurface: NSView {
    var compactOrigin: CGPoint?
    var floating = false
    var contentRect: CGRect? { didSet { needsLayout = true } }
    private var hosted: NSView?
    private let revealMask = CAShapeLayer()
    private let border = CAShapeLayer()
    private var outgoingContent: CALayer?
    private(set) var isResizing = false

    func install(_ view: NSView) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = revealMask
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        addSubview(view); hosted = view
        border.fillColor = nil
        border.strokeColor = NSColor.white.withAlphaComponent(0.13).cgColor
        border.lineWidth = 1
        layer?.addSublayer(border)
    }

    override func layout() {
        super.layout()
        hosted?.frame = contentRect ?? bounds
        border.frame = bounds; revealMask.frame = bounds
    }

    var presentationBounds: CGRect? { revealMask.presentation()?.path?.boundingBoxOfPath }
    var contentFrame: CGRect { hosted?.frame ?? bounds }

    func setVisibleRect(_ rect: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let shape = Self.path(in: rect, bottomRadius: 27, roundedTop: floating)
        revealMask.path = shape; border.path = shape
        CATransaction.commit()
    }

    func contentSnapshot() -> CGImage? {
        guard let hosted, let bitmap = hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds) else { return nil }
        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
        return bitmap.cgImage
    }

    func resize(from: CGRect, to: CGRect, snapshot: CGImage?, snapshotRect: CGRect,
                opening: Bool, fps: Float, completion: @escaping () -> Void) {
        cancelResize()
        isResizing = true
        let target = Self.path(in: to, bottomRadius: 27, roundedTop: floating)
        let duration = opening ? 0.42 : 0.3
        CATransaction.begin(); CATransaction.setDisableActions(true)
        revealMask.removeAnimation(forKey: "reveal"); border.removeAnimation(forKey: "reveal")
        hosted?.layer?.removeAnimation(forKey: "revealOpacity")
        revealMask.path = target; border.path = target; hosted?.layer?.opacity = 1
        CATransaction.setCompletionBlock(completion)
        let spring = CASpringAnimation(keyPath: "path")
        spring.fromValue = Self.path(in: from, bottomRadius: 27, roundedTop: floating)
        spring.toValue = target; spring.duration = duration
        spring.mass = 1; spring.stiffness = opening ? 320 : 420; spring.damping = opening ? 36 : 42
        spring.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
        revealMask.add(spring, forKey: "resize"); border.add(spring, forKey: "resize")
        if let snapshot {
            let outgoing = CALayer()
            outgoing.frame = snapshotRect; outgoing.contents = snapshot; outgoing.opacity = 0
            layer?.insertSublayer(outgoing, below: border); outgoingContent = outgoing
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1; fade.toValue = 0; fade.duration = opening ? 0.16 : 0.2
            outgoing.add(fade, forKey: "contentFade")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = opening ? 0.24 : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        hosted?.layer?.add(fade, forKey: "resizeOpacity")
        CATransaction.commit()
    }

    private func cancelResize() {
        isResizing = false
        revealMask.removeAnimation(forKey: "resize"); border.removeAnimation(forKey: "resize")
        hosted?.layer?.removeAnimation(forKey: "resizeOpacity")
        outgoingContent?.removeFromSuperlayer(); outgoingContent = nil
    }

    func reveal(expanded: Bool, compactSize: CGSize, duration: TimeInterval, fps: Float, completion: @escaping () -> Void = {}) {
        cancelResize()
        let rect = expanded ? bounds : CGRect(origin: compactOrigin ?? CGPoint(x: (bounds.width - compactSize.width) / 2, y: bounds.height - compactSize.height), size: compactSize)
        let target = Self.path(in: rect, bottomRadius: expanded ? 27 : 10, roundedTop: floating)
        let previous = revealMask.presentation()?.path ?? revealMask.path ?? target
        let oldOpacity = hosted?.layer?.presentation()?.opacity ?? hosted?.layer?.opacity ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.path = target; border.path = target
        hosted?.layer?.opacity = expanded ? 1 : 0
        revealMask.removeAnimation(forKey: "reveal"); border.removeAnimation(forKey: "reveal")
        hosted?.layer?.removeAnimation(forKey: "revealOpacity")
        if duration > 0 {
            CATransaction.setCompletionBlock(completion)
            let morph = CABasicAnimation(keyPath: "path")
            morph.fromValue = previous; morph.toValue = target; morph.duration = duration
            morph.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.2, 1)
            morph.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
            revealMask.add(morph, forKey: "reveal"); border.add(morph, forKey: "reveal")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = oldOpacity; fade.toValue = expanded ? 1 : 0; fade.duration = duration * 0.75
            fade.timingFunction = morph.timingFunction; fade.preferredFrameRateRange = morph.preferredFrameRateRange
            hosted?.layer?.add(fade, forKey: "revealOpacity")
        }
        CATransaction.commit()
        if duration == 0 { completion() }
    }

    private static func path(in rect: CGRect, bottomRadius: CGFloat, roundedTop: Bool = false) -> CGPath {
        let x = rect.minX, y = rect.minY, right = rect.maxX, top = rect.maxY
        let b = min(bottomRadius, min(rect.width, rect.height) / 2), t = roundedTop ? b : min(2, b), k: CGFloat = 0.5522847498
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x + b, y: y))
        path.addLine(to: CGPoint(x: right - b, y: y))
        path.addCurve(to: CGPoint(x: right, y: y + b), control1: CGPoint(x: right - b + b * k, y: y), control2: CGPoint(x: right, y: y + b - b * k))
        path.addLine(to: CGPoint(x: right, y: top - t))
        path.addCurve(to: CGPoint(x: right - t, y: top), control1: CGPoint(x: right, y: top - t + t * k), control2: CGPoint(x: right - t + t * k, y: top))
        path.addLine(to: CGPoint(x: x + t, y: top))
        path.addCurve(to: CGPoint(x: x, y: top - t), control1: CGPoint(x: x + t - t * k, y: top), control2: CGPoint(x: x, y: top - t + t * k))
        path.addLine(to: CGPoint(x: x, y: y + b))
        path.addCurve(to: CGPoint(x: x + b, y: y), control1: CGPoint(x: x, y: y + b - b * k), control2: CGPoint(x: x + b - b * k, y: y))
        path.closeSubpath()
        return path
    }
}

@MainActor
private final class AnimationFrameMeter: NSObject {
    private var link: CADisplayLink?
    private var stamps: [Double] = []
    private var changedFrames = 0
    private var lastBounds: CGRect?
    private weak var surface: IslandSurface?
    private(set) var report: [String: Any] = ["measured": false]

    func start(screen: NSScreen, fps: Float, surface: IslandSurface) {
        stop(); stamps = []; changedFrames = 0; lastBounds = nil; self.surface = surface
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, fps), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        if let bounds = surface?.presentationBounds, bounds != lastBounds { changedFrames += 1; lastBounds = bounds }
    }

    func stop() {
        link?.invalidate(); link = nil
        guard stamps.count >= 3 else { return }
        let intervals = zip(stamps, stamps.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        guard let worst = intervals.max(), let first = stamps.first, let last = stamps.last, last > first else { return }
        report = ["measured": true, "callbacks": stamps.count, "changedPresentationFrames": changedFrames,
                  "averageCallbackFPS": Double(stamps.count - 1) / (last - first), "longestFrameIntervalMS": worst * 1000]
    }
}
