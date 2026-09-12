import XCTest
import SwiftUI
import DockCore
@testable import AccountDock

final class UsageTintTests: XCTestCase {
    func testEveryPercentageStepStaysGradualIncludingFormerThresholds() {
        for percent in 1...100 {
            let previous = UsageTint.remaining(Double(percent - 1))
            let current = UsageTint.remaining(Double(percent))
            XCTAssertLessThan(abs(current.red - previous.red), 0.05)
            XCTAssertLessThan(abs(current.green - previous.green), 0.05)
            XCTAssertLessThan(abs(current.blue - previous.blue), 0.05)
            XCTAssertGreaterThanOrEqual(current.green, previous.green)
        }
        let full = UsageTint.remaining(100), empty = UsageTint.remaining(0)
        XCTAssertGreaterThan(full.green, full.red)
        XCTAssertGreaterThan(empty.red, empty.green)
    }

    @MainActor func testRenderUsageColorScale() throws {
        guard let directory = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_USAGE"] else {
            throw XCTSkip("Set PROFILEDOCK_RENDER_USAGE to render the native usage preview")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for width in [132.0, 180.0, 240.0] {
            let view = VStack(spacing: 16) {
                ForEach([100, 60, 45, 30, 25, 20, 15, 10, 0], id: \.self) { remaining in
                    UsageWindowView(window: UsageWindow(id: "preview", duration: 604800,
                        usedPercent: Double(100 - remaining), resetsAt: now.addingTimeInterval(86400)), now: now)
                }
            }.padding(16).frame(width: width + 32).background(.black).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
            let destination = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("usage-\(Int(width)).png"))
        }
    }
}
