import SwiftUI

// MARK: - Named Constants
//
// Centralizes timing/size/CDN magic numbers that were previously scattered as inline literals.
// Changing any value here is the single edit point; no grep-hunt required.
// Living alongside SettingsManager to avoid adding a new file to the Xcode project (legacy
// pbxproj format; file additions require manual project edits).

/// Cross-app timing constants (seconds unless noted).
enum Timing {
    /// Debounce window between the last keystroke and an auto-save triggering.
    static let autoSaveDebounce: TimeInterval = 2.0
    /// Debounce between last keystroke and syntax-highlight reapply in the source editor.
    static let highlightDebounce: TimeInterval = 0.3
    /// Debounce between last keystroke and autocomplete panel trigger.
    static let autocompleteDebounce: TimeInterval = 0.3
    /// Delay before scrollSyncOrigin flips back to `.none` after a programmatic scroll.
    static let scrollSyncResetDelay: TimeInterval = 0.1
    /// Debounce window on scroll-percent broadcasts from source/preview to suppress mutual kicks.
    static let scrollSyncDebounce: TimeInterval = 0.05
    /// How long a heading stays "flashed" (selected) after an outline click.
    static let headingFlashDuration: TimeInterval = 0.5
    /// Debounce window for FSEvents directory-change callbacks before rebuilding the tree.
    static let directoryWatcherDebounce: TimeInterval = 0.3
    /// Latency the FSEvents stream coalesces file events within.
    static let directoryWatcherLatency: CFTimeInterval = 1.0
    /// Minimum hours between auto-checks on launch for updates.
    static let updateCheckIntervalHours: Double = 24
    /// Scroll debounce for persisting a document's scroll position to UserDefaults.
    static let scrollPositionPersistDebounce: TimeInterval = 0.5
}

/// Cache limits for in-memory image + diagram storage.
enum Cache {
    static let imageCountLimit: Int = 100
    static let imageByteLimit: Int = 100 * 1024 * 1024
    static let diagramCountLimit: Int = 100
    static let diagramByteLimit: Int = 100 * 1024 * 1024
    /// Maximum number of per-document scroll-position entries kept in UserDefaults.
    static let scrollPositionLimit: Int = 100
    /// Maximum Recent Files retained across launches.
    static let recentFilesLimit: Int = 10
}

/// CDN resource URLs for preview/export scripts. Both preview (WebRenderer) and exported HTML
/// (MarkdownParser.toHTML) reference the same strings — defining them once eliminates version
/// drift between the two consumers.
enum CDN {
    static let mermaidJS = "https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"
    static let katexCSS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css"
    static let katexJS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js"
    static let katexAutoRenderJS = "https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/contrib/auto-render.min.js"
}

/// UserDefaults key strings. Centralizing them prevents silent user-data loss from typos —
/// renaming a raw string "RecentMarkdownFiles" → "recentFiles" on a live install wipes the
/// user's Open Recent list. Values here MUST match the historical string used at write time.
enum DefaultsKeys {
    // MARK: Settings (SettingsManager)
    static let colorScheme = "colorScheme"
    static let fontStyle = "fontStyle"
    static let zoomLevel = "zoomLevel"
    static let tabWidth = "tabWidth"
    static let autoCloseBrackets = "autoCloseBrackets"
    static let showEditorToolbar = "showEditorToolbar"
    static let showMinimap = "showMinimap"
    static let showLineNumbers = "showLineNumbers"

    // MARK: DocumentManager
    static let autoSaveEnabled = "autoSaveEnabled"
    static let recentFiles = "RecentMarkdownFiles"
    static let scrollPositions = "DocumentScrollPositions"

    // MARK: FolderManager
    static let folderBookmark = "FolderBookmarkData"

    // MARK: ContentView
    static let showOutline = "showOutline"

    // MARK: UpdateManager
    static let lastUpdateCheckDate = "lastUpdateCheckDate"
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var colorScheme: ColorScheme? {
        didSet {
            UserDefaults.standard.set(colorScheme == .dark ? "dark" : (colorScheme == .light ? "light" : "system"), forKey: DefaultsKeys.colorScheme)
        }
    }

    @Published var fontStyle: FontStyle {
        didSet {
            UserDefaults.standard.set(fontStyle.rawValue, forKey: DefaultsKeys.fontStyle)
        }
    }

    @Published var zoomLevel: CGFloat {
        didSet {
            UserDefaults.standard.set(zoomLevel, forKey: DefaultsKeys.zoomLevel)
        }
    }

    // Editor settings
    @Published var tabWidth: Int {
        didSet { UserDefaults.standard.set(tabWidth, forKey: DefaultsKeys.tabWidth) }
    }

    @Published var autoCloseBrackets: Bool {
        didSet { UserDefaults.standard.set(autoCloseBrackets, forKey: DefaultsKeys.autoCloseBrackets) }
    }

    @Published var showEditorToolbar: Bool {
        didSet { UserDefaults.standard.set(showEditorToolbar, forKey: DefaultsKeys.showEditorToolbar) }
    }

    @Published var showMinimap: Bool {
        didSet { UserDefaults.standard.set(showMinimap, forKey: DefaultsKeys.showMinimap) }
    }

    @Published var showLineNumbers: Bool {
        didSet { UserDefaults.standard.set(showLineNumbers, forKey: DefaultsKeys.showLineNumbers) }
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
        let savedFont = UserDefaults.standard.string(forKey: DefaultsKeys.fontStyle) ?? FontStyle.system.rawValue
        self.fontStyle = FontStyle(rawValue: savedFont) ?? .system

        let savedZoom = UserDefaults.standard.double(forKey: DefaultsKeys.zoomLevel)
        self.zoomLevel = savedZoom > 0 ? CGFloat(savedZoom) : 1.0

        let savedScheme = UserDefaults.standard.string(forKey: DefaultsKeys.colorScheme) ?? "system"
        switch savedScheme {
        case "dark":
            self.colorScheme = .dark
        case "light":
            self.colorScheme = .light
        default:
            self.colorScheme = nil
        }

        // Editor settings
        let savedTabWidth = UserDefaults.standard.integer(forKey: DefaultsKeys.tabWidth)
        self.tabWidth = savedTabWidth > 0 ? savedTabWidth : 4

        self.autoCloseBrackets = UserDefaults.standard.object(forKey: DefaultsKeys.autoCloseBrackets) == nil
            ? true : UserDefaults.standard.bool(forKey: DefaultsKeys.autoCloseBrackets)

        self.showEditorToolbar = UserDefaults.standard.object(forKey: DefaultsKeys.showEditorToolbar) == nil
            ? true : UserDefaults.standard.bool(forKey: DefaultsKeys.showEditorToolbar)

        self.showMinimap = UserDefaults.standard.object(forKey: DefaultsKeys.showMinimap) == nil
            ? true : UserDefaults.standard.bool(forKey: DefaultsKeys.showMinimap)

        self.showLineNumbers = UserDefaults.standard.object(forKey: DefaultsKeys.showLineNumbers) == nil
            ? true : UserDefaults.standard.bool(forKey: DefaultsKeys.showLineNumbers)
    }
}
