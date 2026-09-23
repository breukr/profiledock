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
    init(model: DockModel, profileID: String, window: NSWindow) {
        self.model = model; self.profileID = profileID; self.window = window
        model.draggingProfileID = profileID
        NSCursor.closedHand.push()
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
        let next = ProfileDropTarget.Target.targets.allObjects.first { target in
            guard target.model === model, target.window === window, !target.isHiddenOrHasHiddenAncestor else { return false }
            let local = target.convert(window.convertPoint(fromScreen: point), from: nil)
            return target.bounds.intersection(target.visibleRect).contains(local)
        }
        guard next !== hovered else { return }
        hovered?.highlight?(false); hovered = next
        next?.highlight?(true); next?.entered?()
    }
    func finish(commit: Bool) {
        guard active else { return }; active = false
        let target = hovered?.target
        hovered?.highlight?(false); hovered = nil
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        NSCursor.pop()
        model.draggingProfileID = nil
        if commit, let target { model.move(profileID, to: target) }
    }
}

struct ReorderableProfile: ViewModifier {
    @ObservedObject var model: DockModel
    let profile: Profile
    var handle = true
    @State private var targeted = false
    func body(content: Content) -> some View {
        content.overlay { ProfileDropTarget(model: model, target: profile.id, targeted: $targeted) }
        .overlay(alignment: .topLeading) {
            if handle { ProfileDragHandle(model: model, profile: profile).frame(width: 18, height: 22).padding(3) }
        }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(targeted && model.draggingProfileID != nil ? Color.accentColor : .clear, lineWidth: 2).allowsHitTesting(false))
        .accessibilityAction(named: "Move earlier") { model.move(profile.id, by: -1) }
        .accessibilityAction(named: "Move later") { model.move(profile.id, by: 1) }
    }
}

struct ProfileDropTarget: NSViewRepresentable {
    let model: DockModel
    var target: String? = nil
    var entered: (() -> Void)? = nil
    @Binding var targeted: Bool
    func makeNSView(context: Context) -> Target { Target() }
    func updateNSView(_ view: Target, context: Context) {
        view.model = model; view.target = target; view.entered = entered; view.highlight = { targeted = $0 }
    }
    final class Target: NSView {
        static let targets = NSHashTable<Target>.weakObjects()
        weak var model: DockModel?
        var target: String?
        var entered: (() -> Void)?
        var highlight: ((Bool) -> Void)?
        override init(frame frameRect: NSRect) { super.init(frame: frameRect); Self.targets.add(self) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
