import SwiftUI

/// Keep ample allowance green, then gradually warm toward amber and low-budget red.
struct UsageTint {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    static func remaining(_ percent: Double) -> UsageTint {
        let low = UsageTint(red: 0.96, green: 0.36, blue: 0.32)
        let warning = UsageTint(red: 0.98, green: 0.71, blue: 0.29)
        let ample = UsageTint(red: 0.29, green: 0.85, blue: 0.52)
        guard percent.isFinite else { return UsageTint(red: 0.65, green: 0.65, blue: 0.65) }
        if percent <= 10 { return low }
        if percent >= 60 { return ample }
        let (start, end, fraction) = percent < 25
            ? (low, warning, (percent - 10) / 15)
            : (warning, ample, (percent - 25) / 35)
        // Smoothstep makes both the color and its rate of change continuous at each stop.
        let blend = fraction * fraction * (3 - 2 * fraction)
        return UsageTint(red: start.red + (end.red - start.red) * blend,
                         green: start.green + (end.green - start.green) * blend,
                         blue: start.blue + (end.blue - start.blue) * blend)
    }
}
