import SwiftUI

struct MarkdownView: View {
    let content: String

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(parseMarkdown(content), id: \.id) { element in
                        element.view
                    }
                }
                .padding(.vertical, 40)
                .padding(.horizontal, 60)
                .frame(maxWidth: 900)
                .frame(minWidth: geometry.size.width)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .textSelection(.enabled)
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
    }

    @ViewBuilder
    var view: some View {
        switch content {
        case .heading1(let text):
            VStack(alignment: .leading, spacing: 0) {
                Text(formatInlineMarkdown(text))
                    .font(.system(size: 32, weight: .semibold))
                    .padding(.bottom, 12)
                    .padding(.top, 24)
            }

        case .heading2(let text):
            VStack(alignment: .leading, spacing: 0) {
                Text(formatInlineMarkdown(text))
                    .font(.system(size: 24, weight: .semibold))
                    .padding(.bottom, 8)
                    .padding(.top, 20)
            }

        case .heading3(let text):
            Text(formatInlineMarkdown(text))
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 8)
                .padding(.top, 16)

        case .heading4(let text):
            Text(formatInlineMarkdown(text))
                .font(.system(size: 18, weight: .semibold))
                .padding(.bottom, 6)
                .padding(.top, 12)

        case .paragraph(let text):
            Text(formatInlineMarkdown(text))
                .font(.system(size: 16))
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
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text(formatInlineMarkdown(String(item.dropFirst(4))))
                                .font(.system(size: 16))
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if item.hasPrefix("[x] ") || item.hasPrefix("[X] ") {
                            Image(systemName: "checkmark.square.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            Text(formatInlineMarkdown(String(item.dropFirst(4))))
                                .font(.system(size: 16))
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("•")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(.secondary)
                                .frame(width: 8)
                            Text(formatInlineMarkdown(item))
                                .font(.system(size: 16))
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
            TableView(rows: rows)
                .padding(.vertical, 12)
        }
    }

    func formatInlineMarkdown(_ text: String) -> AttributedString {
        var result = text

        // Handle bold **text**
        while let boldRange = result.range(of: #"\*\*[^\*]+\*\*"#, options: .regularExpression) {
            let boldText = result[boldRange].dropFirst(2).dropLast(2)
            result.replaceSubrange(boldRange, with: String(boldText))
        }

        // Handle italic *text*
        while let italicRange = result.range(of: #"\*[^\*]+\*"#, options: .regularExpression) {
            let italicText = result[italicRange].dropFirst().dropLast()
            result.replaceSubrange(italicRange, with: String(italicText))
        }

        // Handle inline code `text`
        while let codeRange = result.range(of: #"`[^`]+`"#, options: .regularExpression) {
            let codeText = result[codeRange].dropFirst().dropLast()
            result.replaceSubrange(codeRange, with: String(codeText))
        }

        // Try to create AttributedString with markdown support
        do {
            return try AttributedString(markdown: text)
        } catch {
            return AttributedString(text)
        }
    }
}

struct TableView: View {
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIndex, cell in
                            Text(formatInlineMarkdown(cell))
                                .font(.system(size: 15, weight: rowIndex == 0 ? .medium : .regular))
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
