import SwiftUI

struct MarkdownToolbarView: View {
    var body: some View {
        HStack(spacing: 2) {
            // Headings
            ToolbarButton(icon: "number", tooltip: "Toggle Heading") {
                NotificationCenter.default.post(name: .editorToggleHeading, object: nil)
            }

            ToolbarDivider()

            // Text formatting
            ToolbarButton(icon: "bold", tooltip: "Bold (⌘B)") {
                NotificationCenter.default.post(name: .editorFormatBold, object: nil)
            }

            ToolbarButton(icon: "italic", tooltip: "Italic (⌘I)") {
                NotificationCenter.default.post(name: .editorFormatItalic, object: nil)
            }

            ToolbarButton(icon: "strikethrough", tooltip: "Strikethrough (⌘⇧X)") {
                NotificationCenter.default.post(name: .editorFormatStrikethrough, object: nil)
            }

            ToolbarButton(icon: "chevron.left.forwardslash.chevron.right", tooltip: "Inline Code (⌘⇧K)") {
                NotificationCenter.default.post(name: .editorFormatInlineCode, object: nil)
            }

            ToolbarDivider()

            // Insert elements
            ToolbarButton(icon: "link", tooltip: "Insert Link (⌘⇧L)") {
                NotificationCenter.default.post(name: .editorInsertLink, object: nil)
            }

            ToolbarButton(icon: "photo", tooltip: "Insert Image") {
                NotificationCenter.default.post(name: .editorInsertImage, object: nil)
            }

            ToolbarDivider()

            // Lists
            ToolbarButton(icon: "list.bullet", tooltip: "Unordered List") {
                NotificationCenter.default.post(name: .editorInsertUnorderedList, object: nil)
            }

            ToolbarButton(icon: "list.number", tooltip: "Ordered List") {
                NotificationCenter.default.post(name: .editorInsertOrderedList, object: nil)
            }

            ToolbarButton(icon: "checklist", tooltip: "Task List") {
                NotificationCenter.default.post(name: .editorInsertTaskList, object: nil)
            }

            ToolbarDivider()

            // Code block & HR
            ToolbarButton(icon: "curlybraces", tooltip: "Code Block") {
                NotificationCenter.default.post(name: .editorFormatCodeBlock, object: nil)
            }

            ToolbarButton(icon: "minus", tooltip: "Horizontal Rule") {
                NotificationCenter.default.post(name: .editorInsertHR, object: nil)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Toolbar Button

private struct ToolbarButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary.opacity(0.75))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Toolbar Divider

private struct ToolbarDivider: View {
    var body: some View {
        Divider()
            .frame(height: 16)
            .padding(.horizontal, 4)
    }
}
