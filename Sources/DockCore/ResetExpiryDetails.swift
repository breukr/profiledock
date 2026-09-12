import Foundation

public struct ResetExpiryDetails: Equatable {
    public let dates: [Date]
    public let message: String?

    public init(count: Int?, expiries: [Date]?) {
        let known = (expiries ?? []).sorted()
        if count == 0 {
            dates = []; message = "No saved resets."
        } else if let count, known.count > count {
            dates = []; message = "Expiry times are refreshing."
        } else {
            dates = known
            if let count, count > known.count {
                let missing = count - known.count
                message = "\(missing) \(missing == 1 ? "reset" : "resets"): expiry unknown."
            } else if count == nil {
                message = "Reset count unknown."
            } else { message = nil }
        }
    }

    public static func countdown(until expiry: Date, now: Date) -> String {
        let seconds = expiry.timeIntervalSince(now)
        guard seconds > 0 else { return "Expired" }
        let hours = Int(seconds / 3600), days = hours / 24
        if days > 0 { return "Expires in \(days)d \(hours % 24)h" }
        if hours > 0 { return "Expires in \(hours)h \(Int(seconds / 60) % 60)m" }
        if seconds < 60 { return "Expires within 1 min" }
        return "Expires in \(Int(seconds / 60)) min"
    }
}
