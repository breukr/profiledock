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

private enum WorkingPulseMotion {
    static func animation(opacity: (Float, Float), scale: (Double, Double)) -> CAAnimationGroup {
        let brightness = CABasicAnimation(keyPath: "opacity")
        brightness.fromValue = opacity.0; brightness.toValue = opacity.1
        let expansion = CABasicAnimation(keyPath: "transform.scale")
        expansion.fromValue = scale.0; expansion.toValue = scale.1
        let animation = CAAnimationGroup()
        animation.animations = [brightness, expansion]
        animation.duration = 1.05; animation.autoreverses = true; animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        return animation
    }
}

/// A crisp rim, soft blue halo and expanding outer ring; only composited layers move.
final class IconPulseSurface: NSView {
    private(set) var outline = CAShapeLayer()
    private(set) var halo = CAShapeLayer()
    private(set) var outerRing = CAShapeLayer()
    private var cornerRadius: CGFloat = 14
    private var animated = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for shape in [halo, outerRing, outline] {
            shape.fillColor = NSColor.clear.cgColor
            shape.strokeColor = NSColor(srgbRed: 0.24, green: 0.65, blue: 1, alpha: 1).cgColor
            shape.opacity = 0
            layer?.addSublayer(shape)
        }
        halo.lineWidth = 8
        halo.shadowColor = NSColor(srgbRed: 0.12, green: 0.5, blue: 1, alpha: 1).cgColor
        halo.shadowRadius = 9; halo.shadowOpacity = 0.8; halo.shadowOffset = .zero
        outline.lineWidth = 1.8
        outline.strokeColor = NSColor(srgbRed: 0.38, green: 0.76, blue: 1, alpha: 1).cgColor
        outerRing.lineWidth = 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [halo, outline, outerRing] {
            shape.frame = bounds
            let inset: CGFloat = shape === outerRing ? 3 : 7
            let radius = cornerRadius + (shape === outerRing ? 7 : 3)
            let path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), cornerWidth: radius, cornerHeight: radius, transform: nil)
            shape.path = path; shape.shadowPath = path
        }
        CATransaction.commit()
    }

    func configure(working: Bool, visible: Bool, reduceMotion: Bool, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        needsLayout = true
        let active = working && visible
        let shouldAnimate = active && !reduceMotion
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.opacity = active ? 0.95 : 0
        halo.opacity = active ? 0.24 : 0
        outerRing.opacity = active ? 0.4 : 0
        CATransaction.commit()
        guard shouldAnimate != animated else { return }
        animated = shouldAnimate
        [outline, halo, outerRing].forEach { $0.removeAllAnimations() }
        guard shouldAnimate else { return }
        outline.add(WorkingPulseMotion.animation(opacity: (0.7, 1), scale: (1, 1.015)), forKey: "workingPulse")
        halo.add(WorkingPulseMotion.animation(opacity: (0.16, 0.58), scale: (0.98, 1.1)), forKey: "workingPulse")
        outerRing.add(WorkingPulseMotion.animation(opacity: (0.12, 0.75), scale: (0.98, 1.065)), forKey: "workingPulse")
    }
}

struct WorkingDotGlow: NSViewRepresentable {
    let visible: Bool
    let reduceMotion: Bool
    func makeNSView(context: Context) -> WorkingDotGlowSurface { WorkingDotGlowSurface() }
    func updateNSView(_ view: WorkingDotGlowSurface, context: Context) { view.configure(visible: visible, reduceMotion: reduceMotion) }
}

final class WorkingDotGlowSurface: NSView {
    private(set) var halo = CAShapeLayer()
    private var animated = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        halo.fillColor = NSColor(srgbRed: 0.3, green: 0.65, blue: 1, alpha: 1).cgColor
        halo.shadowColor = halo.fillColor
        halo.shadowRadius = 3; halo.shadowOpacity = 0.65; halo.shadowOffset = .zero
        halo.opacity = 0
        layer?.addSublayer(halo)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.frame = bounds
        let rect = bounds.insetBy(dx: 6, dy: 6)
        let path = CGPath(ellipseIn: rect, transform: nil)
        halo.path = path; halo.shadowPath = path
        CATransaction.commit()
    }
    func configure(visible: Bool, reduceMotion: Bool) {
        needsLayout = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        halo.opacity = visible ? 0.35 : 0
        CATransaction.commit()
        let shouldAnimate = visible && !reduceMotion
        guard animated != shouldAnimate else { return }
        animated = shouldAnimate
        halo.removeAllAnimations()
        if shouldAnimate { halo.add(WorkingPulseMotion.animation(opacity: (0.2, 0.6), scale: (1, 1.9)), forKey: "workingPulse") }
    }
}
