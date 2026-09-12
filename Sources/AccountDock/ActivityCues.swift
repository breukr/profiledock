import AppKit
import QuartzCore
import DockCore

/// One connected notice per display; sounds play once across all displays.
@MainActor
final class ActivityCues {
    private var panels: [(NSPanel, ActivityCueSurface)] = []
    private var hide: DispatchWorkItem?
    private var removal: DispatchWorkItem?
    private var pending = ActivityCueBatch()
    private var delivery: Task<Void, Never>?
    private var recent: [String: Date] = [:]
    private var sound: NSSound?
    private var lastSound = Date.distantPast
    private var generation = 0
    private static let visibleDuration = 3.2

    func receive(_ event: ActivityEvent, model: DockModel) {
        guard model.preferences.profiles.contains(where: { $0.id == event.profileID }) else { return }
        let key = event.profileID + ":" + event.signal.rawValue
        let now = Date()
        guard now.timeIntervalSince(recent[key] ?? .distantPast) >= 5 else { return }
        recent = recent.filter { now.timeIntervalSince($0.value) < 60 }
        recent[key] = now
        pending.insert(event)
        guard delivery == nil else { return }
        delivery = Task { [weak self, weak model] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let model else { return }
            while !Task.isCancelled {
                guard let notice = self.pending.next() else { break }
                let profiles = model.preferences.profiles.filter { notice.profileIDs.contains($0.id) }
                guard !profiles.isEmpty else { continue }
                self.show(notice.signal, profiles: profiles, model: model, preview: false)
                try? await Task.sleep(for: .seconds(Self.visibleDuration + ActivityCueSurface.closeDuration + 0.1))
            }
            if !Task.isCancelled { self.delivery = nil }
        }
    }

    func present(_ signal: ActivitySignal, model: DockModel, preview: Bool = false) {
        dismiss()
        let profile = model.preferences.profiles.first(where: { $0.id == model.activeProfile }) ?? model.preferences.profiles.first
        show(signal, profiles: profile.map { [$0] } ?? [], model: model, preview: preview)
    }

    private func show(_ signal: ActivitySignal, profiles: [Profile], model: DockModel, preview: Bool) {
        clearPanels()
        let names = profiles.map { profile in
            let name = profile.name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return name.isEmpty ? "Unnamed profile" : name
        }
        let firstName = names.first ?? "Your environment"
        let label = names.count > 1 ? "\(firstName) +\(names.count - 1)" : firstName
        let fullLabel = names.isEmpty ? firstName : names.joined(separator: ", ")
        if preview || model.preferences.activityCues != false {
            let width = min(180, max(96, (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width + 8))
            for screen in NSScreen.screens {
                let island = IslandController.layout(screen: screen, model: model)
                let floating = model.placement != .topCenter
                let geometry = ActivityCueLayout(screen: floating ? screen.visibleFrame : screen.frame, obstacle: island.collapsed, floating: floating, statusWidth: signal == .needsInput ? 104 : 78, nameWidth: width)
                // Small margins accommodate the spring's restrained overshoot without resizing a window per frame.
                let panelFrame = geometry.frame.insetBy(dx: -6, dy: 0).intersection(screen.frame)
                let panel = NSPanel(contentRect: panelFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "ProfileDock: \(signal == .needsInput ? "input needed" : "done") · \(fullLabel)"
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
                panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
                let surface = ActivityCueSurface(frame: CGRect(origin: .zero, size: panelFrame.size), geometry: geometry, panelOrigin: panelFrame.origin, signal: signal, name: label, fullName: fullLabel, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                panel.contentView = surface
                panel.orderFrontRegardless()
                surface.reveal(expanded: true)
                panels.append((panel, surface))
            }
            let current = generation
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.generation == current else { return }
                self.panels.forEach { $0.1.reveal(expanded: false) }
                let removal = DispatchWorkItem { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.clearPanels()
                }
                self.removal = removal
                DispatchQueue.main.asyncAfter(deadline: .now() + ActivityCueSurface.closeDuration, execute: removal)
            }
            hide = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: item)
        }
        if model.preferences.activitySounds == true, preview || Date().timeIntervalSince(lastSound) >= 2 {
            sound?.stop()
            if let url = Bundle.main.url(forResource: signal.rawValue, withExtension: "wav", subdirectory: "Sounds"), let next = NSSound(contentsOf: url, byReference: true) {
                next.volume = Float(min(0.5, max(0, model.preferences.activitySoundVolume ?? 0.18)))
                sound = next; lastSound = Date(); next.play()
            }
        }
    }

    private func clearPanels() {
        generation += 1
        hide?.cancel(); hide = nil; removal?.cancel(); removal = nil
        panels.forEach { $0.0.close() }; panels.removeAll()
    }
    func dismiss() { delivery?.cancel(); delivery = nil; pending = ActivityCueBatch(); clearPanels() }
    func shutdown() { dismiss(); sound?.stop() }
    var visiblePanelCount: Int { panels.count }
}

/// Native layer geometry animates while the window and text layout remain fixed.
@MainActor
final class ActivityCueSurface: NSView {
    static let openDuration = 0.55
    static let closeDuration = 0.4
    let collapsedRect: CGRect
    let expandedRect: CGRect
    let statusText: String
    let environmentText: String
    private let reduceMotion: Bool
    private let clip = CALayer()
    private let edge = CALayer()
    private let content = NSView()

    init(frame: CGRect, geometry: ActivityCueLayout, panelOrigin: CGPoint, signal: ActivitySignal, name: String, fullName: String, reduceMotion: Bool) {
        collapsedRect = geometry.origin.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
        expandedRect = geometry.frame.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
        statusText = signal == .needsInput ? "Needs you" : "Done"
        environmentText = name
        self.reduceMotion = reduceMotion
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        clip.backgroundColor = NSColor.black.cgColor
        clip.cornerRadius = min(16, geometry.frame.height / 2)
        layer?.mask = clip
        edge.cornerRadius = clip.cornerRadius
        edge.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        edge.borderWidth = 0.7
        content.frame = bounds; content.wantsLayer = true
        addSubview(content)
        layer?.addSublayer(edge)
        let left = geometry.left.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
        let right = geometry.right.offsetBy(dx: -panelOrigin.x, dy: -panelOrigin.y)
        let symbol = NSImageView(frame: CGRect(x: left.minX, y: left.midY - 7, width: 14, height: 14))
        symbol.image = NSImage(systemSymbolName: signal == .needsInput ? "hand.raised.fill" : "checkmark", accessibilityDescription: nil)
        symbol.contentTintColor = signal == .needsInput ? .systemOrange : .systemGreen
        content.addSubview(symbol)
        let status = Self.label(statusText, frame: CGRect(x: left.minX + 20, y: left.midY - 8, width: max(0, left.width - 20), height: 16), weight: .semibold)
        status.textColor = symbol.contentTintColor
        content.addSubview(status)
        let environment = Self.label(name, frame: CGRect(x: right.minX, y: right.midY - 8, width: right.width, height: 16), weight: .medium)
        environment.alignment = .right
        environment.toolTip = fullName
        content.addSubview(environment)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(statusText): \(fullName)")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        setGeometry(reduceMotion ? expandedRect : collapsedRect)
        content.layer?.opacity = 0
        layer?.opacity = 0
        CATransaction.commit()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func label(_ text: String, frame: CGRect, weight: NSFont.Weight) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame; field.font = .systemFont(ofSize: 12, weight: weight)
        field.textColor = .white; field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        return field
    }
    private func setGeometry(_ rect: CGRect) {
        for shape in [clip, edge] {
            shape.bounds = CGRect(origin: .zero, size: rect.size)
            shape.position = CGPoint(x: rect.midX, y: rect.midY)
        }
    }
    func reveal(expanded: Bool) {
        let target = expanded || reduceMotion ? expandedRect : collapsedRect
        let duration = expanded ? Self.openDuration : Self.closeDuration
        let previousBounds = clip.presentation()?.bounds ?? clip.bounds
        let previousPosition = clip.presentation()?.position ?? clip.position
        CATransaction.begin(); CATransaction.setDisableActions(true)
        setGeometry(target)
        content.layer?.opacity = expanded ? 1 : 0
        layer?.opacity = expanded ? 1 : 0
        CATransaction.commit()
        if !reduceMotion {
            for shape in [clip, edge] {
                for (key, from, to) in [("bounds", NSValue(rect: previousBounds), NSValue(rect: shape.bounds)), ("position", NSValue(point: previousPosition), NSValue(point: shape.position))] {
                    let spring = CASpringAnimation(keyPath: key)
                    spring.fromValue = from; spring.toValue = to
                    spring.mass = 1; spring.stiffness = expanded ? 360 : 480; spring.damping = expanded ? 32 : 40
                    spring.initialVelocity = 0; spring.duration = duration
                    spring.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                    shape.add(spring, forKey: "morph-\(key)")
                }
            }
        }
        fade(content.layer, from: expanded ? 0 : 1, to: expanded ? 1 : 0, duration: expanded ? 0.22 : 0.12, delay: expanded && !reduceMotion ? 0.1 : 0)
        fade(layer, from: expanded ? 0 : 1, to: expanded ? 1 : 0, duration: reduceMotion ? 0.16 : 0.12, delay: expanded ? 0 : (reduceMotion ? 0 : duration - 0.12))
    }
    private func fade(_ layer: CALayer?, from: Float, to: Float, duration: Double, delay: Double) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.beginTime = CACurrentMediaTime() + delay
        animation.fillMode = .backwards
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "notice-opacity")
    }
    var hasGeometryAnimation: Bool { clip.animation(forKey: "morph-bounds") != nil }
    var targetGeometry: CGRect { CGRect(x: clip.position.x - clip.bounds.width / 2, y: clip.position.y - clip.bounds.height / 2, width: clip.bounds.width, height: clip.bounds.height) }
}
