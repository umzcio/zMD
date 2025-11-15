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
        └── MarkdownView (Rendered content)
```

### Markdown Rendering Architecture

**Custom Parser** (`MarkdownView.swift`):
- Line-by-line stateful parser (not using external markdown libraries)
- Converts markdown → array of `MarkdownElement` enum cases
- Each element renders itself via `@ViewBuilder`
- Handles: headings (H1-H4), paragraphs, lists, code blocks, tables
- Inline formatting uses SwiftUI's `AttributedString(markdown:)` for bold/italic/code

**Why Custom Parser:**
- Full control over rendering style to match Typora aesthetics
- Avoids third-party dependencies and sandboxing issues
- Simplified table/list handling specific to app needs

### Export System

**ExportManager** (`ExportManager.swift`) is a singleton providing three export paths:

1. **PDF Export**: Markdown → HTML → NSAttributedString → CGContext rendering with pagination
2. **HTML Export**: Custom markdown-to-HTML converter with optional CSS styling
3. **RTF Export**: Markdown → HTML → NSAttributedString → RTF data

All exports use `NSSavePanel` and run on main thread. The HTML converter mirrors the parser structure to ensure visual consistency.

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
├── DocumentManager.swift  # Document state management (@ObservableObject)
├── MarkdownView.swift     # Markdown parser and rendering engine
├── TabBar.swift           # Tab bar UI and tab items
├── OutlineView.swift      # Hierarchical outline sidebar
├── ExportManager.swift    # PDF/HTML/RTF export functionality
├── Assets.xcassets/       # App icon and resources
└── zMD.entitlements       # Sandbox permissions (currently empty)
```

## Development Notes

### Adding New Markdown Elements

To add support for new markdown syntax:

1. Add case to `MarkdownElement.MarkdownContent` enum in `MarkdownView.swift`
2. Add parsing logic in `parseMarkdown()` function (line-by-line state machine)
3. Add view rendering in `MarkdownElement.view` @ViewBuilder
4. Mirror the logic in `ExportManager.convertMarkdownToHTMLBody()` for export consistency

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
- Outline click-to-scroll not yet implemented (UI exists but `selectedHeadingId` binding not connected)
- Table rendering may overflow on very wide tables
- Markdown parser is simplified (doesn't support all CommonMark features)
