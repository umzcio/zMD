import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var settings: SettingsManager

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

                // Right: zoom, view mode, encoding
                HStack(spacing: 8) {
                    Menu {
                        ForEach([50, 75, 90, 100, 110, 125, 150, 175, 200], id: \.self) { percent in
                            Button {
                                settings.zoomLevel = CGFloat(percent) / 100.0
                            } label: {
                                HStack {
                                    Text("\(percent)%")
                                    if Int(settings.zoomLevel * 100) == percent {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Reset to 100%") {
                            settings.resetZoom()
                        }
                        .disabled(settings.zoomLevel == 1.0)
                    } label: {
                        Text("\(Int(settings.zoomLevel * 100))%")
                            .font(.system(size: 11))
                            .foregroundColor(settings.zoomLevel != 1.0 ? .secondary : Color(NSColor.tertiaryLabelColor))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

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
