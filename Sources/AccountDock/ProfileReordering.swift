import AppKit
import SwiftUI
import DockCore

/// Local pointer tracking also works in the notch's nonactivating panels.
struct ProfileDragHandle: NSViewRepresentable {
    let model: DockModel
    let profile: Profile
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.model = model; view.profile = profile
        view.toolTip = "Drag to reorder \(profile.name)"
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Drag to reorder \(profile.name). Move commands are also available in the menu.")
    }
    final class Handle: NSView {
        weak var model: DockModel?
        var profile: Profile?
        private var start: NSPoint?
        private var session: ProfileDragSession?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setFill()
            for x in [5.0, 10.0] { for y in [5.0, 10.0, 15.0] { NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2, height: 2)).fill() } }
        }
        override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) {
            guard let start, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) >= 3,
                  let model, let profile, let window else { return }
            self.start = nil
            session = ProfileDragSession(model: model, profileID: profile.id, window: window)
            session?.move(to: window.convertPoint(toScreen: event.locationInWindow))
        }
        override func mouseUp(with event: NSEvent) { start = nil }
    }
}

@MainActor final class ProfileDragSession {
    private let model: DockModel
    private let profileID: String
    private weak var window: NSWindow?
    private weak var hovered: ProfileDropTarget.Target?
    private var monitor: Any?
    private var active = true
    private var preview: NSPanel?
    private var previewLabel: NSTextField?
    init(model: DockModel, profileID: String, window: NSWindow) {
        self.model = model; self.profileID = profileID; self.window = window
        model.draggingProfileID = profileID
        NSCursor.closedHand.push()
        if window.isVisible, let profile = model.preferences.profiles.first(where: { $0.id == profileID }) {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 66), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true; panel.hasShadow = true
            let surface = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 66))
            surface.material = .popover; surface.state = .active; surface.wantsLayer = true
            surface.layer?.cornerRadius = 14; surface.layer?.borderWidth = 1.5
            surface.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.65).cgColor
            let icon = NSImageView(frame: NSRect(x: 12, y: 13, width: 40, height: 40)); icon.image = model.artwork(for: profile)
            let name = NSTextField(labelWithString: profile.name); name.font = .systemFont(ofSize: 13, weight: .semibold)
            name.frame = NSRect(x: 62, y: 34, width: 146, height: 19); name.lineBreakMode = .byTruncatingTail
            let hint = NSTextField(labelWithString: "Drag to a new position"); hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
            hint.frame = NSRect(x: 62, y: 14, width: 146, height: 16); hint.lineBreakMode = .byTruncatingTail
            surface.addSubview(icon); surface.addSubview(name); surface.addSubview(hint)
            panel.contentView = surface; preview = panel; previewLabel = hint
            window.addChildWindow(panel, ordered: .above)
        }
        // The monitor retains this short-lived session if pagination removes the source view.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp, .keyDown]) { [self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 { finish(commit: false); return nil }
                if event.modifierFlags.contains(.command) { finish(commit: false) }
                return event
            }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            move(to: point)
            if event.type == .leftMouseUp { finish(commit: true) }
            return nil
        }
    }
    func move(to point: NSPoint) {
        guard active, let window else { finish(commit: false); return }
        if let preview {
            let visible = NSScreen.screens.first(where: { $0.frame.contains(point) })?.visibleFrame ?? window.screen?.visibleFrame ?? window.frame
            preview.setFrameOrigin(NSPoint(x: min(max(visible.minX, point.x + 18), visible.maxX - preview.frame.width), y: min(max(visible.minY, point.y - 76), visible.maxY - preview.frame.height)))
        }
        let next = ProfileDropTarget.Target.targets.allObjects.first { target in
            guard target.model === model, target.window === window, !target.isHiddenOrHasHiddenAncestor else { return false }
            if let terminalGroup = target.terminalGroup,
               model.preferences.profiles.first(where: { $0.id == profileID })?.kind.usesTerminal != terminalGroup { return false }
            let local = target.convert(window.convertPoint(fromScreen: point), from: nil)
            return target.bounds.intersection(target.visibleRect).contains(local)
        }
        guard next !== hovered else { return }
        hovered?.highlight?(false); hovered = next
        next?.highlight?(true); next?.entered?()
        if let target = next?.target, target != profileID,
           let from = model.preferences.profiles.firstIndex(where: { $0.id == profileID }),
           let to = model.preferences.profiles.firstIndex(where: { $0.id == target }) {
            previewLabel?.stringValue = "Move \(from < to ? "after" : "before") \(model.preferences.profiles[to].name)"
        } else { previewLabel?.stringValue = "Release to keep position" }
    }
    func finish(commit: Bool) {
        guard active else { return }; active = false
        let target = hovered?.target
        hovered?.highlight?(false); hovered = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let preview { window?.removeChildWindow(preview); preview.close() }
        preview = nil; previewLabel = nil
        NSCursor.pop()
        model.draggingProfileID = nil
        if commit, let target {
            withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .snappy(duration: 0.25)) { model.move(profileID, to: target) }
        }
    }
}

struct ReorderableProfile: ViewModifier {
    @ObservedObject var model: DockModel
    let profile: Profile
    var handle = true
    var displayedOnly = false
    @State private var targeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        let dragging = model.draggingProfileID == profile.id
        let receiving = targeted && model.draggingProfileID != nil && !dragging
        let sourceIndex = model.preferences.profiles.firstIndex { $0.id == model.draggingProfileID } ?? 0
        let targetIndex = model.preferences.profiles.firstIndex { $0.id == profile.id } ?? 0
        content
        .opacity(dragging ? 0.3 : 1)
        .scaleEffect(dragging && !reduceMotion ? 0.96 : 1)
        .background(RoundedRectangle(cornerRadius: 12).fill(receiving ? Color.accentColor.opacity(0.12) : .clear))
        .overlay { ProfileDropTarget(model: model, target: profile.id, terminalGroup: displayedOnly ? profile.kind.usesTerminal : nil, targeted: $targeted) }
        .overlay(alignment: .topLeading) {
            if handle { ProfileDragHandle(model: model, profile: profile).frame(width: 18, height: 22).padding(3) }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(receiving ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 2).allowsHitTesting(false))
        .overlay(alignment: displayedOnly ? (sourceIndex < targetIndex ? .trailing : .leading) : (sourceIndex < targetIndex ? .bottom : .top)) {
            if receiving {
                Capsule().fill(Color.accentColor)
                    .frame(width: displayedOnly ? 4 : nil, height: displayedOnly ? nil : 4)
                    .padding(displayedOnly ? .vertical : .horizontal, 8)
                    .shadow(color: Color.accentColor.opacity(0.5), radius: 4).allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: dragging)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: receiving)
        .accessibilityAction(named: "Move earlier") { if displayedOnly { model.moveDisplayed(profile.id, by: -1) } else { model.move(profile.id, by: -1) } }
        .accessibilityAction(named: "Move later") { if displayedOnly { model.moveDisplayed(profile.id, by: 1) } else { model.move(profile.id, by: 1) } }
    }
}

struct ProfileDropTarget: NSViewRepresentable {
    let model: DockModel
    var target: String? = nil
    var terminalGroup: Bool? = nil
    var entered: (() -> Void)? = nil
    @Binding var targeted: Bool
    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) {
        view.model = model; view.target = target; view.terminalGroup = terminalGroup; view.entered = entered; view.highlight = { targeted = $0 }
    }
    final class Target: NSView {
        static let targets = NSHashTable<Target>.weakObjects()
        weak var model: DockModel?
        var target: String?
        var terminalGroup: Bool?
        var entered: (() -> Void)?
        var highlight: ((Bool) -> Void)?
        override init(frame frameRect: NSRect) { super.init(frame: frameRect); Self.targets.add(self) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
