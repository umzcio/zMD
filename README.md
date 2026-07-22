<p align="center">
  <img src="img/zMarkdown.png" alt="zMD" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/zMD-Native_Markdown_Editor-c8a96e?style=for-the-badge&labelColor=080a0f" alt="zMD" />
</p>

<p align="center">
  <strong>Native macOS markdown editor and viewer</strong><br/>
  A lightweight, Typora-inspired app with live rendering, tabs, an outline sidebar, and full export support.<br/><br/>
  <a href="https://github.com/umzcio/zMD/releases/latest">Download</a> · <a href="https://github.com/umzcio/zMD/issues">Issues</a> · <a href="https://github.com/umzcio/zMD/blob/master/CLAUDE.md">Developer Guide</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/status-stable-c8a96e?style=flat-square" alt="Stable" />
  <img src="https://img.shields.io/github/v/release/umzcio/zMD?style=flat-square&color=c8a96e&label=version" alt="Latest release" />
  <img src="https://img.shields.io/badge/platform-macOS_13%2B-4a9eff?style=flat-square" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/stack-SwiftUI%20%7C%20AppKit%20%7C%20NSTextView-34d399?style=flat-square" alt="Stack" />
</p>

---

## Origin

zMD is a simple markdown reader for macOS, with just enough editing built in when you need to make a change. Open a file, it renders instantly; switch to Source or Split when you want to edit; export to PDF/HTML/Word when you're done.

It's a native SwiftUI app built around Apple's `NSTextView` rather than a web view — no Electron, no Tauri. Under 5 MB, signed, distributed as a direct `.dmg`.

If you read markdown, occasionally edit it, or hand markdown to other humans as PDFs and Word docs, this is for you.

---

## How It Works

```
Open .md --> Live Preview + Source Editor --> Export PDF/HTML/Word
```

1. **Open a file**: `⌘O`, drag-drop, or create a new untitled doc with `⌘N`
2. **Choose a view mode**: Preview (rendered), Source (editor with syntax highlighting), or Split (side-by-side with scroll sync)
3. **Edit with assistance**: line numbers, autocomplete, auto-indent, list continuation, Cmd+B/I/K shortcuts, find & replace with regex
4. **Preview everything**: headings, code blocks with syntax highlighting, tables, Mermaid diagrams, LaTeX math, clickable links
5. **Export anywhere**: PDF (paginated), HTML (with or without styles), Word (.docx / .rtf), native print

---

## Features

### Editor
- **Source mode** with markdown syntax highlighting, line numbers, current-line highlight
- **Split view** — source and preview side-by-side with bidirectional scroll sync
- **Format toolbar** — one-click bold, italic, strikethrough, code, link, image, lists, HR
- **Keyboard shortcuts** — `⌘B`, `⌘I`, `⌘⇧X`, `⌘⇧K`, `⌘⇧L` for formatting
- **Auto-save** — optional 2s debounced save, toggleable per-window
- **Find & replace** (`⌘⌥F`) with regex and case-sensitive toggles
- **New untitled tab** (`⌘N`) — instant, no save dialog until you hit `⌘S`

### Preview Rendering
- **Typora-style typography** — rendered headings, proper line-height, collapsed syntax markers
- **Emphasis via asterisks** — `*italic*` / `**bold**`; underscore emphasis (`_text_`) is not supported by design
- **Syntax highlighting** for Swift, Python, JavaScript, TypeScript, C/C++, Bash, SQL, JSON, HTML, XML, YAML
- **Mermaid diagrams** — flowcharts, sequence diagrams, class diagrams rendered inline
- **LaTeX math** — inline `$...$` and block `$$...$$` via KaTeX
- **Tables** — GitHub-flavored markdown tables with alignment
- **Nested lists** — proper indentation with different bullet styles (•, ◦, ▪, ▹)
- **YAML frontmatter** — displays document metadata from `---` blocks
- **Clickable links** — external URLs open in browser, relative `.md` links open as new tabs
- **Task lists** — `- [ ]` / `- [x]` rendered as checkboxes

### Navigation & Search
- **Multi-tab interface** — drag to reorder, right-click for tab options
- **Folder sidebar** — open a directory and browse all markdown files with FSEvents watching
- **Outline sidebar** — hierarchical heading navigation with click-to-scroll
- **Quick switcher** (`⌘⇧O`) — fuzzy search across open files, or `@file` / `#heading` targeted search
- **Command palette** (`⌘K`) — every app action, searchable
- **Find in document** (`⌘F`) — match highlighting with next/previous navigation
- **Reading position memory** — automatically remembers scroll position per document

### Export & Print
- **PDF export** — paginated, formatted, with syntax-highlighted code blocks
- **HTML export** — with or without embedded CSS styling
- **Word export** — both `.docx` (native XML) and `.rtf` formats
- **Native print** (`⌘P`) — macOS print dialog with full formatting
- **Mermaid and KaTeX** — included in exports with CDN script references

### File Management
- **Live file watching** — detects external edits and prompts to reload
- **Multi-encoding detection** — auto-decodes UTF-8, Windows CP1252, ISO Latin-1, Mac Roman, UTF-16
- **File operations** — Duplicate, Rename, Move To, Reveal in Finder
- **Open Recent** — last 10 files with bookmarks for sandboxed access
- **Drag-and-drop** — drop `.md` files onto the window to open
- **Security-scoped bookmarks** — persistent save access across launches

### UX Polish
- **Focus mode** (`⌘⇧F`) — hides everything, centers content at 720px max, floating exit pill
- **Status bar** — word count, character count, reading time, view mode, detected encoding
- **Toast notifications** — save confirmations, file change alerts, export success
- **Zoom** — `⌘+` / `⌘−` / `⌘0`, pinch-to-zoom trackpad gesture
- **Auto-update** — silent GitHub release check on launch (once per 24h)
- **Themes** — System / Light / Dark, with font style (System / Serif / Monospace)

### Autocomplete
- **Word completion** — suggests words from the current and all open documents after 3 characters
- **Markdown snippets** — type `link`, `bold`, `codeblock`, `table`, etc. for quick insertion
- **HTML tag completion** — type `<` to see available HTML tags with descriptions
- **Debounced** — 300ms after typing pauses, never interrupts the cursor

---

## Tech Stack

| Layer | Technology |
|-------|-----------|
| **UI** | SwiftUI + AppKit interop |
| **Text engine** | `NSTextView` (Apple's native text system, not a web view) |
| **Parser** | Custom line-based markdown parser (single source of truth for preview + export) |
| **Syntax highlighting** | Regex-based, ~10 language grammars |
| **Diagrams / Math** | Headless `WKWebView` with Mermaid + KaTeX CDN scripts |
| **File watching** | `DispatchSourceFileSystemObject` + `FSEventStream` for directories |
| **Persistence** | `UserDefaults` + security-scoped bookmark data |
| **Distribution** | Signed `.app` inside a drag-to-Applications `.dmg` (direct download, not Mac App Store, no sandbox) |
| **Deployment target** | macOS 13.0+ |

---

## Quick Start

### Install

Download the latest `.dmg` from [Releases](https://github.com/umzcio/zMD/releases/latest), open it, drag zMD to your Applications folder, and launch. First launch on unsigned builds requires right-click → Open to bypass Gatekeeper.

### Build from Source

```bash
git clone https://github.com/umzcio/zMD.git
cd zMD
open zMD.xcodeproj
```

Press `⌘R` in Xcode to build and run.

**Requirements:** macOS 13.0+, Xcode 15.0+

### Build a Release DMG

```bash
./scripts/build-dmg.sh
```

Produces `build/zMD.dmg` with the drag-to-Applications installer layout.

---

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌘N` | New untitled file |
| `⌘O` | Open file(s) |
| `⌘⌥O` | Open folder |
| `⌘⇧O` | Quick switcher (fuzzy search files + headings) |
| `⌘K` | Command palette |
| `⌘S` | Save |
| `⌘W` | Close tab |
| `⌘F` | Find in document |
| `⌘⌥F` | Find and Replace (source/split mode) |
| `⌘G` / `⌘⇧G` | Next / previous match |
| `⌘P` | Print |
| `⌘1` / `⌘2` / `⌘3` | Preview / Source / Split view |
| `⌘⇧F` | Focus mode |
| `⌘B` / `⌘I` | Bold / italic |
| `⌘⇧X` / `⌘⇧K` / `⌘⇧L` | Strikethrough / inline code / link |
| `⌘=` / `⌘−` / `⌘0` | Zoom in / out / reset |
| `⌘,` | Settings |
| `⌃Tab` / `⌃⇧Tab` | Next / previous tab |

---

## License

[MIT](LICENSE.md). Want to contribute? See [CONTRIBUTING.md](CONTRIBUTING.md).

---

<p align="center">
  <em>"It doesn't have to be a web view."</em><br/>
  <sub>-- every macOS user, every time they launch VS Code</sub>
</p>
