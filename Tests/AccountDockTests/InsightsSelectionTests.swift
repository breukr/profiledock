import XCTest
import DockCore
@testable import AccountDock

final class InsightsSelectionTests: XCTestCase {
    @MainActor func testSelectionsSurviveRestartAndAreSharedByBothViews() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let profile = Profile(id: "default", name: "Personal", color: "377CF6")
        try FileManager.default.createDirectory(at: profile.home(in: home), withIntermediateDirectories: true)
        let model = DockModel(home: home)
        model.preferences.profiles = [profile]
        let store = InsightsStore()
        defer { store.shutdown() }
        let full = InsightsPanel(model: model, store: store, active: false)
        let drawer = InsightsPanel(model: model, store: store, compact: true, active: false)
        model.insightsPeriod = .month
        model.insightsAccount = profile.id
        model.insightsMetric = .tokens
        XCTAssertEqual(full.period, .month)
        XCTAssertEqual(drawer.account, profile.id)
        XCTAssertEqual(drawer.metric, .tokens)
        let restored = DockModel(home: home)
        XCTAssertEqual(restored.insightsPeriod, .month)
        XCTAssertEqual(restored.insightsAccount, profile.id)
        XCTAssertEqual(restored.insightsMetric, .tokens)
        // Choosing all accounts is an explicit selection and survives restart too.
        restored.insightsAccount = "all"
        restored.insightsPeriod = .today
        restored.insightsMetric = .sessions
        let again = DockModel(home: home)
        XCTAssertEqual(again.insightsAccount, "all")
        XCTAssertEqual(again.insightsPeriod, .today)
        XCTAssertEqual(again.insightsMetric, .sessions)
    }

    @MainActor func testOldAndUnknownOptionsKeepSafeDefaultsWithoutLosingProfiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = DockModel(home: home)
        XCTAssertEqual(model.insightsAccount, "all")
        XCTAssertEqual(model.insightsPeriod, .week)
        XCTAssertEqual(model.insightsMetric, .cost)
        model.preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"profiles":[{"id":"default","name":"Personal","color":"377CF6"}],"scale":1,"insightsAccount":"removed-profile","insightsPeriod":999,"insightsMetric":"future-metric"}"#.utf8))
        XCTAssertEqual(model.preferences.profiles.count, 1)
        XCTAssertEqual(model.insightsAccount, "all")
        XCTAssertEqual(model.insightsPeriod, .week)
        XCTAssertEqual(model.insightsMetric, .cost)
    }

    @MainActor func testRenamingKeepsAccountSelectionAndRemovingFallsBackToAll() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = DockModel(home: home)
        model.preferences.profiles = [Profile(id: "default", name: "Original", color: "377CF6")]
        model.preferences.insightsAccount = "default"
        model.preferences.profiles[0].name = "Renamed"
        XCTAssertEqual(model.insightsAccount, "default")
        model.preferences.profiles = []
        XCTAssertEqual(model.insightsAccount, "all")
    }
}
