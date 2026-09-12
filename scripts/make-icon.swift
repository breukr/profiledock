import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
struct Mark: Decodable {
    struct Tile: Decodable { let x, y, size, radius: Double; let dark: String }
    let size, radius: Double
    let darkBackground: String
    let tiles: [Tile]
}
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Brand/mark.json")
let mark = try JSONDecoder().decode(Mark.self, from: Data(contentsOf: source))
func color(_ hex: String) -> NSColor {
    let value = UInt32(hex, radix: 16)!
    return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
}
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let dimension = CGFloat(pixels)
        let factor = dimension * 0.88 / mark.size, padding = dimension * 0.06
        color(mark.darkBackground).setFill()
        NSBezierPath(roundedRect: NSRect(x: padding, y: padding, width: dimension * 0.88, height: dimension * 0.88), xRadius: mark.radius * factor, yRadius: mark.radius * factor).fill()
        for tile in mark.tiles {
            color(tile.dark).setFill()
            let rect = NSRect(x: padding + tile.x * factor, y: padding + (mark.size - tile.y - tile.size) * factor, width: tile.size * factor, height: tile.size * factor)
            NSBezierPath(roundedRect: rect, xRadius: tile.radius * factor, yRadius: tile.radius * factor).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(multiplier == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
