import SwiftUI

struct OutlineView: View {
    let content: String
    @Binding var selectedHeadingId: String?

    /// Cached outline so we don't re-parse the entire document on every SwiftUI body evaluation.
    /// Rebuilt only when `content` actually changes, debounced by SwiftUI's natural update cadence.
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
                    if headings.isEmpty {
                        Text("No headings")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(headings) { item in
                            OutlineItemView(item: item, selectedId: $selectedHeadingId)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 250)
        .background(.ultraThinMaterial)
        .onAppear { rebuildOutline() }
        .onChange(of: content) { _ in rebuildOutline() }
    }

    private func rebuildOutline() {
        // Delegate to MarkdownParser so the outline uses the same stable slug IDs as the
        // preview renderer's heading ranges — click targets stay accurate after edits above,
        // and `#` lines inside fenced code blocks do not appear as phantom entries.
        headings = MarkdownParser.shared.extractHeadings(content).map {
            OutlineItem(id: $0.id, level: $0.level, text: $0.text)
        }
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
