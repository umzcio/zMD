# zMD - Simple Markdown Viewer

A lightweight macOS application for viewing markdown files with tab support, inspired by Typora.

## Features

### ✅ Implemented
- **Clean, Typora-style markdown rendering**
  - Headings (H1-H6) with proper hierarchy
  - Bold, italic, inline code
  - Code blocks with syntax preservation
  - Tables with proper alignment
  - Lists (ordered, unordered, checkboxes)
  - Horizontal rules, blockquotes, links

- **Tab Management**
  - Multiple files open simultaneously
  - Tab bar with close buttons
  - Right-click context menu (Close Tab, Close Other Tabs)
  - Drag to reorder tabs support

- **Outline Sidebar**
  - Hierarchical document outline
  - Click headings to navigate (in progress)
  - Toggle with sidebar button

- **Keyboard Shortcuts**
  - `⌘O` - Open markdown file(s)
  - `⌘W` - Close current tab
  - `⌃Tab` - Next tab
  - `⌃⇧Tab` - Previous tab

- **Native macOS Integration**
  - SwiftUI interface
  - Dark/Light mode support
  - App sandbox for security
  - Custom app icon

### ⚠️ In Progress
- Text selection and copy (Cmd+A, drag-to-select)
- Scroll to heading from outline
- More keyboard shortcuts

## Building & Running

See [BUILD.md](BUILD.md) for detailed build instructions.

**Quick start:**
```bash
open zMD.xcodeproj
# Then press ⌘R in Xcode to run
```

## Usage

1. **Open Files**: Press `⌘O` or click the `+` button
2. **Switch Tabs**: Click tabs or use `⌃Tab` / `⌃⇧Tab`
3. **Close Tabs**: Click X button, press `⌘W`, or right-click → Close Tab
4. **Toggle Outline**: Click the sidebar icon in top right
5. **View Markdown**: All standard markdown syntax is supported

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building)

## Project Structure

```
zMD/
├── zMD.xcodeproj/              # Xcode project file
├── BUILD.md                    # Build instructions
└── zMD/
    ├── zMDApp.swift            # App entry point & commands
    ├── ContentView.swift       # Main view layout
    ├── DocumentManager.swift   # Document state management
    ├── MarkdownView.swift      # Markdown parsing & rendering
    ├── TabBar.swift            # Tab interface
    ├── OutlineView.swift       # Outline sidebar
    ├── Assets.xcassets/        # App assets & icon
    └── zMD.entitlements        # App permissions
```

## Why zMD?

Built as a free, simple alternative to expensive markdown viewers. No subscriptions, no bloat - just clean markdown viewing with the features you need.

## Contributing

Feel free to fork, modify, and improve! This is a personal project but contributions are welcome.

## License

Free to use and modify as needed.
