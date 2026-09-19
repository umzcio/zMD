import Foundation
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look preview for Markdown files (Space in Finder), rendered through the same
/// `MarkdownParser.toHTML` pipeline the app uses for HTML/PDF export.
///
/// Data-based preview (`QLIsDataBasedPreview`): we hand Quick Look an HTML document and it owns
/// the view. `nonisolated` because the target defaults to MainActor isolation and Quick Look
/// calls `providePreview` off the main thread — parsing a 2 MB file has no business on it anyway.
nonisolated final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let (data, truncated) = try QuickLookHTML.readPrefix(of: url)

        let markdown = QuickLookHTML.decode(data, truncated: truncated)

        var html = QuickLookHTML.makeOfflineSafe(
            MarkdownParser.shared.toHTML(markdown, includeStyles: true)
        )
        if truncated {
            html = QuickLookHTML.appendingTruncationNotice(to: html)
        }
        let htmlData = Data(html.utf8)

        // contentSize is only a hint for the initial panel size; the HTML reflows to fit.
        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 800, height: 1000)
        ) { reply in
            reply.stringEncoding = .utf8
            return htmlData
        }
        reply.title = url.lastPathComponent
        return reply
    }
}
