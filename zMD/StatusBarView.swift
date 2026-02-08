import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var documentManager: DocumentManager

    var body: some View {
        if let selectedId = documentManager.selectedDocumentId,
           let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) {
            HStack(spacing: 0) {
                // Left: word count, char count, reading time
                let stats = documentStats(for: document.content)
                Text("\(stats.words) words  \u{00B7}  \(stats.characters) chars  \u{00B7}  \(stats.readingTime) min read")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Spacer()

                // Right: view mode, encoding
                HStack(spacing: 8) {
                    Text(documentManager.viewMode.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("UTF-8")
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor.tertiaryLabelColor))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 24)
            .background(.ultraThinMaterial)
        }
    }

    private func documentStats(for content: String) -> (words: Int, characters: Int, readingTime: Int) {
        let characters = content.count
        let words = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        let readingTime = max(1, (words + 199) / 200) // ~200 wpm, minimum 1 min
        return (words, characters, readingTime)
    }
}
