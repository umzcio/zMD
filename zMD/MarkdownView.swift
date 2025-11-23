import SwiftUI

struct MarkdownView: View {
    let content: String
    var baseURL: URL? = nil
    @StateObject private var settings = SettingsManager.shared
    @EnvironmentObject var documentManager: DocumentManager

    // Memoize parsed elements to avoid re-parsing on every render
    private var parsedElements: [MarkdownElement] {
        parseMarkdown(content)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(parsedElements, id: \.id) { element in
                            element.view(
                                fontStyle: settings.fontStyle,
                                searchText: documentManager.isSearching ? documentManager.searchText : "",
                                currentMatchIndex: documentManager.currentMatchIndex,
                                searchMatches: documentManager.searchMatches,
                                fullContent: content
                            )
                            .id(element.id)
                        }
                    }
                    .padding(.vertical, 40)
                    .padding(.horizontal, 60)
                    .frame(maxWidth: 900)
                    .frame(minWidth: geometry.size.width)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: documentManager.currentMatchIndex) { _ in
                    scrollToCurrentMatch(scrollProxy: scrollProxy)
                }
                .onChange(of: documentManager.searchMatches.count) { _ in
                    if !documentManager.searchMatches.isEmpty {
                        scrollToCurrentMatch(scrollProxy: scrollProxy)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func scrollToCurrentMatch(scrollProxy: ScrollViewProxy) {
        guard documentManager.isSearching,
              !documentManager.searchMatches.isEmpty,
              documentManager.currentMatchIndex < documentManager.searchMatches.count else {
            return
        }

        let currentMatch = documentManager.searchMatches[documentManager.currentMatchIndex]

        // Find which element contains this match
        if let elementId = findElementContainingMatch(currentMatch) {
            withAnimation {
                scrollProxy.scrollTo(elementId, anchor: .center)
            }
        }
    }

    private func findElementContainingMatch(_ match: SearchMatch) -> UUID? {
        let matchPosition = content.distance(from: content.startIndex, to: match.range.lowerBound)
        var currentPosition = 0

        for element in parsedElements {
            let elementText = element.textContent
            let elementLength = elementText.count

            if currentPosition <= matchPosition && matchPosition < currentPosition + elementLength {
                return element.id
            }

            currentPosition += elementLength + 1 // +1 for newline
        }

        return nil
    }

    func parseMarkdown(_ markdown: String) -> [MarkdownElement] {
        var elements: [MarkdownElement] = []
        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var listItems: [String] = []

        while i < lines.count {
            let line = lines[i]

            // End list if we hit a non-list item
            if !line.hasPrefix("- ") && !line.hasPrefix("* ") && !line.hasPrefix("+ ") && !listItems.isEmpty {
                elements.append(MarkdownElement(content: .list(items: listItems)))
                listItems = []
            }

            if line.hasPrefix("# ") {
                elements.append(MarkdownElement(content: .heading1(String(line.dropFirst(2)))))
            } else if line.hasPrefix("## ") {
                elements.append(MarkdownElement(content: .heading2(String(line.dropFirst(3)))))
            } else if line.hasPrefix("### ") {
                elements.append(MarkdownElement(content: .heading3(String(line.dropFirst(4)))))
            } else if line.hasPrefix("#### ") {
                elements.append(MarkdownElement(content: .heading4(String(line.dropFirst(5)))))
            } else if line.hasPrefix("|") && line.hasSuffix("|") {
                // Table detected
                var tableRows: [[String]] = []

                while i < lines.count && lines[i].hasPrefix("|") {
                    let currentLine = lines[i].trimmingCharacters(in: .whitespaces)

                    // Skip separator row (contains dashes)
                    if currentLine.contains("---") || currentLine.contains("--") {
                        i += 1
                        continue
                    }

                    let cells = currentLine
                        .split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    if !cells.isEmpty {
                        tableRows.append(cells)
                    }

                    i += 1
                }

                if !tableRows.isEmpty {
                    elements.append(MarkdownElement(content: .table(rows: tableRows)))
                }
                i -= 1 // Adjust because we'll increment at the end of the loop
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                let itemText = String(line.dropFirst(2))
                listItems.append(itemText)
            } else if line.hasPrefix("```") {
                // Code block
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                elements.append(MarkdownElement(content: .codeBlock(code: codeLines.joined(separator: "\n"))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty line
                if !listItems.isEmpty {
                    elements.append(MarkdownElement(content: .list(items: listItems)))
                    listItems = []
                }
            } else if let imageMatch = line.range(of: #"!\[([^\]]*)\]\(([^\)]+)\)"#, options: .regularExpression) {
                // Image: ![alt](path)
                let matchedString = String(line[imageMatch])
                if let altRange = matchedString.range(of: #"\[([^\]]*)\]"#, options: .regularExpression),
                   let pathRange = matchedString.range(of: #"\(([^\)]+)\)"#, options: .regularExpression) {
                    let alt = String(matchedString[altRange]).dropFirst().dropLast()
                    let path = String(matchedString[pathRange]).dropFirst().dropLast()
                    elements.append(MarkdownElement(content: .image(alt: String(alt), path: String(path), baseURL: baseURL)))
                }
            } else {
                // Regular paragraph
                elements.append(MarkdownElement(content: .paragraph(line)))
            }

            i += 1
        }

        // Add any remaining list items
        if !listItems.isEmpty {
            elements.append(MarkdownElement(content: .list(items: listItems)))
        }

        return elements
    }
}

struct MarkdownElement: Identifiable {
    let id = UUID()
    let content: MarkdownContent

    enum MarkdownContent {
        case heading1(String)
        case heading2(String)
        case heading3(String)
        case heading4(String)
        case paragraph(String)
        case list(items: [String])
        case codeBlock(code: String)
        case table(rows: [[String]])
        case image(alt: String, path: String, baseURL: URL?)
    }

    var textContent: String {
        switch content {
        case .heading1(let text), .heading2(let text), .heading3(let text), .heading4(let text), .paragraph(let text):
            return text
        case .list(let items):
            return items.joined(separator: "\n")
        case .codeBlock(let code):
            return code
        case .table(let rows):
            return rows.flatMap { $0 }.joined(separator: " ")
        case .image(let alt, _, _):
            return alt
        }
    }

    @ViewBuilder
    func view(fontStyle: SettingsManager.FontStyle, searchText: String, currentMatchIndex: Int, searchMatches: [SearchMatch], fullContent: String) -> some View {
        switch content {
        case .heading1(let text):
            VStack(alignment: .leading, spacing: 0) {
                Text(formatInlineMarkdown(text, searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: text, fullContent: fullContent))
                    .font(fontStyle.font(size: 32).weight(.semibold))
                    .padding(.bottom, 12)
                    .padding(.top, 24)
            }

        case .heading2(let text):
            VStack(alignment: .leading, spacing: 0) {
                Text(formatInlineMarkdown(text, searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: text, fullContent: fullContent))
                    .font(fontStyle.font(size: 24).weight(.semibold))
                    .padding(.bottom, 8)
                    .padding(.top, 20)
            }

        case .heading3(let text):
            Text(formatInlineMarkdown(text, searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: text, fullContent: fullContent))
                .font(fontStyle.font(size: 20).weight(.semibold))
                .padding(.bottom, 8)
                .padding(.top, 16)

        case .heading4(let text):
            Text(formatInlineMarkdown(text, searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: text, fullContent: fullContent))
                .font(fontStyle.font(size: 18).weight(.semibold))
                .padding(.bottom, 6)
                .padding(.top, 12)

        case .paragraph(let text):
            Text(formatInlineMarkdown(text, searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: text, fullContent: fullContent))
                .font(fontStyle.font(size: 16))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 12) {
                        // Check for checkbox syntax
                        if item.hasPrefix("[ ] ") {
                            Image(systemName: "square")
                                .font(fontStyle.font(size: 16))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text(formatInlineMarkdown(String(item.dropFirst(4)), searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: String(item.dropFirst(4)), fullContent: fullContent))
                                .font(fontStyle.font(size: 16))
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") {
                            Image(systemName: "checkmark.square.fill")
                                .font(fontStyle.font(size: 16))
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            Text(formatInlineMarkdown(String(item.dropFirst(4)), searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: String(item.dropFirst(4)), fullContent: fullContent))
                                .font(fontStyle.font(size: 16))
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("•")
                                .font(fontStyle.font(size: 16).weight(.bold))
                                .foregroundColor(.secondary)
                                .frame(width: 8)
                            Text(formatInlineMarkdown(item, searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: item, fullContent: fullContent))
                                .font(fontStyle.font(size: 16))
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.vertical, 4)

        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 14, design: .monospaced))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(NSColor.separatorColor).opacity(0.1))
            .cornerRadius(6)
            .padding(.vertical, 8)

        case .table(let rows):
            TableView(rows: rows, fontStyle: fontStyle)
                .padding(.vertical, 12)

        case .image(let alt, let path, let baseURL):
            ImageView(alt: alt, path: path, baseURL: baseURL)
                .padding(.vertical, 12)
        }
    }

    func formatInlineMarkdown(_ text: String, searchText: String = "", currentMatchIndex: Int = 0, searchMatches: [SearchMatch] = [], originalText: String = "", fullContent: String = "") -> AttributedString {
        // Try to create AttributedString with markdown support
        var attributed: AttributedString
        do {
            attributed = try AttributedString(markdown: text)
        } catch {
            attributed = AttributedString(text)
        }

        // Only apply search highlighting if we have valid search state
        // Skip if: no search text, no matches, or text doesn't contain search term
        if !searchText.isEmpty && !searchMatches.isEmpty && text.localizedCaseInsensitiveContains(searchText) {
            applySearchHighlighting(to: &attributed, searchText: searchText, currentMatchIndex: currentMatchIndex, searchMatches: searchMatches, originalText: originalText, fullContent: fullContent)
        }

        return attributed
    }

    func applySearchHighlighting(to attributed: inout AttributedString, searchText: String, currentMatchIndex: Int, searchMatches: [SearchMatch], originalText: String, fullContent: String) {
        let text = String(attributed.characters)
        var searchStartIndex = text.startIndex

        // Find position of originalText in fullContent to offset match indices
        guard let originalRange = fullContent.range(of: originalText, options: .caseInsensitive) else {
            return
        }

        let offsetInContent = fullContent.distance(from: fullContent.startIndex, to: originalRange.lowerBound)

        while searchStartIndex < text.endIndex {
            if let range = text.range(of: searchText, options: .caseInsensitive, range: searchStartIndex..<text.endIndex) {
                // Calculate the position of this match in the full content
                let matchPositionInText = text.distance(from: text.startIndex, to: range.lowerBound)
                let matchPositionInContent = offsetInContent + matchPositionInText

                // Check if this is the current match
                let isCurrent = searchMatches.indices.contains(currentMatchIndex) &&
                    fullContent.distance(from: fullContent.startIndex, to: searchMatches[currentMatchIndex].range.lowerBound) == matchPositionInContent

                // Convert String range to AttributedString range
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].backgroundColor = isCurrent ? .yellow : Color.yellow.opacity(0.4)
                    attributed[attrRange].foregroundColor = .black
                }

                searchStartIndex = range.upperBound
            } else {
                break
            }
        }
    }
}

struct TableView: View {
    let rows: [[String]]
    let fontStyle: SettingsManager.FontStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            Text(formatInlineMarkdown(cell))
                                .font(fontStyle.font(size: 15).weight(rowIndex == 0 ? .medium : .regular))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowIndex == 0 ? Color(NSColor.controlBackgroundColor) : Color.clear)
                                .border(Color(NSColor.separatorColor), width: 0.5)
                        }
                    }
                }
            }
        }
    }

    func formatInlineMarkdown(_ text: String) -> AttributedString {
        do {
            return try AttributedString(markdown: text)
        } catch {
            return AttributedString(text)
        }
    }
}

struct ImageView: View {
    let alt: String
    let path: String
    let baseURL: URL?

    private var imageURL: URL? {
        // Try as absolute path first
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }

        // Try as absolute file path
        let absolutePath = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: absolutePath.path) {
            return absolutePath
        }

        // Try relative to markdown file
        if let base = baseURL?.deletingLastPathComponent() {
            let relativePath = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: relativePath.path) {
                return relativePath
            }
        }

        return nil
    }

    var body: some View {
        if let url = imageURL {
            if url.isFileURL {
                // Local file
                if let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 800)
                        .cornerRadius(4)
                } else {
                    Text("⚠️ Could not load image: \(alt)")
                        .foregroundColor(.secondary)
                        .padding()
                }
            } else {
                // Remote URL
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 800)
                            .cornerRadius(4)
                    case .failure:
                        Text("⚠️ Failed to load image: \(alt)")
                            .foregroundColor(.secondary)
                            .padding()
                    @unknown default:
                        EmptyView()
                    }
                }
            }
        } else {
            Text("⚠️ Image not found: \(path)")
                .foregroundColor(.secondary)
                .padding()
        }
    }
}

#Preview {
    MarkdownView(content: """
    # Sample Markdown

    This is a **bold** text and this is *italic*.

    ## Lists

    - Item 1
    - Item 2
    - Item 3

    ## Code

    Here is some `inline code` and a code block:

    ```
    func hello() {
        print("Hello, World!")
    }
    ```
    """)
}
