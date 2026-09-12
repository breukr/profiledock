import AppKit
import SwiftUI
import QuartzCore

struct IconPulse: NSViewRepresentable {
    let working: Bool
    let visible: Bool
    let reduceMotion: Bool
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> IconPulseSurface { IconPulseSurface() }
    func updateNSView(_ view: IconPulseSurface, context: Context) {
        view.configure(working: working, visible: visible, reduceMotion: reduceMotion, cornerRadius: cornerRadius)
    }
}

/// Composited full-icon outline and glow. No per-frame SwiftUI updates or idle timers.
final class IconPulseSurface: NSView {
    private(set) var outline = CAShapeLayer()
    private var cornerRadius: CGFloat = 14
    private var animated = false
    private var working = false
    private var visible = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        outline.fillColor = NSColor.clear.cgColor
        outline.strokeColor = NSColor(srgbRed: 0.3, green: 0.65, blue: 1, alpha: 1).cgColor
        outline.lineWidth = 3
        outline.shadowColor = NSColor(srgbRed: 0.12, green: 0.5, blue: 1, alpha: 1).cgColor
        outline.shadowRadius = 6
        outline.shadowOpacity = 0.85
        outline.shadowOffset = .zero
        outline.opacity = 0
        layer?.addSublayer(outline)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.frame = bounds
        let shape = CGPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), cornerWidth: cornerRadius + 3, cornerHeight: cornerRadius + 3, transform: nil)
        outline.path = shape; outline.shadowPath = shape
        CATransaction.commit()
    }

    func configure(working: Bool, visible: Bool, reduceMotion: Bool, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        self.working = working; self.visible = visible
        needsLayout = true
        let shouldAnimate = working && visible && !reduceMotion
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.opacity = working && visible ? 0.8 : 0
        CATransaction.commit()
        guard shouldAnimate != animated else { return }
        animated = shouldAnimate
        outline.removeAllAnimations()
        guard shouldAnimate else { return }
        let brightness = CABasicAnimation(keyPath: "opacity")
        brightness.fromValue = 0.25; brightness.toValue = 1
        let expansion = CABasicAnimation(keyPath: "transform.scale")
        expansion.fromValue = 0.985; expansion.toValue = 1.07
        let animation = CAAnimationGroup()
        animation.animations = [brightness, expansion]
        animation.duration = 0.85; animation.autoreverses = true; animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        outline.add(animation, forKey: "workingPulse")
    }
}
