# zMD

A lightweight macOS markdown viewer with multi-tab support and professional export capabilities.

![zMD Screenshot](https://raw.githubusercontent.com/umzcio/zMD/master/img/screenshot1.png)

---

## Features

### Markdown Rendering
- **Full CommonMark Support** - Headings, paragraphs, lists, tables, code blocks, blockquotes, horizontal rules
- **Nested Lists** - Properly indented sub-items with different bullet styles (•, ◦, ▪, ▹)
- **Syntax Highlighting** - Language-aware code blocks for Swift, Python, JavaScript, TypeScript, C/C++, Bash, SQL, JSON, HTML, and XML
- **YAML Frontmatter** - Displays document metadata from `---` blocks
- **Inline Formatting** - Bold, italic, strikethrough, inline code, and hyperlinks
- **Images** - Embedded images with automatic scaling (local and remote URLs)

### User Experience
- **Multi-Tab Interface** - Open and manage multiple markdown files simultaneously
- **Hierarchical Outline** - Navigate document structure with click-to-scroll
- **Quick Open** - Press `⌘⇧O` to quickly search and open recent files
- **Reading Position Memory** - Automatically remembers scroll position for each document
- **Full Text Selection** - Native macOS text selection with Select All and Copy support
- **In-Document Search** - Press `⌘F` to find text with match highlighting and navigation

### File Management
- **Live File Watching** - Detects external edits and offers to reload
- **Multi-Encoding Support** - Handles UTF-8, Windows CP1252, ISO Latin-1, and Mac Roman
- **Open Recent** - Quick access to recently opened files
- **File Operations** - Duplicate, Rename, Move To, and Reveal in Finder

### Export & Print
- **PDF Export** - Formatted document with pagination
- **HTML Export** - With or without embedded styles
- **Word Export** - Both .docx and .rtf formats
- **Print Support** - Native macOS print dialog with full formatting

### Customization
- **Themes** - System, Light, or Dark mode
- **Font Styles** - System, Serif, or Monospace fonts
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
- Press `⌘⇧O` for Quick Open (search recent files)
- Drag and drop files onto the app icon
- Recent files available in File menu

### Navigation
- Click the outline button to toggle document structure sidebar
- Click any heading in the outline to scroll to it
- Use `⌘F` to search within the document
- `⌘G` / `⌘⇧G` to jump between search matches

### Exporting & Printing
- **File → Export** to save as PDF, HTML, or Word
- **File → Print** (`⌘P`) to print with native macOS dialog

### Customization
Press `⌘,` to open Settings:
- **Theme** - System, Light, or Dark mode
- **Font Style** - System, Serif, or Monospace fonts

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘O` | Open file(s) |
| `⌘⇧O` | Quick Open (recent files) |
| `⌘W` | Close tab |
| `⌘P` | Print |
| `⌘F` | Find in document |
| `⌘G` | Find next match |
| `⌘⇧G` | Find previous match |
| `⌘,` | Open Settings |
| `⌘Q` | Quit app |
| `⌘⇧S` | Duplicate file |
| `⌃Tab` | Next tab |
| `⌃⇧Tab` | Previous tab |
| `⌘?` | Help |

## What's New in v2.0

### Parser Enhancements
- Syntax highlighting for 10+ programming languages
- YAML frontmatter display
- Nested list support with visual indentation
- Blockquote and horizontal rule rendering
- Strikethrough text support

### UX Improvements
- Quick Open (`⌘⇧O`) for fast file access
- Reading position memory across sessions
- Native print support (`⌘P`)
- Click-to-scroll outline navigation
- Full text selection and copy

### Reliability
- Live file change detection with reload prompts
- Multi-encoding support for legacy files
- User-visible error messages instead of silent failures
- Improved stability and performance

## Why zMD?

A free, focused markdown viewer without subscriptions or unnecessary features. Just clean rendering, tabs, and the export formats you need.

## License

Free to use and modify.
