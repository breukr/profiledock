import AppKit
import QuartzCore

/// Dark Liquid Glass for the strip (Sam's 2026-11-07 direction): pure black where the strip meets the notch,
/// fading into dark tinted native glass below it. macOS 26+ uses `NSGlassEffectView` (Apple's Liquid Glass);
/// macOS 14 and 15 use a frosted `NSVisualEffectView` (blurred desktop behind the window). With Reduce
/// Transparency on, there is no backdrop at all and the strip stays opaque black, as before 2.0.
///
/// The system glass is composited by the window server, so a CALayer mask (the strip's animated outline) does
/// not clip it. The strip therefore opens and closes as solid black, and the glass fades in only once the
/// outline has settled, sized exactly to it.
@MainActor
enum StripGlass {
    /// Opacity of the black shade over the glass below the notch band. Keeps white 0.55 text readable on a white desktop.
    static let shadeOpacity: CGFloat = 0.66
    /// Height over which the notch band fades into the glass.
    static let fade: CGFloat = 56
    /// Cross-fade from solid black to glass after the strip settles.
    static let fadeIn: CFTimeInterval = 0.22

    static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    /// The blurred backdrop, or nil when Reduce Transparency is on.
    static func backdrop(cornerRadius: CGFloat) -> NSView? {
        guard !reduceTransparency else { return nil }
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            glass.tintColor = NSColor.black.withAlphaComponent(0.3)
            glass.appearance = NSAppearance(named: .darkAqua)
            return glass
        }
        let frost = NSVisualEffectView()
        frost.material = .hudWindow
        frost.blendingMode = .behindWindow
        frost.state = .active
        frost.appearance = NSAppearance(named: .darkAqua)
        frost.wantsLayer = true
        frost.layer?.cornerRadius = cornerRadius
        frost.layer?.masksToBounds = true
        return frost
    }
}

/// Black at the top (the notch band), fading to the glass shade below. Sits between the backdrop and the content.
/// Its own layer is the gradient, so it always matches the view's size.
@MainActor
final class StripShadeView: NSView {
    /// Height of the opaque band at the top, normally the notch height plus a small margin. Zero when floating.
    var band: CGFloat = 0 { didSet { if band != oldValue { updateGradient() } } }
    private var gradient: CAGradientLayer? { layer as? CAGradientLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gradient?.startPoint = CGPoint(x: 0.5, y: 1); gradient?.endPoint = CGPoint(x: 0.5, y: 0)
        updateGradient()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { CAGradientLayer() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateGradient() }

    private func updateGradient() {
        guard let gradient else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let height = max(1, bounds.height)
        let solid = NSColor.black.cgColor, shade = NSColor.black.withAlphaComponent(StripGlass.shadeOpacity).cgColor
        guard band > 0 else { gradient.colors = [shade, shade]; gradient.locations = [0, 1]; return }
        let bandEnd = min(1, band / height), fadeEnd = min(1, (band + StripGlass.fade) / height)
        gradient.colors = [solid, solid, shade, shade]
        gradient.locations = [0, NSNumber(value: Double(bandEnd)), NSNumber(value: Double(fadeEnd)), 1]
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
