import DockCore

// Keep raw preference values forward-compatible: an unknown option must not
// prevent the rest of the user's profiles and preferences from loading.
extension DockModel {
    var insightsAccount: String {
        get {
            guard let id = preferences.insightsAccount,
                  preferences.profiles.contains(where: { $0.id == id }) else { return "all" }
            return id
        }
        set {
            guard preferences.insightsAccount != newValue else { return }
            preferences.insightsAccount = newValue
            save()
        }
    }
    var insightsPeriod: InsightsPeriod {
        get { preferences.insightsPeriod.flatMap(InsightsPeriod.init(rawValue:)) ?? .week }
        set {
            guard preferences.insightsPeriod != newValue.rawValue else { return }
            preferences.insightsPeriod = newValue.rawValue
            save()
        }
    }
    var insightsMetric: InsightMetric {
        get { preferences.insightsMetric.flatMap(InsightMetric.init(rawValue:)) ?? .cost }
        set {
            guard preferences.insightsMetric != newValue.rawValue else { return }
            preferences.insightsMetric = newValue.rawValue
            save()
        }
    }
}
