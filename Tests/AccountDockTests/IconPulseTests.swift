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
        XCTAssertEqual(animation.duration, 0.85)
        XCTAssertTrue(animation.autoreverses)
        XCTAssertEqual(animation.preferredFrameRateRange.preferred, 120)
        XCTAssertEqual(animation.animations?.count, 2)
        XCTAssertEqual(pulse.outline.path?.boundingBox.width, 58)
        pulse.configure(working: true, visible: false, reduceMotion: false, cornerRadius: 14)
        XCTAssertNil(pulse.outline.animation(forKey: "workingPulse"))
        XCTAssertEqual(pulse.outline.opacity, 0)
        pulse.configure(working: true, visible: true, reduceMotion: true, cornerRadius: 14)
        XCTAssertNil(pulse.outline.animation(forKey: "workingPulse"))
        XCTAssertGreaterThan(pulse.outline.opacity, 0)
        pulse.configure(working: false, visible: true, reduceMotion: false, cornerRadius: 14)
        XCTAssertNil(pulse.outline.animation(forKey: "workingPulse"))
        XCTAssertEqual(pulse.outline.opacity, 0)
    }
}
