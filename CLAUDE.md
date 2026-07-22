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
        └── HSplitView (view mode: preview / source / split)
            ├── SourceEditorView (Editable NSTextView — source/split modes)
            └── MarkdownTextView (Rendered content via NSTextView — preview/split modes)
```

### Markdown Rendering Architecture

**Two-layer rendering, one shared inline tokenizer:**
- `MarkdownParser.swift`: Single source of truth for *block*-level parsing (headings, paragraphs, lists, code blocks, tables, blockquotes, images, frontmatter).
- `InlineMarkdown.swift`: Shared *inline* tokenizer (bold/italic/code/strikethrough/links/images/math) consumed by all four rendering backends — `MarkdownParser` (HTML/PDF/RTF export), `MarkdownTextView` (preview), `ExportManager` (DOCX export), and `PrintManager` (print). This replaced four independently drifting inline-formatting implementations with a single one.
- `MarkdownTextView.swift` (NSViewRepresentable): Consumes `MarkdownParser`'s block-level `[Element]`s (and `InlineMarkdown` for inline formatting) to build NSAttributedString for NSTextView rendering. Handles headings, paragraphs, lists, code blocks (with syntax highlighting via SyntaxHighlighter), tables, blockquotes, images, frontmatter.
- `SourceEditorView.swift` (NSViewRepresentable): Editable NSTextView counterpart shown in Source and Split view modes, with its own markdown syntax highlighting for the raw source — separate from the preview/export pipeline above.

**Note:** `MarkdownView.swift` was removed as dead code. The active preview renderer is `MarkdownTextView.swift`; the active editor is `SourceEditorView.swift`.

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
└── zMD.entitlements         # Sandbox disabled; see Sandboxing Considerations below
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

The app currently ships **un-sandboxed** (direct `.dmg` distribution, not Mac App Store). See `zMD.entitlements` — `com.apple.security.app-sandbox` is `false`. The `com.apple.security.files.user-selected.read-write` and `com.apple.security.network.client` keys are present but inert outside the sandbox.

- `UpdateManager` writes the new .app bundle to `/Applications` directly — this only works outside the sandbox.
- The security-scoped bookmark calls (`startAccessingSecurityScopedResource`, `.withSecurityScope` bookmark data) are still present in DocumentManager/FolderManager but are no-ops at runtime in the un-sandboxed configuration. They stay in place so a future sandbox re-enable is a smaller change.
- If you ever set `app-sandbox=true`, re-test: save, rename, move, Open Recent, folder sidebar restore, drag-drop of .md files onto the window, and the auto-updater (which will break — sandbox cannot write `/Applications` or invoke `hdiutil`).

### Known Limitations

- Text selection implementation is incomplete (partially works)
- Table rendering may overflow on very wide tables
- Markdown parser is simplified (doesn't support all CommonMark features)
- Remote images load asynchronously but don't trigger re-render when cached
