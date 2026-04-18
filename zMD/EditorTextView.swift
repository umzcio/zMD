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

    // MARK: - Autocomplete

    let autocomplete = AutocompleteWindowController()
    var htmlPrefixStart: Int?

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

    // MARK: - First Responder

    /// Dismiss the autocomplete panel whenever focus leaves the editor (e.g., user clicks into
    /// another view or window deactivates). Previously the panel floated in place anchored to a
    /// stale screen point until the user clicked inside the editor again.
    override func resignFirstResponder() -> Bool {
        autocomplete.dismiss()
        htmlPrefixStart = nil
        return super.resignFirstResponder()
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

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var thinRect = rect
        thinRect.size.width = 2
        super.drawInsertionPoint(in: thinRect, color: color, turnedOn: flag)
    }

    // MARK: - Key Handling

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = event.keyCode

        // Autocomplete navigation when popup is visible
        if autocomplete.isVisible {
            if keyCode == 125 { // Down arrow
                autocomplete.moveDown()
                return
            }
            if keyCode == 126 { // Up arrow
                autocomplete.moveUp()
                return
            }
            if keyCode == 36 || keyCode == 76 { // Return / Enter
                autocomplete.confirmSelection()
                return
            }
            if keyCode == 53 { // Escape
                autocomplete.dismiss()
                return
            }
        }

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

        // Dismiss autocomplete on click
        if autocomplete.isVisible {
            autocomplete.dismiss()
            htmlPrefixStart = nil
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
                    // Wrap the newline + continuation prefix as a single undo step so that Cmd+Z
                    // reverts both together instead of leaving a stray bullet behind.
                    undoManager?.beginUndoGrouping()
                    undoManager?.setActionName("Continue List")
                    super.insertNewline(sender)
                    insertText(indent + cont, replacementRange: selectedRange())
                    undoManager?.endUndoGrouping()
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

        // Default: auto-indent (also wrapped so newline + indent are one undo step)
        if !indent.isEmpty {
            undoManager?.beginUndoGrouping()
            super.insertNewline(sender)
            insertText(indent, replacementRange: selectedRange())
            undoManager?.endUndoGrouping()
        } else {
            super.insertNewline(sender)
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

            // Insert pair and place cursor between. Route through shouldChangeText/replaceCharacters
            // /didChangeText so the delegate textDidChange fires (previously `super.insertText` here
            // bypassed our own textDidChange observers, which meant autocomplete trigger and gutter
            // redraw silently skipped on auto-closed pairs).
            let pair = char + closing
            let insertRange = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
            if shouldChangeText(in: insertRange, replacementString: pair) {
                replaceCharacters(in: insertRange, with: pair)
                setSelectedRange(NSRange(location: insertRange.location + 1, length: 0))
                didChangeText()
            }
            return
        }

        super.insertText(string, replacementRange: replacementRange)
    }

    func findWordStart(at position: Int, in text: NSString) -> Int {
        var i = position - 1
        while i >= 0 {
            let ch = text.character(at: i)
            let scalar = Unicode.Scalar(ch)
            if scalar != nil && (CharacterSet.alphanumerics.contains(scalar!) || ch == 0x5F /* _ */) {
                i -= 1
            } else {
                break
            }
        }
        return i + 1
    }

    func showCompletions(_ items: [CompletionItem], triggerStart: Int) {
        guard !items.isEmpty else {
            autocomplete.dismiss()
            return
        }

        let cursorPos = selectedRange().location
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return }

        let glyphIndex = layoutManager.glyphIndexForCharacter(at: cursorPos)
        var caretRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 0), in: textContainer)
        caretRect.origin.y += textContainerInset.height
        caretRect.origin.x += textContainerInset.width

        let pointInView = NSPoint(x: caretRect.origin.x, y: caretRect.maxY + 4)
        let pointInWindow = convert(pointInView, to: nil)
        guard let screenPoint = window?.convertPoint(toScreen: pointInWindow) else { return }

        let triggerRange = NSRange(location: triggerStart, length: cursorPos - triggerStart)
        autocomplete.show(items: items, at: screenPoint, for: self, triggerRange: triggerRange)
    }

    // MARK: - Delete Handling (remove pair)

    override func deleteBackward(_ sender: Any?) {
        // Update autocomplete state on delete
        if let start = htmlPrefixStart {
            let cursorPos = selectedRange().location
            if cursorPos <= start + 1 {
                htmlPrefixStart = nil
                autocomplete.dismiss()
            }
        } else if autocomplete.isVisible {
            autocomplete.dismiss()
        }

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

        // Track removal per line. Previously `cursorLineProcessed` flipped on the first line of
        // the selection regardless of which line the cursor actually sat on — so a multi-line
        // selection with the caret on a later line attributed the wrong removal to
        // `removedBeforeCursor` and drifted the restored selection.
        var perLineRemoved: [Int] = []

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
            perLineRemoved.append(removed)
            return result
        }.joined(separator: "\n")

        // Determine which line the cursor is on relative to `lineRange` by counting newlines
        // between `lineRange.location` and `range.location`.
        let prefixLen = range.location - lineRange.location
        let cursorLineIdx = (text.substring(with: NSRange(location: lineRange.location, length: prefixLen))
            .components(separatedBy: "\n").count) - 1

        let removedBeforeCursor = perLineRemoved.prefix(cursorLineIdx + 1).last ?? 0
        let removedBeforeStart = perLineRemoved.prefix(cursorLineIdx).reduce(0, +)
        let totalRemoved = perLineRemoved.reduce(0, +)

        if shouldChangeText(in: lineRange, replacementString: outdented) {
            replaceCharacters(in: lineRange, with: outdented)
            let newStart = max(lineRange.location, range.location - removedBeforeStart - removedBeforeCursor)
            let newLength = max(0, range.length - (totalRemoved - removedBeforeStart - removedBeforeCursor))
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

        // Collect ranges with a marker for which one is the primary. Sort descending by location so
        // each edit happens at a position the earlier edits did not shift.
        let primary = selectedRange()
        var allRanges: [(range: NSRange, isPrimary: Bool)] = multiCursorController.additionalCursors.map { ($0.range, false) }
        allRanges.append((primary, true))
        allRanges.sort { $0.range.location > $1.range.location }

        let insertedLen = (text as NSString).length
        var mapping: [(original: NSRange, newLocation: Int)] = []
        var newPrimaryLocation = primary.location

        textStorage.beginEditing()
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Multi-Cursor Insert")

        // Because we iterate descending, each edit's own new location depends only on its range's
        // location and the insertedLen (not on later edits that sit at higher positions).
        for entry in allRanges {
            if shouldChangeText(in: entry.range, replacementString: text) {
                replaceCharacters(in: entry.range, with: text)
                let newLoc = entry.range.location + insertedLen
                if entry.isPrimary {
                    newPrimaryLocation = newLoc
                } else {
                    mapping.append((original: entry.range, newLocation: newLoc))
                }
            }
        }

        undoManager?.endUndoGrouping()
        textStorage.endEditing()

        multiCursorController.updatePositions(mapping)
        setSelectedRange(NSRange(location: newPrimaryLocation, length: 0))
        didChangeText()
    }

    private func deleteAtAllCursors() {
        guard let textStorage = textStorage else { return }

        let primary = selectedRange()
        var allRanges: [(range: NSRange, isPrimary: Bool)] = multiCursorController.additionalCursors.map { ($0.range, false) }
        allRanges.append((primary, true))
        allRanges.sort { $0.range.location > $1.range.location }

        var mapping: [(original: NSRange, newLocation: Int)] = []
        var newPrimaryLocation = primary.location

        textStorage.beginEditing()
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Multi-Cursor Delete")

        for entry in allRanges {
            var deleteRange: NSRange
            if entry.range.length > 0 {
                deleteRange = entry.range
            } else if entry.range.location > 0 {
                deleteRange = NSRange(location: entry.range.location - 1, length: 1)
            } else {
                // Nothing to delete at position 0
                if entry.isPrimary {
                    newPrimaryLocation = 0
                } else {
                    mapping.append((original: entry.range, newLocation: 0))
                }
                continue
            }
            if shouldChangeText(in: deleteRange, replacementString: "") {
                replaceCharacters(in: deleteRange, with: "")
                let newLoc = deleteRange.location
                if entry.isPrimary {
                    newPrimaryLocation = newLoc
                } else {
                    mapping.append((original: entry.range, newLocation: newLoc))
                }
            }
        }

        undoManager?.endUndoGrouping()
        textStorage.endEditing()

        multiCursorController.updatePositions(mapping)
        setSelectedRange(NSRange(location: newPrimaryLocation, length: 0))
        didChangeText()
    }

    private func handleColumnSelect(event: NSEvent) {
        let startPoint = convert(event.locationInWindow, from: nil)
        let startIndex = characterIndexForInsertion(at: startPoint)

        var lastIndex = startIndex
        // Use NSWindow.trackEvents — runs in the standard event-tracking run-loop mode, times
        // out if events stop arriving, and cannot hang if the user releases outside the window.
        // The previous `while true { nextEvent(matching:) }` could spin until an unrelated event
        // arrived when the user released the mouse outside.
        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: Date.distantFuture.timeIntervalSinceNow,
            mode: .eventTracking
        ) { [weak self] nextEvent, stop in
            guard let self = self, let nextEvent = nextEvent else {
                stop.pointee = true
                return
            }
            let currentPoint = self.convert(nextEvent.locationInWindow, from: nil)
            let currentIndex = self.characterIndexForInsertion(at: currentPoint)

            if currentIndex != lastIndex {
                lastIndex = currentIndex
                self.multiCursorController.clearAll()

                if let layoutManager = self.layoutManager, let textContainer = self.textContainer {
                    let startRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: startIndex, length: 0), in: textContainer)
                    let endRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: currentIndex, length: 0), in: textContainer)

                    let minY = min(startRect.minY, endRect.minY)
                    let maxY = max(startRect.maxY, endRect.maxY)
                    let columnX = startRect.minX

                    var y = minY
                    let lineHeight = layoutManager.defaultLineHeight(for: self.font ?? NSFont.systemFont(ofSize: 14))
                    while y <= maxY {
                        let point = NSPoint(x: columnX + self.textContainerInset.width, y: y + self.textContainerInset.height)
                        let idx = self.characterIndexForInsertion(at: point)
                        self.multiCursorController.addCursor(at: NSRange(location: idx, length: 0))
                        y += lineHeight
                    }
                }
            }

            if nextEvent.type == .leftMouseUp {
                stop.pointee = true
            }
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

}
