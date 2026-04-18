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
  <img src="https://img.shields.io/badge/version-2.5-c8a96e?style=flat-square" alt="v2.5" />
  <img src="https://img.shields.io/badge/platform-macOS_13%2B-4a9eff?style=flat-square" alt="macOS 13+" />
  <img src="https://img.shields.io/badge/stack-SwiftUI%20%7C%20AppKit%20%7C%20NSTextView-34d399?style=flat-square" alt="Stack" />
</p>

---

## Origin

zMD started as a frustration: every "lightweight" markdown editor on macOS is a 200 MB Electron bundle with a subscription page baked in. I wanted the Typora experience (live-rendered, typography-first, no visible syntax noise) without the web tech tax — something that launches instantly, respects the system, and doesn't phone home.

So this is a native SwiftUI app, under 5 MB, signed and distributed as a direct `.dmg` (not via the Mac App Store, so no sandbox), built around Apple's `NSTextView` for rendering and editing. No Electron, no Tauri, no web views (except for Mermaid and LaTeX, which need a JS runtime). Typora-inspired formatting. Word-class export. Atom-style autocomplete. Free and open.

If you read markdown, write markdown, or hand markdown to other humans as PDFs and Word docs, this is for you.

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

## Architecture

```
                    +-----------------------------+
                    |       zMDApp (entry)        |
                    |   menu commands + shortcuts |
                    +--------------+--------------+
                                   |
                    +--------------+--------------+
                    |        ContentView          |
                    |  tab bar + folder sidebar   |
                    |  outline + status bar       |
                    +--------------+--------------+
                                   |
              +--------------------+--------------------+
              |                                         |
   +----------+-----------+               +-------------+----------+
   |  MarkdownTextView    |               |   SourceEditorView     |
   |  (preview renderer)  |               |   (editor + gutter)    |
   |  NSTextView + cache  |               |   NSTextView + hl      |
   +----------+-----------+               +-------------+----------+
              |                                         |
              +--------------------+--------------------+
                                   |
                    +--------------+--------------+
                    |       MarkdownParser        |
                    |   line-based -> [Element]   |
                    |   shared parse for both     |
                    |   preview and export        |
                    +--------------+--------------+
                                   |
        +--------------+-----------+-----------+--------------+
        |              |                       |              |
   +----+-----+   +----+-----+           +----+-----+    +----+-----+
   |  PDF     |   |  HTML    |           |  DOCX    |    |  RTF     |
   |  export  |   |  export  |           |  export  |    |  export  |
   +----------+   +----------+           +----------+    +----------+
```

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

## Design Decisions

**Why native instead of Electron?** Typora-style markdown editors should feel like *text*, not like a web page in a wrapper. `NSTextView` is 30+ years of Apple engineering optimized for editing. It renders instantly, handles selection/copy/dictation/accessibility for free, and has zero web-tech overhead. The whole app is under 5 MB.

**Why a shared parser for preview AND export?** When the HTML export of a document doesn't match the preview, you've just created two bugs at once. `MarkdownParser` is the single source of truth — both the in-app `NSTextView` renderer and the HTML/PDF/DOCX/RTF exporters consume the same `[Element]` tree.

**Why a custom parser instead of cmark/swift-markdown?** The custom parser is line-based, ~400 LOC, and produces a structure optimized for `NSAttributedString` rendering with incremental element-level caching. Off-the-shelf parsers produce AST trees that need further transformation and don't handle my edge cases (frontmatter, indented code fences inside lists, inline Mermaid).

**Why `NSTextView` for both the editor AND the rendered preview?** Consistency. Both views use the same text layout engine, so selection, find, scroll, and styling all behave identically. The preview is an `NSTextView` with `isEditable = false` and pre-built `NSAttributedString` content.

**Why incremental element-level caching?** Re-rendering a 5,000-line document on every keystroke is brutal. Instead, each parsed `Element` has a content-hash ID, and its rendered `NSAttributedString` is cached. On edit, only changed elements re-render. Cache invalidates on zoom, font change, or diagram render completion.

**Why not use a markdown library like GitHub-flavored?** Simplicity and control. The parser is ~400 lines. If an edge case breaks, I can fix it in minutes. No dependency churn, no vendored binaries, no build-system complexity.

---

## Roadmap

Current focus areas (see [issues](https://github.com/umzcio/zMD/issues) for granular tracking):

- **Editor features** — multi-cursor, block-level drag-reorder, table editing, Vim mode (optional)
- **Preview** — wiki-style `[[backlinks]]`, footnote popovers, export to Reveal.js slideshow
- **Plugins** — Lua or JavaScript plugin system for custom renderers / export filters
- **Integrations** — Obsidian / Logseq import, Notion export, Zotero citation pull
- **Performance** — async parser for 10k+ line documents, progressive rendering

---

## License

Free to use, modify, and redistribute. If you ship it commercially, drop me a line — I'd love to hear about it.

---

<p align="center">
  <em>"It doesn't have to be a web view."</em><br/>
  <sub>-- every macOS user, every time they launch VS Code</sub>
</p>
