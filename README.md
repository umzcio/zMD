# zMD

A lightweight macOS markdown viewer with multi-tab support and professional export capabilities.

![zMD Screenshot](https://raw.githubusercontent.com/umzcio/zMD/master/img/screenshot1.png)

---

## Features

- **Clean Markdown Rendering** - Support for headings, tables, code blocks, lists, images, and inline formatting
- **Multi-Tab Interface** - Open and manage multiple markdown files simultaneously
- **Hierarchical Outline** - Navigate document structure with collapsible heading tree
- **Customizable Appearance** - Choose between Light/Dark themes and three font styles (System, Serif, Monospace)
- **Professional Exports** - Export to PDF, HTML, or Word (.docx) with proper formatting
- **File Management** - Open Recent, Duplicate, Rename, Move To, and Reveal in Finder
- **Native macOS** - Built with SwiftUI, supports Dark Mode, sandboxed for security

## Installation

### Building from Source

```bash
git clone https://github.com/yourusername/zMD.git
cd zMD
open zMD.xcodeproj
```

Press `⌘R` in Xcode to build and run.

**Requirements:** macOS 13.0+, Xcode 15.0+

## Usage

### Opening Files
- Press `⌘O` to open markdown files
- Drag and drop files onto the app icon
- Recent files available in File menu

### Navigation
- `⌘W` - Close current tab
- `⌃Tab` / `⌃⇧Tab` - Switch between tabs
- Click outline sidebar to toggle document structure

### Customization
Press `⌘,` to open Settings where you can:
- **Theme** - Choose System, Light, or Dark mode
- **Font Style** - Select between System, Serif, or Monospace fonts

### Exporting
Choose **File → Export** to save as:
- **PDF** - Formatted document with pagination
- **HTML** - With or without embedded styles
- **Word (.docx)** - Microsoft Word compatible format

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘O` | Open file(s) |
| `⌘W` | Close tab |
| `⌘,` | Open Settings |
| `⌘Q` | Quit app |
| `⌘⇧S` | Duplicate file |
| `⌃Tab` | Next tab |
| `⌃⇧Tab` | Previous tab |
| `ESC` | Close Settings |

## Why zMD?

A free, focused markdown viewer without subscriptions or unnecessary features. Just clean rendering, tabs, and the export formats you need.

## License

Free to use and modify.
