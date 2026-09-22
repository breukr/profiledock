import AppKit
import DockCore

@MainActor enum NativeProfileArtwork {
    static func preview(profile: Profile, image: NSImage?, vendor: NSImage?, size: CGFloat = 96, margin: CGFloat = 0.1) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        draw(profile: profile, image: image, vendor: vendor, dimension: size, margin: margin)
        result.unlockFocus()
        return result
    }

    static func draw(profile: Profile, image: NSImage?, vendor: NSImage?, dimension d: CGFloat, margin: CGFloat = 0.1) {
        let tile = NSRect(x: d * margin, y: d * margin, width: d * (1 - 2 * margin), height: d * (1 - 2 * margin))
        let color = NSColor(hex: profile.color)
        let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.25, yRadius: tile.width * 0.25)
        switch profile.profileIconStyle {
        case .dot:
            if let vendor { vendor.draw(in: NSRect(x: 0, y: 0, width: d, height: d)) }
            else { NSColor.white.setFill(); shape.fill(); initials(profile, in: tile, color: .black) }
            let dot = NSRect(x: d * 0.66, y: d * 0.08, width: d * 0.27, height: d * 0.27)
            NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -d * 0.025, dy: -d * 0.025)).fill()
            color.setFill(); NSBezierPath(ovalIn: dot).fill()
        case .initials:
            color.setFill(); shape.fill(); initials(profile, in: tile, color: .white)
        case .image:
            color.setFill(); shape.fill()
            if let image {
                NSGraphicsContext.saveGraphicsState(); shape.addClip()
                fill(image, in: tile)
                NSGraphicsContext.restoreGraphicsState()
            } else { initials(profile, in: tile, color: .white) }
        case .chatgpt:
            color.setFill(); shape.fill()
            // Extract the monochrome knot from the installed vendor artwork,
            // ignoring its outer tile. No redistributed third-party bitmap.
            if let vendor, let mark = logoMask(vendor) { fit(mark, in: tile.insetBy(dx: tile.width * 0.1625, dy: tile.width * 0.1625)) }
            else { initials(profile, in: tile, color: .white) }
        }
    }

    private static func fit(_ image: NSImage, in rect: NSRect) {
        let factor = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    /// Crop from the center, preserving the image's proportions and the native outer margin.
    private static func fill(_ image: NSImage, in rect: NSRect) {
        let factor = max(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private static func initials(_ profile: Profile, in tile: NSRect, color: NSColor) {
        let text = NSAttributedString(string: profile.dockLetters, attributes: [.font: NSFont.systemFont(ofSize: tile.width * 0.425, weight: .semibold), .foregroundColor: color])
        text.draw(at: NSPoint(x: tile.midX - text.size().width / 2, y: tile.midY - text.size().height / 2))
    }

    private static func logoMask(_ vendor: NSImage) -> NSImage? {
        var proposed = NSRect(x: 0, y: 0, width: 256, height: 256)
        guard let source = vendor.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        let side = 128
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The central 60% includes the knot and flat tile background, but
            // excludes the rounded outer corners and their transparent pixels.
            context.draw(source, in: CGRect(x: -42.67, y: -42.67, width: 213.34, height: 213.34))
            return true
        }
        guard rendered else { return nil }
        func light(_ offset: Int) -> Double { (Double(rgba[offset]) + Double(rgba[offset + 1]) + Double(rgba[offset + 2])) / 765 }
        let background = [0, (side - 1) * 4, (side - 1) * side * 4, (side * side - 1) * 4].map(light).reduce(0, +) / 4
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = UInt8(min(255, max(0, abs(light(offset) - background) * 1.6 * 255)))
            rgba[offset] = alpha; rgba[offset + 1] = alpha; rgba[offset + 2] = alpha; rgba[offset + 3] = alpha
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let mask = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: mask, size: NSSize(width: side, height: side))
    }
}
