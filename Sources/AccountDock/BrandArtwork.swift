import AppKit
import SwiftUI

enum BrandArtwork {
    struct Mark: Decodable {
        let size: Double
        let tiles: [Tile]
        struct Tile: Decodable { let x, y, size, radius: Double }
    }
    private static let mark: Mark? = {
        guard let url = Bundle.main.url(forResource: "mark", withExtension: "json", subdirectory: "Brand"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Mark.self, from: data)
    }()

    static func template(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            NSColor.black.setFill()
            if let mark {
                for tile in mark.tiles {
                    // Crop to the four-tile glyph, without the app icon's background padding.
                    let factor = rect.width / 64
                    NSBezierPath(roundedRect: NSRect(x: (tile.x - 20) * factor, y: (tile.y - 22) * factor, width: tile.size * factor, height: tile.size * factor), xRadius: tile.radius * factor, yRadius: tile.radius * factor).fill()
                }
            } else {
                for y in [0.0, 0.5625] { for x in [0.0, 0.5625] {
                    NSBezierPath(roundedRect: NSRect(x: x * size, y: y * size, width: size * 0.4375, height: size * 0.4375), xRadius: size * 0.125, yRadius: size * 0.125).fill()
                } }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ProfileDock"
        return image
    }
}

struct BrandMark: View {
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: BrandArtwork.template(size: size)).renderingMode(.template)
            .resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityLabel("ProfileDock")
    }
}
