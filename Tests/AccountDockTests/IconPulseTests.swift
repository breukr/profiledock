import AppKit
import QuartzCore
import XCTest
@testable import AccountDock

final class IconPulseTests: XCTestCase {
    @MainActor func testPulseRunsOnlyForVisibleWorkingAccountsAndRespectsReduceMotion() throws {
        _ = NSApplication.shared
        let pulse = IconPulseSurface(frame: CGRect(x: 0, y: 0, width: 72, height: 72))
        pulse.configure(working: true, visible: true, reduceMotion: false, cornerRadius: 14)
        pulse.layoutSubtreeIfNeeded()
        let animation = try XCTUnwrap(pulse.outline.animation(forKey: "workingPulse") as? CAAnimationGroup)
        XCTAssertEqual(animation.duration, 1.05)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertEqual(animation.preferredFrameRateRange.preferred, 120)
        XCTAssertEqual(animation.animations?.count, 2)
        XCTAssertEqual(pulse.outline.path?.boundingBox.width, 58)
        XCTAssertGreaterThan(pulse.outerRing.path?.boundingBox.width ?? 0, pulse.outline.path?.boundingBox.width ?? 0)
        XCTAssertNotNil(pulse.halo.animation(forKey: "workingPulse"))
        XCTAssertNotNil(pulse.outerRing.animation(forKey: "workingPulse"))
        pulse.configure(working: true, visible: false, reduceMotion: false, cornerRadius: 14)
        XCTAssertNil(pulse.outline.animation(forKey: "workingPulse"))
        XCTAssertEqual(pulse.outline.opacity, 0)
        XCTAssertTrue([pulse.halo, pulse.outerRing].allSatisfy { $0.animationKeys()?.isEmpty != false && $0.opacity == 0 })
        pulse.configure(working: true, visible: true, reduceMotion: true, cornerRadius: 14)
        XCTAssertNil(pulse.outline.animation(forKey: "workingPulse"))
        XCTAssertGreaterThan(pulse.outline.opacity, 0)
        XCTAssertTrue([pulse.halo, pulse.outerRing].allSatisfy { $0.animationKeys()?.isEmpty != false && $0.opacity > 0 })
        pulse.configure(working: false, visible: true, reduceMotion: false, cornerRadius: 14)
        XCTAssertNil(pulse.outline.animation(forKey: "workingPulse"))
        XCTAssertEqual(pulse.outline.opacity, 0)
        XCTAssertTrue([pulse.halo, pulse.outerRing].allSatisfy { $0.animationKeys()?.isEmpty != false && $0.opacity == 0 })
        try captureSteadyHaloPreview()
    }

    @MainActor private func captureSteadyHaloPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["PROFILEDOCK_RENDER_CUES"] else { return }
        let canvas = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.black.cgColor
        let pulse = IconPulseSurface(frame: CGRect(x: 14, y: 14, width: 72, height: 72))
        pulse.configure(working: true, visible: true, reduceMotion: true, cornerRadius: 14)
        canvas.addSubview(pulse)
        let icon = NSView(frame: CGRect(x: 24, y: 24, width: 52, height: 52))
        icon.wantsLayer = true; icon.layer?.backgroundColor = NSColor.white.cgColor; icon.layer?.cornerRadius = 14
        let label = NSTextField(labelWithString: "P")
        label.frame = CGRect(x: 0, y: 11, width: 52, height: 30)
        label.font = .systemFont(ofSize: 24, weight: .semibold); label.alignment = .center; label.textColor = .systemBlue
        icon.addSubview(label); canvas.addSubview(icon)
        canvas.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let destination = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent("working-halo-steady.png"))
    }

    @MainActor func testCompactWorkingGlowStopsWhenHiddenAndIsSteadyWithReduceMotion() {
        _ = NSApplication.shared
        let dot = WorkingDotGlowSurface(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        dot.configure(visible: true, reduceMotion: false)
        dot.layoutSubtreeIfNeeded()
        XCTAssertNotNil(dot.halo.animation(forKey: "workingPulse"))
        XCTAssertEqual(dot.halo.path?.boundingBox.width, 6)
        dot.configure(visible: false, reduceMotion: false)
        XCTAssertNil(dot.halo.animation(forKey: "workingPulse"))
        XCTAssertEqual(dot.halo.opacity, 0)
        dot.configure(visible: true, reduceMotion: true)
        XCTAssertNil(dot.halo.animation(forKey: "workingPulse"))
        XCTAssertGreaterThan(dot.halo.opacity, 0)
    }
}
