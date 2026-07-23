import Foundation
import UniformTypeIdentifiers

/// Handles file URLs dropped onto the main window.
enum DropHandler {
    static let maxOpenOnDrop = 20

    static func handle(providers: [NSItemProvider], documentManager: DocumentManager) {
        let group = DispatchGroup()
        var collectedURLs: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                lock.lock()
                collectedURLs.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            var expanded: [URL] = []
            var nonMarkdownSkipped = 0
            for url in collectedURLs {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    if let children = try? FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: nil
                    ) {
                        expanded.append(contentsOf: children.filter(Self.isMarkdown))
                    }
                } else if Self.isMarkdown(url) {
                    expanded.append(url)
                } else {
                    nonMarkdownSkipped += 1
                }
            }

            let toOpen = Array(expanded.prefix(maxOpenOnDrop))
            let overCapSkipped = max(0, expanded.count - toOpen.count)
            for url in toOpen {
                documentManager.loadDocument(from: url)
            }

            if toOpen.isEmpty && nonMarkdownSkipped > 0 {
                ToastManager.shared.show("No markdown files found in drop", style: .warning)
            } else if overCapSkipped > 0 {
                ToastManager.shared.show(
                    "Opened \(toOpen.count) files; skipped \(overCapSkipped) (cap \(maxOpenOnDrop))",
                    style: .warning
                )
            } else if nonMarkdownSkipped > 0 {
                ToastManager.shared.show(
                    "Opened \(toOpen.count); skipped \(nonMarkdownSkipped) non-markdown",
                    style: .warning
                )
            }
        }
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }
}
