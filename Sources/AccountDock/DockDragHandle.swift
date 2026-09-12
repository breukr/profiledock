import AppKit
import SwiftUI

enum DockDragPhase { case began, moved, ended }

struct DockDragHandle: NSViewRepresentable {
    let drag: (DockDragPhase, CGPoint) -> Void
    func makeNSView(context: Context) -> GripView { GripView(drag: drag) }
    func updateNSView(_ view: GripView, context: Context) { view.drag = drag }

    final class GripView: NSView {
        var drag: (DockDragPhase, CGPoint) -> Void
        private var held = false
        init(drag: @escaping (DockDragPhase, CGPoint) -> Void) {
            self.drag = drag
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.handle)
            setAccessibilityLabel("Move ProfileDock")
            setAccessibilityHelp("Drag to position the strip on this display. Reset its position in Appearance settings.")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.55).setFill()
            for x in [-2.5, 2.5] {
                for y in [-5.0, 0, 5] {
                    NSBezierPath(ovalIn: NSRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2)).fill()
                }
            }
        }
        override func mouseDown(with event: NSEvent) { held = true; NSCursor.closedHand.push(); drag(.began, NSEvent.mouseLocation) }
        override func mouseDragged(with event: NSEvent) { if held { drag(.moved, NSEvent.mouseLocation) } }
        override func mouseUp(with event: NSEvent) { if held { held = false; NSCursor.pop(); drag(.ended, NSEvent.mouseLocation) } }
    }
}
