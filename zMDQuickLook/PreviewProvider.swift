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
        let ext = url.pathExtension.lowercased()

        // .eml: parse as MIME and render to markdown; .msg: compound file; everything else IS
        // markdown.
        let markdown: String
        var truncated = false
        if ext == "msg" {
            // A compound file cannot be previewed from a prefix (its directory and FAT are
            // scattered through the file), so it is read whole under its own, larger cap and is
            // never "truncated": either it fits and the preview is complete, or it does not.
            let (whole, overCap) = try QuickLookHTML.readPrefix(of: url, maxBytes: QuickLookHTML.maxCompoundFileBytes)
            if overCap {
                markdown = "# Message too large to preview\n\nOpen the file in zMD to view it.\n"
            } else {
                markdown = OutlookMessage.parse(whole)?.markdownRepresentation() ?? "# Unreadable message\n"
            }
        } else {
            let (data, wasTruncated) = try QuickLookHTML.readPrefix(of: url)
            truncated = wasTruncated
            markdown = ext == "eml"
                ? EmailMessage.parse(data).markdownRepresentation()
                : QuickLookHTML.decode(data, truncated: truncated)
        }

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
