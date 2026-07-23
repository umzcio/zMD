import Foundation

enum AccessibilityCopy {
    static let matchCase = "Match Case"
    static let regularExpression = "Use Regular Expression"

    static func toggleValue(_ isEnabled: Bool) -> String {
        isEnabled ? "On" : "Off"
    }
}
