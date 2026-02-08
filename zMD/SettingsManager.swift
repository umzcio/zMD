import SwiftUI

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var colorScheme: ColorScheme? {
        didSet {
            UserDefaults.standard.set(colorScheme == .dark ? "dark" : (colorScheme == .light ? "light" : "system"), forKey: "colorScheme")
        }
    }

    @Published var fontStyle: FontStyle {
        didSet {
            UserDefaults.standard.set(fontStyle.rawValue, forKey: "fontStyle")
        }
    }

    @Published var zoomLevel: CGFloat {
        didSet {
            UserDefaults.standard.set(zoomLevel, forKey: "zoomLevel")
        }
    }

    func zoomIn() {
        zoomLevel = min(2.0, (zoomLevel * 10 + 1).rounded() / 10)
    }

    func zoomOut() {
        zoomLevel = max(0.5, (zoomLevel * 10 - 1).rounded() / 10)
    }

    func resetZoom() {
        zoomLevel = 1.0
    }

    enum FontStyle: String, CaseIterable {
        case system = "System"
        case serif = "Serif"
        case monospace = "Monospace"

        var displayName: String {
            return self.rawValue
        }

        func font(size: CGFloat) -> Font {
            switch self {
            case .system:
                return .system(size: size)
            case .serif:
                return .custom("Charter", size: size)
            case .monospace:
                return .system(size: size, design: .monospaced)
            }
        }
    }

    init() {
        // Load saved preferences
        let savedFont = UserDefaults.standard.string(forKey: "fontStyle") ?? FontStyle.system.rawValue
        self.fontStyle = FontStyle(rawValue: savedFont) ?? .system

        let savedZoom = UserDefaults.standard.double(forKey: "zoomLevel")
        self.zoomLevel = savedZoom > 0 ? CGFloat(savedZoom) : 1.0

        let savedScheme = UserDefaults.standard.string(forKey: "colorScheme") ?? "system"
        switch savedScheme {
        case "dark":
            self.colorScheme = .dark
        case "light":
            self.colorScheme = .light
        default:
            self.colorScheme = nil
        }
    }
}
