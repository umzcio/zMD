# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

zMD is a lightweight macOS markdown viewer built with SwiftUI. It provides a clean, Typora-inspired interface for viewing markdown files with tab support, an outline sidebar, and export capabilities.

**Key Features:**
- Multi-tab document management
- Real-time markdown rendering with Typora-style formatting
- Hierarchical outline sidebar for navigation
- Export to PDF, HTML, and RTF (Word-compatible)
- Native macOS integration with keyboard shortcuts

## Build Commands

### Development
```bash
# Open in Xcode
open zMD.xcodeproj

# Build and run (⌘R in Xcode)
# Or via command line:
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Debug

# Release build
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Release

# Build output location
# build/Release/zMD.app
```

### Distribution
```bash
# Create release build
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Release

# Copy to Applications
cp -r build/Release/zMD.app /Applications/
```

**Note:** First launch on unsigned builds requires right-click → Open to bypass macOS Gatekeeper.

## Architecture

### State Management Pattern

The app uses SwiftUI's `@StateObject` / `@EnvironmentObject` pattern for centralized state:

- **DocumentManager** (`DocumentManager.swift`): Central source of truth for all document state
  - Manages array of `MarkdownDocument` objects (each with UUID, URL, content)
  - Tracks `selectedDocumentId` for active tab
  - Handles file loading, tab switching, and document lifecycle
  - Injected into view hierarchy via `.environmentObject()` at app root

### View Hierarchy

```
zMDApp (App entry point)
└── ContentView (Main container)
    ├── TabBar (Tab interface + controls)
    │   └── TabItem[] (Individual tabs with context menus)
    └── HStack
        ├── OutlineView (Sidebar - conditional)
        └── MarkdownTextView (Rendered content via NSTextView)
```

### Markdown Rendering Architecture

**Two-layer rendering:**
- `MarkdownTextView.swift` (NSViewRepresentable): Line-by-line parser builds NSAttributedString for NSTextView rendering. Handles headings, paragraphs, lists, code blocks (with syntax highlighting via SyntaxHighlighter), tables, blockquotes, images, frontmatter.
- `MarkdownParser.swift`: Shared parser used by ExportManager for HTML/PDF/RTF/DOCX exports. Single source of truth for export parsing.

**Note:** `MarkdownView.swift` was removed as dead code. The active renderer is `MarkdownTextView.swift`.

### Export System

**ExportManager** (`ExportManager.swift`) handles PDF, HTML, RTF, and DOCX exports:

1. **PDF Export**: Markdown → HTML (via MarkdownParser) → NSAttributedString → CGContext rendering with pagination
2. **HTML Export**: Markdown → HTML (via MarkdownParser) with optional CSS styling
3. **RTF Export**: Markdown → HTML → NSAttributedString → RTF data
4. **DOCX Export**: Custom XML generation with inline formatting, tables, lists, and hyperlinks

All exports use `NSSavePanel` and run on main thread. HTML conversion routes through `MarkdownParser.shared.toHTML()` for consistent, safe output.

### Menu Commands & Shortcuts

Defined in `zMDApp.swift` using SwiftUI's `.commands` modifier:

- File menu: Open (⌘O)
- Export submenu: PDF, HTML (with/without styles), Word/RTF
- Tab menu: Close (⌘W), Next (⌃Tab), Previous (⌃⇧Tab)
- Right-click context menu: Close Tab, Close Other Tabs

## File Organization

```
zMD/
├── zMDApp.swift           # App entry point, menu commands, keyboard shortcuts
├── ContentView.swift      # Main view container and layout
├── DocumentManager.swift    # Document state management (@ObservableObject)
├── MarkdownTextView.swift   # NSTextView-based markdown renderer (active)
├── MarkdownParser.swift     # Shared markdown parser for exports
├── TabBar.swift             # Tab bar UI and tab items
├── OutlineView.swift        # Hierarchical outline sidebar (cached headings)
├── ExportManager.swift      # PDF/HTML/RTF/DOCX export functionality
├── SyntaxHighlighter.swift  # Code block syntax highlighting
├── AlertManager.swift       # Centralized alert/error management
├── FileWatcher.swift        # File change monitoring
├── QuickOpenView.swift      # Quick open dialog
├── Assets.xcassets/         # App icon and resources
└── zMD.entitlements         # Sandbox permissions (currently empty)
```

## Development Notes

### Adding New Markdown Elements

To add support for new markdown syntax:

1. Add rendering logic in `MarkdownTextView.swift`'s `buildAttributedString()` method
2. Add a new case to `MarkdownParser.Element` enum in `MarkdownParser.swift`
3. Add parsing logic in `MarkdownParser.parse()` and HTML conversion in `elementToHTML()`
4. This ensures rendering and export stay in sync

### Working with Document State

Always access/modify documents through `DocumentManager` methods, never manipulate `openDocuments` array directly:
- Use `loadDocument(from:)` to open files
- Use `closeDocument(_:)` to close tabs
- Use `selectedDocumentId` binding for active document

### Sandboxing Considerations

The app runs in macOS App Sandbox (see `zMD.entitlements`):
- File access is limited to user-selected files via `NSOpenPanel` / `NSSavePanel`
- No network access required
- Export functions use sandbox-safe APIs (NSAttributedString, CGContext)

### Known Limitations

- Text selection implementation is incomplete (partially works)
- Table rendering may overflow on very wide tables
- Markdown parser is simplified (doesn't support all CommonMark features)
- Remote images load asynchronously but don't trigger re-render when cached
