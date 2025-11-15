import SwiftUI

struct OutlineView: View {
    let content: String
    @Binding var selectedHeadingId: String?

    var headings: [OutlineItem] {
        extractHeadings(from: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.indent")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Text("OUTLINE")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

            Divider()

            // Outline items
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(headings) { item in
                        OutlineItemView(item: item, selectedId: $selectedHeadingId)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 250)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    func extractHeadings(from markdown: String) -> [OutlineItem] {
        var items: [OutlineItem] = []
        let lines = markdown.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                var level = 0
                var text = trimmed

                // Count the number of # symbols
                for char in trimmed {
                    if char == "#" {
                        level += 1
                    } else {
                        break
                    }
                }

                // Extract the text after the # symbols
                if level > 0 {
                    text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    items.append(OutlineItem(id: "heading-\(index)", level: level, text: text))
                }
            }
        }

        return items
    }
}

struct OutlineItem: Identifiable {
    let id: String
    let level: Int
    let text: String
}

struct OutlineItemView: View {
    let item: OutlineItem
    @Binding var selectedId: String?

    var body: some View {
        Button(action: {
            selectedId = item.id
        }) {
            HStack(spacing: 6) {
                Text(item.text)
                    .font(.system(size: fontSize))
                    .foregroundColor(selectedId == item.id ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(12 + (item.level - 1) * 16))
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(selectedId == item.id ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.horizontal, 8)
    }

    var fontSize: CGFloat {
        switch item.level {
        case 1: return 14
        case 2: return 13
        case 3: return 12
        default: return 11
        }
    }
}

#Preview {
    OutlineView(content: """
    # Main Title
    ## Section 1
    ### Subsection 1.1
    ### Subsection 1.2
    ## Section 2
    # Another Title
    """, selectedHeadingId: .constant(nil))
}
