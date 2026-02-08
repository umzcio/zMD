import SwiftUI

struct OutlineView: View {
    let content: String
    @Binding var selectedHeadingId: String?
    @State private var headings: [OutlineItem] = []

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
        .background(.ultraThinMaterial)
        .onAppear { headings = OutlineItem.extractHeadings(from: content) }
        .onChange(of: content) { _ in headings = OutlineItem.extractHeadings(from: content) }
    }
}

struct OutlineItem: Identifiable {
    let id: String
    let level: Int
    let text: String

    static func extractHeadings(from markdown: String) -> [OutlineItem] {
        var items: [OutlineItem] = []
        let lines = markdown.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                var level = 0

                for char in trimmed {
                    if char == "#" {
                        level += 1
                    } else {
                        break
                    }
                }

                if level > 0 {
                    let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    items.append(OutlineItem(id: "heading-\(index)", level: level, text: text))
                }
            }
        }

        return items
    }
}

struct OutlineItemView: View {
    let item: OutlineItem
    @Binding var selectedId: String?
    @State private var isHovered = false

    private var isActive: Bool {
        selectedId == item.id
    }

    var body: some View {
        Button(action: {
            selectedId = item.id
        }) {
            HStack(spacing: 6) {
                Text(item.text)
                    .font(.system(size: fontSize))
                    .foregroundColor(isActive ? .primary : (isHovered ? .primary.opacity(0.8) : .secondary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(12 + (item.level - 1) * 16))
            .padding(.trailing, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? Color.accentColor.opacity(0.1) : (isHovered ? Color.accentColor.opacity(0.06) : Color.clear))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
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
