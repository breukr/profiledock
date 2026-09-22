import AppKit
import XCTest
import DockCore
@testable import AccountDock

final class NativeProfileArtworkTests: XCTestCase {
    private var profile: Profile {
        var value = Profile(id: "work", name: "Work", color: "FF0000")
        value.dockIconStyle = .image
        return value
    }

    @MainActor func testSquareImageFillsRoundedTileWithoutColoredInset() throws {
        let source = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { bounds in
            NSColor.white.setFill(); bounds.fill(); return true
        }
        let preview = NativeProfileArtwork.preview(profile: profile, image: source, vendor: nil, size: 100)
        try assertFilledTile(raster(preview))
        let exported = try XCTUnwrap(NSImage(data: NativeDockApp.icon(profile: profile, image: source)))
        try assertFilledTile(raster(exported))
    }

    @MainActor func testWideAndTallImagesCropCentrallyWithoutStretchingOrLetterboxing() throws {
        for size in [NSSize(width: 200, height: 100), NSSize(width: 100, height: 200)] {
            let source = NSImage(size: size, flipped: false) { bounds in
                NSColor.red.setFill(); bounds.fill()
                NSColor.white.setFill()
                NSRect(x: (size.width - 100) / 2, y: (size.height - 100) / 2, width: 100, height: 100).fill()
                NSColor.blue.setFill()
                NSRect(x: size.width / 2 - 10, y: size.height / 2 - 10, width: 20, height: 20).fill()
                return true
            }
            let bitmap = try raster(NativeProfileArtwork.preview(profile: profile, image: source, vendor: nil, size: 100))
            try assertFilledTile(bitmap)
            // The central square stays square when either source dimension is cropped.
            for (x, y) in [(44, 50), (56, 50), (50, 44), (50, 56)] {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                XCTAssertGreaterThan(color.blueComponent, 0.95)
                XCTAssertLessThan(color.redComponent, 0.05)
            }
            for (x, y) in [(40, 50), (60, 50), (50, 40), (50, 60)] {
                XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)).redComponent, 0.95)
            }
        }
    }

    @MainActor private func raster(_ image: NSImage) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        image.draw(in: NSRect(x: 0, y: 0, width: 100, height: 100))
        return bitmap
    }

    private func assertFilledTile(_ bitmap: NSBitmapImageRep, file: StaticString = #filePath, line: UInt = #line) throws {
        for (x, y) in [(12, 50), (87, 50), (50, 12), (50, 87)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.greenComponent, 0.95, "Image reaches the rounded tile edge", file: file, line: line)
            XCTAssertGreaterThan(color.alphaComponent, 0.95, file: file, line: line)
        }
        for (x, y) in [(5, 50), (95, 50), (50, 5), (50, 95), (11, 11), (88, 88)] {
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0.05,
                              "Native margins and rounded corners stay transparent", file: file, line: line)
        }
    }
}
