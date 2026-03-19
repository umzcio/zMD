import AppKit

// MARK: - Notification Names for Editor Formatting

extension Notification.Name {
    static let editorFormatBold = Notification.Name("editorFormatBold")
    static let editorFormatItalic = Notification.Name("editorFormatItalic")
    static let editorFormatStrikethrough = Notification.Name("editorFormatStrikethrough")
    static let editorFormatInlineCode = Notification.Name("editorFormatInlineCode")
    static let editorFormatCodeBlock = Notification.Name("editorFormatCodeBlock")
    static let editorInsertLink = Notification.Name("editorInsertLink")
    static let editorInsertImage = Notification.Name("editorInsertImage")
    static let editorInsertHR = Notification.Name("editorInsertHR")
    static let editorToggleHeading = Notification.Name("editorToggleHeading")
    static let editorInsertUnorderedList = Notification.Name("editorInsertUnorderedList")
    static let editorInsertOrderedList = Notification.Name("editorInsertOrderedList")
    static let editorInsertTaskList = Notification.Name("editorInsertTaskList")
    static let editorFindAndReplace = Notification.Name("editorFindAndReplace")
}

// MARK: - EditorTextView

class EditorTextView: NSTextView {

    // MARK: - Settings

    var tabWidth: Int = 4
    var autoCloseBrackets: Bool = true
    var showCurrentLineHighlight: Bool = true

    // MARK: - Multi-cursor

    var multiCursorController = MultiCursorController()

    // MARK: - Current line highlight

    private var currentLineHighlightColor: NSColor {
        if effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor.white.withAlphaComponent(0.04)
        } else {
            return NSColor.black.withAlphaComponent(0.04)
        }
    }

    // MARK: - Auto-close pairs

    private let autoClosePairs: [String: String] = [
        "(": ")",
        "[": "]",
        "{": "}",
        "\"": "\"",
        "`": "`",
    ]

    private let closingChars: Set<Character> = [")", "]", "}", "\"", "`"]

    // MARK: - Initialization

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        smartInsertDeleteEnabled = false
        usesFindBar = false

        registerForNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notification Handling

    private func registerForNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleFormatBold), name: .editorFormatBold, object: nil)
        nc.addObserver(self, selector: #selector(handleFormatItalic), name: .editorFormatItalic, object: nil)
        nc.addObserver(self, selector: #selector(handleFormatStrikethrough), name: .editorFormatStrikethrough, object: nil)
        nc.addObserver(self, selector: #selector(handleFormatInlineCode), name: .editorFormatInlineCode, object: nil)
        nc.addObserver(self, selector: #selector(handleFormatCodeBlock), name: .editorFormatCodeBlock, object: nil)
        nc.addObserver(self, selector: #selector(handleInsertLink), name: .editorInsertLink, object: nil)
        nc.addObserver(self, selector: #selector(handleInsertImage), name: .editorInsertImage, object: nil)
        nc.addObserver(self, selector: #selector(handleInsertHR), name: .editorInsertHR, object: nil)
        nc.addObserver(self, selector: #selector(handleToggleHeading), name: .editorToggleHeading, object: nil)
        nc.addObserver(self, selector: #selector(handleInsertUnorderedList), name: .editorInsertUnorderedList, object: nil)
        nc.addObserver(self, selector: #selector(handleInsertOrderedList), name: .editorInsertOrderedList, object: nil)
        nc.addObserver(self, selector: #selector(handleInsertTaskList), name: .editorInsertTaskList, object: nil)
    }

    // MARK: - Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard showCurrentLineHighlight, let layoutManager = layoutManager, let textContainer = textContainer else { return }

        // Draw current line highlight
        let selectedRange = selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: selectedRange, actualCharacterRange: nil)

        var lineRect = layoutManager.lineFragmentRect(forGlyphAt: max(0, glyphRange.location), effectiveRange: nil)
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerInset.height

        currentLineHighlightColor.setFill()
        lineRect.fill()

        // Draw multi-cursor highlights
        for cursor in multiCursorController.additionalCursors {
            if cursor.range.location < (string as NSString).length {
                var cursorLineRect = layoutManager.lineFragmentRect(forGlyphAt: cursor.range.location, effectiveRange: nil)
                cursorLineRect.origin.x = 0
                cursorLineRect.size.width = bounds.width
                cursorLineRect.origin.y += textContainerInset.height
                currentLineHighlightColor.setFill()
                cursorLineRect.fill()
            }
        }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Draw primary cursor
        var thinRect = rect
        thinRect.size.width = 2
        super.drawInsertionPoint(in: thinRect, color: color, turnedOn: flag)

        // Draw additional cursors
        guard let layoutManager = layoutManager else { return }

        for cursor in multiCursorController.additionalCursors {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: cursor.range.location)
            var cursorRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 0), in: textContainer!)
            cursorRect.origin.y += textContainerInset.height
            cursorRect.origin.x += textContainerInset.width
            cursorRect.size.width = 2
            cursorRect.size.height = rect.height

            if flag {
                color.setFill()
                cursorRect.fill()
            }
        }
    }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        // Cmd+D: Select next occurrence
        if flags == .command && event.charactersIgnoringModifiers == "d" {
            selectNextOccurrence()
            return
        }

        // Cmd+/: Toggle comment
        if flags == .command && event.charactersIgnoringModifiers == "/" {
            toggleComment()
            return
        }

        // Cmd+Shift+Up: Move line up
        if flags == [.command, .shift] && keyCode == 126 {
            moveLineUp()
            return
        }

        // Cmd+Shift+Down: Move line down
        if flags == [.command, .shift] && keyCode == 125 {
            moveLineDown()
            return
        }

        // Cmd+]: Indent
        if flags == .command && event.charactersIgnoringModifiers == "]" {
            indentSelection()
            return
        }

        // Cmd+[: Outdent
        if flags == .command && event.charactersIgnoringModifiers == "[" {
            outdentSelection()
            return
        }

        // Cmd+B: Bold
        if flags == .command && event.charactersIgnoringModifiers == "b" {
            handleFormatBold()
            return
        }

        // Cmd+I: Italic
        if flags == .command && event.charactersIgnoringModifiers == "i" {
            handleFormatItalic()
            return
        }

        // Cmd+Shift+X: Strikethrough
        if flags == [.command, .shift] && event.charactersIgnoringModifiers == "X" {
            handleFormatStrikethrough()
            return
        }

        // Cmd+Shift+K: Inline code
        if flags == [.command, .shift] && event.charactersIgnoringModifiers == "K" {
            handleFormatInlineCode()
            return
        }

        // Cmd+Shift+L: Insert link
        if flags == [.command, .shift] && event.charactersIgnoringModifiers == "L" {
            handleInsertLink()
            return
        }

        // Escape: Collapse multi-cursor
        if keyCode == 53 && !multiCursorController.additionalCursors.isEmpty {
            multiCursorController.clearAll()
            setNeedsDisplay(bounds)
            return
        }

        // If we have multi-cursors, handle simultaneous typing
        if !multiCursorController.additionalCursors.isEmpty {
            if let chars = event.characters, !chars.isEmpty, flags.isSubset(of: [.shift]) {
                insertTextAtAllCursors(chars)
                return
            }
        }

        super.keyDown(with: event)
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd+Click: Add cursor
        if flags.contains(.command) && !flags.contains(.shift) {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            multiCursorController.addCursor(at: NSRange(location: charIndex, length: 0))
            setNeedsDisplay(bounds)
            return
        }

        // Option+Click+Drag: Column select
        if flags.contains(.option) {
            handleColumnSelect(event: event)
            return
        }

        // Normal click: clear multi-cursors
        if !multiCursorController.additionalCursors.isEmpty {
            multiCursorController.clearAll()
            setNeedsDisplay(bounds)
        }

        super.mouseDown(with: event)
    }

    // MARK: - Tab Handling

    override func insertTab(_ sender: Any?) {
        let range = selectedRange()

        // If there's a multi-line selection, indent all lines
        if range.length > 0 {
            let text = string as NSString
            let selectedText = text.substring(with: range)
            if selectedText.contains("\n") {
                indentSelection()
                return
            }
        }

        // Insert spaces instead of tab
        let spaces = String(repeating: " ", count: tabWidth)
        insertText(spaces, replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        outdentSelection()
    }

    // MARK: - Newline with Auto-indent + List Continuation

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        let currentLine = text.substring(with: lineRange)

        // Extract leading whitespace
        var indent = ""
        for char in currentLine {
            if char == " " || char == "\t" {
                indent.append(char)
            } else {
                break
            }
        }

        let trimmedLine = currentLine.trimmingCharacters(in: .whitespaces)

        // Check for list patterns
        let listPatterns: [(pattern: String, continuation: (String) -> String?)] = [
            // Task list: - [ ] or - [x]
            (#"^- \[[ xX]\] (.+)$"#, { _ in "- [ ] " }),
            // Unordered list: - or * or +
            (#"^([-*+]) (.+)$"#, { match in
                let marker = String(match.dropFirst().prefix(1))
                return "\(marker) "
            }),
            // Ordered list: 1.
            (#"^(\d+)\. (.+)$"#, { match in
                if let num = Int(match.prefix(while: { $0.isNumber })) {
                    return "\(num + 1). "
                }
                return nil
            }),
            // Empty list item (just marker, no content) — stop the list
            (#"^[-*+] $"#, { _ in nil }),
            (#"^- \[[ xX]\] $"#, { _ in nil }),
            (#"^\d+\. $"#, { _ in nil }),
        ]

        for (pattern, continuation) in listPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: trimmedLine, range: NSRange(location: 0, length: (trimmedLine as NSString).length)) != nil {
                if let cont = continuation(trimmedLine) {
                    super.insertNewline(sender)
                    insertText(indent + cont, replacementRange: selectedRange())
                    return
                } else {
                    // Empty list item — delete it and just insert newline
                    let deleteRange = NSRange(location: lineRange.location, length: lineRange.length)
                    if shouldChangeText(in: deleteRange, replacementString: "\n") {
                        replaceCharacters(in: deleteRange, with: "\n")
                        didChangeText()
                    }
                    return
                }
            }
        }

        // Default: auto-indent
        super.insertNewline(sender)
        if !indent.isEmpty {
            insertText(indent, replacementRange: selectedRange())
        }
    }

    // MARK: - Auto-close Brackets

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let str = string as? String, str.count == 1, autoCloseBrackets else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        let char = str

        // Skip over closing bracket if next char matches
        if let c = char.first, closingChars.contains(c) {
            let text = self.string as NSString
            let cursorPos = selectedRange().location
            if cursorPos < text.length {
                let nextChar = text.substring(with: NSRange(location: cursorPos, length: 1))
                if nextChar == char {
                    setSelectedRange(NSRange(location: cursorPos + 1, length: 0))
                    return
                }
            }
        }

        // Auto-close: insert pair
        if let closing = autoClosePairs[char] {
            let range = selectedRange()

            // For quotes and backticks, only auto-close if not already inside a pair
            if char == "\"" || char == "`" {
                let text = self.string as NSString
                let cursorPos = range.location
                // Check if next char is same — skip instead
                if cursorPos < text.length {
                    let nextChar = text.substring(with: NSRange(location: cursorPos, length: 1))
                    if nextChar == char {
                        setSelectedRange(NSRange(location: cursorPos + 1, length: 0))
                        return
                    }
                }
            }

            // If there's a selection, wrap it
            if range.length > 0 {
                let text = self.string as NSString
                let selected = text.substring(with: range)
                let wrapped = char + selected + closing
                if shouldChangeText(in: range, replacementString: wrapped) {
                    replaceCharacters(in: range, with: wrapped)
                    setSelectedRange(NSRange(location: range.location + 1, length: range.length))
                    didChangeText()
                }
                return
            }

            // Insert pair and place cursor between
            let pair = char + closing
            super.insertText(pair, replacementRange: replacementRange)
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
            return
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: - Delete Handling (remove pair)

    override func deleteBackward(_ sender: Any?) {
        if autoCloseBrackets {
            let text = string as NSString
            let cursorPos = selectedRange().location
            if cursorPos > 0 && cursorPos < text.length {
                let prevChar = text.substring(with: NSRange(location: cursorPos - 1, length: 1))
                let nextChar = text.substring(with: NSRange(location: cursorPos, length: 1))
                if let closing = autoClosePairs[prevChar], closing == nextChar {
                    // Delete both chars
                    let deleteRange = NSRange(location: cursorPos - 1, length: 2)
                    if shouldChangeText(in: deleteRange, replacementString: "") {
                        replaceCharacters(in: deleteRange, with: "")
                        didChangeText()
                    }
                    return
                }
            }
        }

        // Handle multi-cursor delete
        if !multiCursorController.additionalCursors.isEmpty {
            deleteAtAllCursors()
            return
        }

        super.deleteBackward(sender)
    }

    // MARK: - Format Actions

    @objc func handleFormatBold() {
        wrapSelectionWith("**", "**", placeholder: "bold text")
    }

    @objc func handleFormatItalic() {
        wrapSelectionWith("*", "*", placeholder: "italic text")
    }

    @objc func handleFormatStrikethrough() {
        wrapSelectionWith("~~", "~~", placeholder: "strikethrough text")
    }

    @objc func handleFormatInlineCode() {
        wrapSelectionWith("`", "`", placeholder: "code")
    }

    @objc func handleFormatCodeBlock() {
        let range = selectedRange()
        let text = string as NSString

        if range.length > 0 {
            let selected = text.substring(with: range)
            let replacement = "```\n\(selected)\n```"
            if shouldChangeText(in: range, replacementString: replacement) {
                replaceCharacters(in: range, with: replacement)
                didChangeText()
            }
        } else {
            let insertion = "```\n\n```"
            if shouldChangeText(in: range, replacementString: insertion) {
                replaceCharacters(in: range, with: insertion)
                setSelectedRange(NSRange(location: range.location + 4, length: 0))
                didChangeText()
            }
        }
    }

    @objc func handleInsertLink() {
        let range = selectedRange()
        let text = string as NSString

        if range.length > 0 {
            let selected = text.substring(with: range)
            let replacement = "[\(selected)](url)"
            if shouldChangeText(in: range, replacementString: replacement) {
                replaceCharacters(in: range, with: replacement)
                // Select "url" for easy replacement
                let urlStart = range.location + selected.count + 3
                setSelectedRange(NSRange(location: urlStart, length: 3))
                didChangeText()
            }
        } else {
            let insertion = "[link text](url)"
            if shouldChangeText(in: range, replacementString: insertion) {
                replaceCharacters(in: range, with: insertion)
                setSelectedRange(NSRange(location: range.location + 1, length: 9))
                didChangeText()
            }
        }
    }

    @objc func handleInsertImage() {
        let range = selectedRange()
        let text = string as NSString

        if range.length > 0 {
            let selected = text.substring(with: range)
            let replacement = "![\(selected)](image-url)"
            if shouldChangeText(in: range, replacementString: replacement) {
                replaceCharacters(in: range, with: replacement)
                let urlStart = range.location + selected.count + 4
                setSelectedRange(NSRange(location: urlStart, length: 9))
                didChangeText()
            }
        } else {
            let insertion = "![alt text](image-url)"
            if shouldChangeText(in: range, replacementString: insertion) {
                replaceCharacters(in: range, with: insertion)
                setSelectedRange(NSRange(location: range.location + 2, length: 8))
                didChangeText()
            }
        }
    }

    @objc func handleInsertHR() {
        let range = selectedRange()
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))

        // Ensure we're on a new line
        var prefix = ""
        if lineRange.location < range.location || (lineRange.length > 0 && text.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines) != "") {
            prefix = "\n"
        }

        let insertion = prefix + "\n---\n\n"
        if shouldChangeText(in: range, replacementString: insertion) {
            replaceCharacters(in: range, with: insertion)
            setSelectedRange(NSRange(location: range.location + insertion.count, length: 0))
            didChangeText()
        }
    }

    @objc func handleToggleHeading() {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: range.location, length: 0))
        let line = text.substring(with: lineRange)

        // Count existing heading level
        var headingLevel = 0
        for char in line {
            if char == "#" { headingLevel += 1 }
            else { break }
        }

        var newLine: String
        if headingLevel == 0 {
            newLine = "# " + line
        } else if headingLevel >= 6 {
            // Remove heading
            newLine = String(line.dropFirst(headingLevel))
            if newLine.hasPrefix(" ") { newLine = String(newLine.dropFirst()) }
        } else {
            // Increment heading level
            newLine = "#" + line
        }

        if shouldChangeText(in: lineRange, replacementString: newLine) {
            replaceCharacters(in: lineRange, with: newLine)
            didChangeText()
        }
    }

    @objc func handleInsertUnorderedList() {
        insertListPrefix("- ")
    }

    @objc func handleInsertOrderedList() {
        insertListPrefix("1. ")
    }

    @objc func handleInsertTaskList() {
        insertListPrefix("- [ ] ")
    }

    // MARK: - Editor Operations

    private func toggleComment() {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: range)
        let lines = text.substring(with: lineRange)

        let lineArray = lines.components(separatedBy: "\n")
        var resultLines: [String] = []
        let commentPrefix = "<!-- "
        let commentSuffix = " -->"

        // Check if all non-empty lines are commented
        let nonEmptyLines = lineArray.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = nonEmptyLines.allSatisfy {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix(commentPrefix) && trimmed.hasSuffix(commentSuffix)
        }

        for line in lineArray {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                resultLines.append(line)
                continue
            }

            if allCommented {
                // Uncomment
                if trimmed.hasPrefix(commentPrefix) && trimmed.hasSuffix(commentSuffix) {
                    let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                    var content = trimmed
                    content = String(content.dropFirst(commentPrefix.count))
                    content = String(content.dropLast(commentSuffix.count))
                    resultLines.append(indent + content)
                } else {
                    resultLines.append(line)
                }
            } else {
                // Comment
                let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
                let content = line.trimmingCharacters(in: .whitespaces)
                resultLines.append(indent + commentPrefix + content + commentSuffix)
            }
        }

        let newText = resultLines.joined(separator: "\n")
        if shouldChangeText(in: lineRange, replacementString: newText) {
            replaceCharacters(in: lineRange, with: newText)
            didChangeText()
        }
    }

    private func moveLineUp() {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: range)

        guard lineRange.location > 0 else { return }

        let prevLineRange = text.lineRange(for: NSRange(location: lineRange.location - 1, length: 0))
        let currentLine = text.substring(with: lineRange)
        let prevLine = text.substring(with: prevLineRange)

        let combinedRange = NSRange(location: prevLineRange.location, length: prevLineRange.length + lineRange.length)
        var newText: String
        if currentLine.hasSuffix("\n") {
            newText = currentLine + prevLine
        } else {
            // Last line doesn't have trailing newline
            let cleanPrev = prevLine.hasSuffix("\n") ? String(prevLine.dropLast()) : prevLine
            newText = currentLine + "\n" + cleanPrev
        }

        if shouldChangeText(in: combinedRange, replacementString: newText) {
            replaceCharacters(in: combinedRange, with: newText)
            let newSelStart = prevLineRange.location + (range.location - lineRange.location)
            setSelectedRange(NSRange(location: newSelStart, length: range.length))
            didChangeText()
        }
    }

    private func moveLineDown() {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: range)
        let lineEnd = lineRange.location + lineRange.length

        guard lineEnd < text.length else { return }

        let nextLineRange = text.lineRange(for: NSRange(location: lineEnd, length: 0))
        let currentLine = text.substring(with: lineRange)
        let nextLine = text.substring(with: nextLineRange)

        let combinedRange = NSRange(location: lineRange.location, length: lineRange.length + nextLineRange.length)
        var newText: String
        if nextLine.hasSuffix("\n") {
            newText = nextLine + currentLine
        } else {
            // Next line is last line (no trailing newline)
            let cleanCurrent = currentLine.hasSuffix("\n") ? String(currentLine.dropLast()) : currentLine
            newText = nextLine + "\n" + cleanCurrent
        }

        if shouldChangeText(in: combinedRange, replacementString: newText) {
            replaceCharacters(in: combinedRange, with: newText)
            let newSelStart = lineRange.location + nextLineRange.length + (range.location - lineRange.location)
            setSelectedRange(NSRange(location: newSelStart, length: range.length))
            didChangeText()
        }
    }

    private func indentSelection() {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: range)
        let lines = text.substring(with: lineRange)
        let indent = String(repeating: " ", count: tabWidth)

        let indented = lines.components(separatedBy: "\n").enumerated().map { (index, line) -> String in
            // Don't indent the last empty line from split
            if index > 0 && line.isEmpty && index == lines.components(separatedBy: "\n").count - 1 {
                return line
            }
            return indent + line
        }.joined(separator: "\n")

        if shouldChangeText(in: lineRange, replacementString: indented) {
            replaceCharacters(in: lineRange, with: indented)
            // Adjust selection
            let linesCount = lines.components(separatedBy: "\n").count
            setSelectedRange(NSRange(location: range.location + tabWidth, length: range.length + tabWidth * (linesCount - 1)))
            didChangeText()
        }
    }

    private func outdentSelection() {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: range)
        let lines = text.substring(with: lineRange)

        var removedBeforeCursor = 0
        var totalRemoved = 0
        var cursorLineProcessed = false

        let outdented = lines.components(separatedBy: "\n").map { line -> String in
            var removed = 0
            var result = line
            for _ in 0..<tabWidth {
                if result.hasPrefix(" ") {
                    result = String(result.dropFirst())
                    removed += 1
                } else if result.hasPrefix("\t") {
                    result = String(result.dropFirst())
                    removed += 1
                    break
                } else {
                    break
                }
            }
            if !cursorLineProcessed {
                removedBeforeCursor = removed
                cursorLineProcessed = true
            }
            totalRemoved += removed
            return result
        }.joined(separator: "\n")

        if shouldChangeText(in: lineRange, replacementString: outdented) {
            replaceCharacters(in: lineRange, with: outdented)
            let newStart = max(lineRange.location, range.location - removedBeforeCursor)
            let newLength = max(0, range.length - (totalRemoved - removedBeforeCursor))
            setSelectedRange(NSRange(location: newStart, length: newLength))
            didChangeText()
        }
    }

    // MARK: - Multi-cursor Operations

    private func selectNextOccurrence() {
        let text = string as NSString

        if selectedRange().length == 0 {
            // Select word under cursor
            let wordRange = selectionRange(forProposedRange: selectedRange(), granularity: .selectByWord)
            setSelectedRange(wordRange)
            return
        }

        // Find next occurrence of selected text
        let selectedText = text.substring(with: selectedRange())
        let searchStart = selectedRange().location + selectedRange().length
        var searchRange = NSRange(location: searchStart, length: text.length - searchStart)

        var found = text.range(of: selectedText, options: [], range: searchRange)
        if found.location == NSNotFound {
            // Wrap around
            searchRange = NSRange(location: 0, length: selectedRange().location)
            found = text.range(of: selectedText, options: [], range: searchRange)
        }

        if found.location != NSNotFound {
            multiCursorController.addCursor(at: found)
            // Scroll to show the new cursor
            scrollRangeToVisible(found)
            setNeedsDisplay(bounds)
        }
    }

    private func insertTextAtAllCursors(_ text: String) {
        guard let textStorage = textStorage else { return }

        // Collect all ranges (primary + additional), sort in reverse order
        var allRanges = multiCursorController.additionalCursors.map { $0.range }
        allRanges.append(selectedRange())
        allRanges.sort { $0.location > $1.location }

        textStorage.beginEditing()

        for range in allRanges {
            if shouldChangeText(in: range, replacementString: text) {
                replaceCharacters(in: range, with: text)
            }
        }

        textStorage.endEditing()

        // Adjust cursor positions
        multiCursorController.adjustAfterInsert(insertedLength: (text as NSString).length, deletedLength: allRanges.first?.length ?? 0)
        didChangeText()
    }

    private func deleteAtAllCursors() {
        guard let textStorage = textStorage else { return }

        var allRanges = multiCursorController.additionalCursors.map { $0.range }
        allRanges.append(selectedRange())
        allRanges.sort { $0.location > $1.location }

        textStorage.beginEditing()

        for range in allRanges {
            if range.length > 0 {
                if shouldChangeText(in: range, replacementString: "") {
                    replaceCharacters(in: range, with: "")
                }
            } else if range.location > 0 {
                let deleteRange = NSRange(location: range.location - 1, length: 1)
                if shouldChangeText(in: deleteRange, replacementString: "") {
                    replaceCharacters(in: deleteRange, with: "")
                }
            }
        }

        textStorage.endEditing()
        multiCursorController.adjustAfterDelete()
        didChangeText()
    }

    private func handleColumnSelect(event: NSEvent) {
        let startPoint = convert(event.locationInWindow, from: nil)
        let startIndex = characterIndexForInsertion(at: startPoint)

        // Track mouse drag
        var lastIndex = startIndex
        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }

            let currentPoint = convert(nextEvent.locationInWindow, from: nil)
            let currentIndex = characterIndexForInsertion(at: currentPoint)

            if currentIndex != lastIndex {
                lastIndex = currentIndex
                // Build column selection across lines
                multiCursorController.clearAll()

                guard let layoutManager = layoutManager, let textContainer = textContainer else { break }

                let startRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: startIndex, length: 0), in: textContainer)
                let endRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: currentIndex, length: 0), in: textContainer)

                let minY = min(startRect.minY, endRect.minY)
                let maxY = max(startRect.maxY, endRect.maxY)
                let columnX = startRect.minX

                // Add cursor on each line within the vertical range
                var y = minY
                while y <= maxY {
                    let point = NSPoint(x: columnX + textContainerInset.width, y: y + textContainerInset.height)
                    let idx = characterIndexForInsertion(at: point)
                    multiCursorController.addCursor(at: NSRange(location: idx, length: 0))
                    y += layoutManager.defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 14))
                }
            }

            if nextEvent.type == .leftMouseUp { break }
        }

        setNeedsDisplay(bounds)
    }

    // MARK: - Helpers

    private func wrapSelectionWith(_ prefix: String, _ suffix: String, placeholder: String) {
        let range = selectedRange()
        let text = string as NSString
        let prefixLen = (prefix as NSString).length
        let suffixLen = (suffix as NSString).length

        if range.length > 0 {
            let selected = text.substring(with: range)

            // Check if already wrapped — unwrap
            if range.location >= prefixLen &&
               range.location + range.length + suffixLen <= text.length {
                let beforeRange = NSRange(location: range.location - prefixLen, length: prefixLen)
                let afterRange = NSRange(location: range.location + range.length, length: suffixLen)
                let before = text.substring(with: beforeRange)
                let after = text.substring(with: afterRange)
                if before == prefix && after == suffix {
                    // Unwrap
                    let fullRange = NSRange(location: beforeRange.location, length: prefixLen + range.length + suffixLen)
                    if shouldChangeText(in: fullRange, replacementString: selected) {
                        replaceCharacters(in: fullRange, with: selected)
                        setSelectedRange(NSRange(location: beforeRange.location, length: range.length))
                        didChangeText()
                    }
                    return
                }
            }

            // Wrap selection
            let wrapped = prefix + selected + suffix
            if shouldChangeText(in: range, replacementString: wrapped) {
                replaceCharacters(in: range, with: wrapped)
                setSelectedRange(NSRange(location: range.location + prefixLen, length: range.length))
                didChangeText()
            }
        } else {
            // Insert with placeholder
            let insertion = prefix + placeholder + suffix
            if shouldChangeText(in: range, replacementString: insertion) {
                replaceCharacters(in: range, with: insertion)
                setSelectedRange(NSRange(location: range.location + prefixLen, length: (placeholder as NSString).length))
                didChangeText()
            }
        }
    }

    private func insertListPrefix(_ prefix: String) {
        let text = string as NSString
        let range = selectedRange()
        let lineRange = text.lineRange(for: range)
        let line = text.substring(with: lineRange)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // If already has this prefix, remove it
        if trimmed.hasPrefix(prefix) {
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let content = String(trimmed.dropFirst(prefix.count))
            let newLine = indent + content
            if shouldChangeText(in: lineRange, replacementString: newLine) {
                replaceCharacters(in: lineRange, with: newLine)
                didChangeText()
            }
        } else {
            // Add prefix
            let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
            let content = line.trimmingCharacters(in: .whitespaces)
            let newLine = indent + prefix + content
            if shouldChangeText(in: lineRange, replacementString: newLine) {
                replaceCharacters(in: lineRange, with: newLine)
                didChangeText()
            }
        }
    }

    // MARK: - Selection changed — redraw for line highlight

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        setNeedsDisplay(bounds)
    }
}
