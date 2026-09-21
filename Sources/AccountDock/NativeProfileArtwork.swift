import AppKit
import DockCore

@MainActor enum NativeProfileArtwork {
    static func preview(profile: Profile, image: NSImage?, vendor: NSImage?, size: CGFloat = 96) -> NSImage {
        let result = NSImage(size: NSSize(width: size, height: size))
        result.lockFocus()
        draw(profile: profile, image: image, vendor: vendor, dimension: size)
        result.unlockFocus()
        return result
    }

    static func draw(profile: Profile, image: NSImage?, vendor: NSImage?, dimension d: CGFloat) {
        let tile = NSRect(x: d * 0.1, y: d * 0.1, width: d * 0.8, height: d * 0.8)
        let color = NSColor(hex: profile.color)
        let shape = NSBezierPath(roundedRect: tile, xRadius: d * 0.2, yRadius: d * 0.2)
        switch profile.dockIconStyle ?? .initials {
        case .dot:
            if let vendor { vendor.draw(in: NSRect(x: 0, y: 0, width: d, height: d)) }
            else { NSColor.white.setFill(); shape.fill(); initials(profile, dimension: d, color: .black) }
            let dot = NSRect(x: d * 0.66, y: d * 0.08, width: d * 0.27, height: d * 0.27)
            NSColor.white.setFill(); NSBezierPath(ovalIn: dot.insetBy(dx: -d * 0.025, dy: -d * 0.025)).fill()
            color.setFill(); NSBezierPath(ovalIn: dot).fill()
        case .initials:
            color.setFill(); shape.fill(); initials(profile, dimension: d, color: .white)
        case .image:
            color.setFill(); shape.fill()
            if let image {
                NSGraphicsContext.saveGraphicsState(); shape.addClip()
                fit(image, in: tile.insetBy(dx: d * 0.04, dy: d * 0.04))
                NSGraphicsContext.restoreGraphicsState()
            } else { initials(profile, dimension: d, color: .white) }
        case .chatgpt:
            color.setFill(); shape.fill()
            // Extract the monochrome knot from the installed vendor artwork,
            // ignoring its outer tile. No redistributed third-party bitmap.
            if let vendor, let mark = logoMask(vendor) { fit(mark, in: tile.insetBy(dx: d * 0.13, dy: d * 0.13)) }
            else { initials(profile, dimension: d, color: .white) }
        }
    }

    private static func fit(_ image: NSImage, in rect: NSRect) {
        let factor = min(rect.width / max(1, image.size.width), rect.height / max(1, image.size.height))
        let size = NSSize(width: image.size.width * factor, height: image.size.height * factor)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    private static func initials(_ profile: Profile, dimension d: CGFloat, color: NSColor) {
        let text = NSAttributedString(string: profile.dockLetters, attributes: [.font: NSFont.systemFont(ofSize: d * 0.34, weight: .semibold), .foregroundColor: color])
        text.draw(at: NSPoint(x: (d - text.size().width) / 2, y: (d - text.size().height) / 2))
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
