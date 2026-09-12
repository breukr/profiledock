import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let pixels = size * multiplier
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let dimension = CGFloat(pixels)
        NSColor(srgbRed: 0.12, green: 0.14, blue: 0.19, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: dimension * 0.06, y: dimension * 0.06, width: dimension * 0.88, height: dimension * 0.88), xRadius: dimension * 0.2, yRadius: dimension * 0.2).fill()
        let colors: [NSColor] = [.systemBlue, .systemOrange, .systemTeal, .systemPurple]
        for index in 0..<4 {
            colors[index].setFill()
            let rect = NSRect(x: dimension * (index % 2 == 0 ? 0.22 : 0.53), y: dimension * (index < 2 ? 0.53 : 0.22), width: dimension * 0.25, height: dimension * 0.25)
            NSBezierPath(roundedRect: rect, xRadius: dimension * 0.065, yRadius: dimension * 0.065).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(multiplier == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
