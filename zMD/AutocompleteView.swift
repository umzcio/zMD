import AppKit

// MARK: - Completion Item

struct CompletionItem {
    let label: String
    let insertText: String
    let icon: String
    let description: String
    let cursorOffset: Int?    // offset from end of insertText to place cursor (negative = back)
}

// MARK: - Completion Data

struct CompletionData {

    // MARK: - Markdown Snippets

    static let markdownSnippets: [CompletionItem] = [
        // Formatting
        CompletionItem(label: "bold", insertText: "****", icon: "bold", description: "Bold text — **text**", cursorOffset: -2),
        CompletionItem(label: "italic", insertText: "**", icon: "italic", description: "Italic text — *text*", cursorOffset: -1),
        CompletionItem(label: "strikethrough", insertText: "~~~~", icon: "strikethrough", description: "Strikethrough — ~~text~~", cursorOffset: -2),
        CompletionItem(label: "highlight", insertText: "====", icon: "highlighter", description: "Highlight — ==text==", cursorOffset: -2),

        // Code
        CompletionItem(label: "codeblock", insertText: "```\n\n```", icon: "curlybraces", description: "Fenced code block", cursorOffset: -4),
        CompletionItem(label: "codeblock-js", insertText: "```javascript\n\n```", icon: "curlybraces", description: "JavaScript code block", cursorOffset: -4),
        CompletionItem(label: "codeblock-py", insertText: "```python\n\n```", icon: "curlybraces", description: "Python code block", cursorOffset: -4),
        CompletionItem(label: "codeblock-swift", insertText: "```swift\n\n```", icon: "curlybraces", description: "Swift code block", cursorOffset: -4),
        CompletionItem(label: "codeblock-bash", insertText: "```bash\n\n```", icon: "curlybraces", description: "Bash code block", cursorOffset: -4),
        CompletionItem(label: "codeinline", insertText: "``", icon: "chevron.left.forwardslash.chevron.right", description: "Inline code — `code`", cursorOffset: -1),

        // Links & media
        CompletionItem(label: "link", insertText: "[text](url)", icon: "link", description: "Hyperlink — [text](url)", cursorOffset: -6),
        CompletionItem(label: "image", insertText: "![alt](url)", icon: "photo", description: "Image — ![alt](url)", cursorOffset: -5),
        CompletionItem(label: "imagelink", insertText: "[![alt](image-url)](link-url)", icon: "photo", description: "Clickable image link", cursorOffset: -13),
        CompletionItem(label: "reference", insertText: "[text][ref]\n\n[ref]: url", icon: "link", description: "Reference-style link", cursorOffset: -4),

        // Structure
        CompletionItem(label: "heading1", insertText: "# ", icon: "textformat.size.larger", description: "Heading level 1", cursorOffset: nil),
        CompletionItem(label: "heading2", insertText: "## ", icon: "textformat.size.larger", description: "Heading level 2", cursorOffset: nil),
        CompletionItem(label: "heading3", insertText: "### ", icon: "textformat.size.larger", description: "Heading level 3", cursorOffset: nil),
        CompletionItem(label: "horizontalrule", insertText: "\n---\n", icon: "minus", description: "Horizontal rule", cursorOffset: nil),
        CompletionItem(label: "blockquote", insertText: "> ", icon: "text.quote", description: "Blockquote", cursorOffset: nil),
        CompletionItem(label: "footnote", insertText: "[^1]\n\n[^1]: ", icon: "text.append", description: "Footnote", cursorOffset: nil),

        // Lists
        CompletionItem(label: "tasklist", insertText: "- [ ] ", icon: "checklist", description: "Task list item", cursorOffset: nil),
        CompletionItem(label: "unorderedlist", insertText: "- Item 1\n- Item 2\n- Item 3", icon: "list.bullet", description: "Unordered list", cursorOffset: nil),
        CompletionItem(label: "orderedlist", insertText: "1. Item 1\n2. Item 2\n3. Item 3", icon: "list.number", description: "Ordered list", cursorOffset: nil),

        // Tables
        CompletionItem(label: "table", insertText: "| Header | Header |\n| ------ | ------ |\n| Cell   | Cell   |", icon: "tablecells", description: "Markdown table", cursorOffset: nil),
        CompletionItem(label: "table3col", insertText: "| Header | Header | Header |\n| ------ | ------ | ------ |\n| Cell   | Cell   | Cell   |", icon: "tablecells", description: "3-column table", cursorOffset: nil),

        // Other
        CompletionItem(label: "frontmatter", insertText: "---\ntitle: \ndate: \ntags: []\n---\n", icon: "doc.text", description: "YAML frontmatter", cursorOffset: nil),
        CompletionItem(label: "details", insertText: "<details>\n<summary>Click to expand</summary>\n\n</details>", icon: "chevron.down.circle", description: "Collapsible section", cursorOffset: -11),
        CompletionItem(label: "comment", insertText: "<!-- -->", icon: "bubble.left", description: "HTML comment", cursorOffset: -4),
        CompletionItem(label: "mathblock", insertText: "$$\n\n$$", icon: "function", description: "Math block (LaTeX)", cursorOffset: -3),
        CompletionItem(label: "mathinline", insertText: "$$", icon: "function", description: "Inline math (LaTeX)", cursorOffset: -1),
        CompletionItem(label: "mermaid", insertText: "```mermaid\ngraph TD\n    A --> B\n```", icon: "chart.bar", description: "Mermaid diagram", cursorOffset: -4),
    ]

    // MARK: - Build completions for a prefix

    /// Get all completions matching a prefix — words from all open docs + snippets
    static func completions(prefix: String, currentDocText: String, allDocTexts: [String]) -> [CompletionItem] {
        guard prefix.count >= 2 else { return [] }
        let lowerPrefix = prefix.lowercased()

        // 1. Snippet matches (fuzzy on label)
        let snippetMatches = markdownSnippets.filter {
            $0.label.lowercased().contains(lowerPrefix)
        }

        // 2. Word matches from all open documents
        var wordSet = Set<String>()
        for text in allDocTexts {
            let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && $0.lowercased() != lowerPrefix && $0.lowercased().hasPrefix(lowerPrefix) }
            wordSet.formUnion(words)
        }

        // Also get words from current doc with higher priority
        let currentWords = Set(
            currentDocText.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && $0.lowercased() != lowerPrefix && $0.lowercased().hasPrefix(lowerPrefix) }
        )

        // Sort: exact prefix matches first, then by length
        let sortedWords = Array(wordSet).sorted { a, b in
            let aInCurrent = currentWords.contains(a)
            let bInCurrent = currentWords.contains(b)
            if aInCurrent != bInCurrent { return aInCurrent }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }

        let wordItems = sortedWords.prefix(12).map { word in
            CompletionItem(
                label: word,
                insertText: word,
                icon: "textformat.abc",
                description: currentWords.contains(word) ? "Word" : "Word (other file)",
                cursorOffset: nil
            )
        }

        // Combine: snippets first, then words
        return Array((snippetMatches + wordItems).prefix(15))
    }

    // MARK: - HTML Tag completions (triggered by <)

    static let htmlTags: [CompletionItem] = [
        CompletionItem(label: "a", insertText: "<a href=\"\"></a>", icon: "link", description: "Hyperlink", cursorOffset: -6),
        CompletionItem(label: "b", insertText: "<b></b>", icon: "bold", description: "Bold text", cursorOffset: -4),
        CompletionItem(label: "blockquote", insertText: "<blockquote>\n\n</blockquote>", icon: "text.quote", description: "Block quotation", cursorOffset: -15),
        CompletionItem(label: "br", insertText: "<br />", icon: "arrow.turn.down.left", description: "Line break", cursorOffset: nil),
        CompletionItem(label: "code", insertText: "<code></code>", icon: "chevron.left.forwardslash.chevron.right", description: "Inline code", cursorOffset: -7),
        CompletionItem(label: "details", insertText: "<details>\n<summary></summary>\n\n</details>", icon: "chevron.down.circle", description: "Collapsible content", cursorOffset: -31),
        CompletionItem(label: "div", insertText: "<div>\n\n</div>", icon: "rectangle", description: "Division container", cursorOffset: -7),
        CompletionItem(label: "em", insertText: "<em></em>", icon: "italic", description: "Emphasized text", cursorOffset: -5),
        CompletionItem(label: "h1", insertText: "<h1></h1>", icon: "textformat.size.larger", description: "Heading 1", cursorOffset: -5),
        CompletionItem(label: "h2", insertText: "<h2></h2>", icon: "textformat.size.larger", description: "Heading 2", cursorOffset: -5),
        CompletionItem(label: "h3", insertText: "<h3></h3>", icon: "textformat.size.larger", description: "Heading 3", cursorOffset: -5),
        CompletionItem(label: "hr", insertText: "<hr />", icon: "minus", description: "Horizontal rule", cursorOffset: nil),
        CompletionItem(label: "img", insertText: "<img src=\"\" alt=\"\" />", icon: "photo", description: "Image", cursorOffset: -10),
        CompletionItem(label: "kbd", insertText: "<kbd></kbd>", icon: "keyboard", description: "Keyboard input", cursorOffset: -6),
        CompletionItem(label: "mark", insertText: "<mark></mark>", icon: "highlighter", description: "Highlight", cursorOffset: -7),
        CompletionItem(label: "p", insertText: "<p></p>", icon: "text.alignleft", description: "Paragraph", cursorOffset: -4),
        CompletionItem(label: "pre", insertText: "<pre><code>\n\n</code></pre>", icon: "curlybraces", description: "Preformatted block", cursorOffset: -14),
        CompletionItem(label: "span", insertText: "<span></span>", icon: "textformat", description: "Inline container", cursorOffset: -7),
        CompletionItem(label: "strong", insertText: "<strong></strong>", icon: "bold", description: "Strong text", cursorOffset: -9),
        CompletionItem(label: "sub", insertText: "<sub></sub>", icon: "textformat.subscript", description: "Subscript", cursorOffset: -6),
        CompletionItem(label: "sup", insertText: "<sup></sup>", icon: "textformat.superscript", description: "Superscript", cursorOffset: -6),
        CompletionItem(label: "table", insertText: "<table>\n<tr><th></th></tr>\n<tr><td></td></tr>\n</table>", icon: "tablecells", description: "Table", cursorOffset: -35),
        CompletionItem(label: "ul", insertText: "<ul>\n<li></li>\n</ul>", icon: "list.bullet", description: "Unordered list", cursorOffset: -11),
    ]

    static func htmlCompletions(prefix: String) -> [CompletionItem] {
        if prefix.isEmpty { return htmlTags }
        return htmlTags.filter { $0.label.hasPrefix(prefix.lowercased()) }
    }
}

// MARK: - Autocomplete Window

class AutocompleteWindowController: NSObject {
    private var window: NSWindow?
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var descriptionField: NSTextField!
    private var items: [CompletionItem] = []
    private var selectedIndex = 0
    private weak var editorTextView: EditorTextView?
    private var triggerRange: NSRange = NSRange(location: 0, length: 0)

    var isVisible: Bool { window?.isVisible ?? false }

    func show(items: [CompletionItem], at screenPoint: NSPoint, for editor: EditorTextView, triggerRange: NSRange) {
        guard !items.isEmpty else {
            dismiss()
            return
        }

        self.items = items
        self.editorTextView = editor
        self.triggerRange = triggerRange
        self.selectedIndex = 0

        if window == nil {
            setupWindow()
        }

        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateDescription()

        let rowHeight: CGFloat = 26
        let descHeight: CGFloat = 44
        let maxVisible = min(items.count, 8)
        let tableHeight = CGFloat(maxVisible) * rowHeight
        let windowHeight = tableHeight + descHeight + 2
        let windowWidth: CGFloat = 280

        let origin = NSPoint(x: screenPoint.x - 20, y: screenPoint.y - windowHeight)
        window?.setFrame(NSRect(origin: origin, size: NSSize(width: windowWidth, height: windowHeight)), display: true)
        window?.orderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
        items = []
    }

    func moveUp() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
        updateDescription()
    }

    func moveDown() {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % items.count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
        updateDescription()
    }

    func confirmSelection() {
        guard selectedIndex < items.count, let editor = editorTextView else { return }
        let item = items[selectedIndex]

        if editor.shouldChangeText(in: triggerRange, replacementString: item.insertText) {
            editor.replaceCharacters(in: triggerRange, with: item.insertText)
            editor.didChangeText()

            let endPos = triggerRange.location + (item.insertText as NSString).length
            if let offset = item.cursorOffset {
                editor.setSelectedRange(NSRange(location: endPos + offset, length: 0))
            } else {
                editor.setSelectedRange(NSRange(location: endPos, length: 0))
            }
        }

        dismiss()
    }

    private func updateDescription() {
        guard selectedIndex < items.count else { return }
        descriptionField?.stringValue = items[selectedIndex].description
    }

    private func setupWindow() {
        let w = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 250),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        w.isFloatingPanel = true
        w.hidesOnDeactivate = true
        w.hasShadow = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.level = .floating

        let contentView = NSView(frame: w.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 8
        contentView.layer?.masksToBounds = true
        contentView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        contentView.layer?.borderWidth = 0.5
        contentView.layer?.borderColor = NSColor.separatorColor.cgColor

        tableView = NSTableView(frame: .zero)
        tableView.headerView = nil
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClick)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        column.isEditable = false
        tableView.addTableColumn(column)

        scrollView = NSScrollView(frame: .zero)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        descriptionField = NSTextField(wrappingLabelWithString: "")
        descriptionField.font = NSFont.systemFont(ofSize: 11)
        descriptionField.textColor = .secondaryLabelColor
        descriptionField.translatesAutoresizingMaskIntoConstraints = false
        descriptionField.maximumNumberOfLines = 2

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(scrollView)
        contentView.addSubview(separator)
        contentView.addSubview(descriptionField)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            descriptionField.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            descriptionField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            descriptionField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            descriptionField.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])

        w.contentView = contentView
        self.window = w
    }

    @objc private func tableDoubleClick() {
        confirmSelection()
    }
}

// MARK: - Table DataSource / Delegate

extension AutocompleteWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]

        let cellView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 26))

        let icon = NSImageView(frame: NSRect(x: 8, y: 3, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        icon.imageScaling = .scaleProportionallyDown
        cellView.addSubview(icon)

        let label = NSTextField(labelWithString: item.label)
        label.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.frame = NSRect(x: 32, y: 3, width: 220, height: 20)
        label.lineBreakMode = .byTruncatingTail
        cellView.addSubview(label)

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 {
            selectedIndex = row
            updateDescription()
        }
    }
}
