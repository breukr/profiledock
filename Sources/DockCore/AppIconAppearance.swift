import Foundation

public enum AppIconAppearance: String, Codable, CaseIterable, Sendable {
    case auto, dark, light, tinted, clear
    public var label: String { rawValue.capitalized }
}
