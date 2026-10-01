import XCTest
@testable import zMD

/// `.eml` support: MIME parsing, header decoding, body selection, and the privacy-preserving
/// markdown rendering. Fixtures are synthesized here (no real mail in the repo).
nonisolated final class EmailMessageTests: XCTestCase {
    private func eml(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    // MARK: Headers

    func testFoldedAndEncodedHeadersDecode() {
        let m = EmailMessage.parse(eml("""
        From: =?UTF-8?B?Sm9zw6kgR2FyY8OtYQ==?= <jose@example.com>
        To: "Rossmiller, Zach" <zach@example.edu>,
          Ann <ann@example.org>
        Subject: =?ISO-8859-1?Q?Caf=E9_plans?= =?ISO-8859-1?Q?_for_Friday?=
        Date: Tue, 1 Oct 2026 09:30:00 -0600 (MDT)
        Content-Type: text/plain; charset=utf-8

        Body.
        """))
        XCTAssertEqual(m.subject, "Café plans for Friday", "Q-encoding, underscores as spaces, whitespace between encoded words dropped")
        XCTAssertEqual(m.from.first?.name, "José García")
        XCTAssertEqual(m.from.first?.address, "jose@example.com")
        XCTAssertEqual(m.to.map(\.address), ["zach@example.edu", "ann@example.org"], "comma inside quotes must not split")
        XCTAssertEqual(m.to.first?.name, "Rossmiller, Zach")
        XCTAssertNotNil(m.date)
        let utc = Calendar(identifier: .gregorian)
        var comps = utc.dateComponents(in: TimeZone(identifier: "UTC")!, from: m.date!)
        comps.nanosecond = 0
        XCTAssertEqual(comps.hour, 15, "09:30 -0600 is 15:30 UTC")
        XCTAssertEqual(m.textBody?.trimmingCharacters(in: .whitespacesAndNewlines), "Body.")
    }

    func testMissingContentTypeIsPlainTextAndNoBlankLineIsAllHeaders() {
        let m = EmailMessage.parse(eml("Subject: hi\n\nhello"))
        XCTAssertEqual(m.textBody?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        let headersOnly = EmailMessage.parse(eml("Subject: only"))
        XCTAssertEqual(headersOnly.subject, "only")
        XCTAssertEqual(headersOnly.textBody ?? "", "")
    }

    // MARK: MIME structure

    private let multipart = """
    From: a@example.com
    Subject: Report
    Content-Type: multipart/mixed; boundary="outer"

    --outer
    Content-Type: multipart/alternative; boundary=inner

    --inner
    Content-Type: text/plain; charset=iso-8859-1
    Content-Transfer-Encoding: quoted-printable

    Plain caf=E9 line one=
     continues. # not a heading
    --inner
    Content-Type: text/html; charset=utf-8

    <html><head><style>p{color:red}</style></head><body><p>Hi <b>there</b></p><img src="cid:logo@x"><img src="https://t.example/pixel.gif"></body></html>
    --inner--
    --outer
    Content-Type: image/png
    Content-ID: <logo@x>
    Content-Disposition: inline; filename="logo.png"
    Content-Transfer-Encoding: base64

    iVBORw0KGgo=
    --outer
    Content-Type: application/pdf; name="Q3.pdf"
    Content-Disposition: attachment; filename*=utf-8''Q3%20report.pdf
    Content-Transfer-Encoding: base64

    JVBERi0xLjQ=
    --outer--
    """

    func testMultipartSelectsHtmlOverPlainAndCollectsAttachments() throws {
        let m = EmailMessage.parse(eml(multipart))
        XCTAssertEqual(m.textBody, "Plain café line one continues. # not a heading", "QP soft break joins lines; =E9 decodes via the part's charset")
        XCTAssertTrue(m.htmlBody?.contains("<b>there</b>") == true)
        XCTAssertEqual(m.attachments.count, 2)
        let pdf = try XCTUnwrap(m.attachments.first { $0.mimeType == "application/pdf" })
        XCTAssertEqual(pdf.filename, "Q3 report.pdf", "RFC 2231 filename* beats the legacy name=")
        XCTAssertEqual(pdf.data, Data(base64Encoded: "JVBERi0xLjQ="))
        XCTAssertFalse(pdf.isInline)
        // The logo is referenced by cid: so it's an inline resource, not a listed file.
        XCTAssertEqual(m.fileAttachments.map(\.filename), ["Q3 report.pdf"])
    }

    func testRenderingBlocksRemoteImagesInlinesCidAndStripsScripts() {
        let m = EmailMessage.parse(eml(multipart))
        let md = m.markdownRepresentation()
        XCTAssertTrue(md.hasPrefix("---\nSubject: Report\n"), "frontmatter header block first")
        XCTAssertTrue(md.contains("# Report"))
        XCTAssertTrue(md.contains("- Q3 report.pdf ("), "attachment list")
        XCTAssertTrue(md.contains("*1 remote image not loaded.*"))
        XCTAssertFalse(md.contains("https://t.example/pixel.gif"), "tracking pixel URL must not survive")
        XCTAssertTrue(md.contains("src=\"data:image/png;base64,iVBORw0KGgo=\""), "cid resolved to a data URI")
        XCTAssertTrue(md.contains("<style>p{color:red}</style>"), "head styles carried into the block")
        XCTAssertFalse(md.contains("<html"), "only body contents are embedded")
        // The generated markdown must parse into the intended elements through the real pipeline.
        let kinds = MarkdownParser.shared.parse(md).map { element -> String in
            switch element {
            case .frontmatter: return "fm"
            case .heading1: return "h1"
            case .paragraph: return "p"
            case .list: return "list"
            case .horizontalRule: return "hr"
            case .htmlBlock: return "html"
            default: return "other"
            }
        }
        XCTAssertEqual(kinds, ["fm", "h1", "p", "list", "p", "hr", "html"], "\(kinds)")

        // Body is the LAST thing in the document.
        let bodyStart = md.range(of: "<div class=\"email-body\">")!.lowerBound
        XCTAssertNil(md[bodyStart...].range(of: "\n# "), "nothing markdown may follow the HTML block")
    }

    func testPlainTextBodyIsLiteralAndAutolinked() {
        let m = EmailMessage.parse(eml("""
        Subject: s
        Content-Type: text/plain; charset=utf-8

        # not a heading
        *not emphasis* <b>not bold</b>
        see https://example.com/x.
        """))
        let md = m.markdownRepresentation()
        XCTAssertTrue(md.contains("# not a heading"), "literal inside the pre-wrap div")
        XCTAssertTrue(md.contains("&lt;b&gt;not bold&lt;/b&gt;"), "HTML in plain text is escaped")
        XCTAssertTrue(md.contains("<a href=\"https://example.com/x\">https://example.com/x</a>"), "trailing period excluded from the link")
        let parsed = MarkdownParser.shared.parse(md)
        XCTAssertFalse(parsed.contains { if case .heading1(let t) = $0 { return t.contains("not a heading") } else { return false } },
                       "the literal '#' line must not become a heading element")
    }

    func testSanitizerRemovesHandlersJavascriptAndCssRemoteUrls() {
        let r = EmailHTMLSanitizer.sanitize(
            #"<div onclick="x()" style="background:url(https://t.example/a.png)"><a href="javascript:alert(1)">x</a><script>bad()</script><iframe src="https://e"></iframe><p background="https://t.example/b.png">ok</p></div>"#,
            inlineParts: [:])
        XCTAssertFalse(r.html.contains("onclick"))
        XCTAssertFalse(r.html.contains("javascript:"))
        XCTAssertFalse(r.html.contains("<script"))
        XCTAssertFalse(r.html.contains("<iframe"))
        XCTAssertFalse(r.html.contains("t.example"), "every remote reference gone: \(r.html)")
        XCTAssertTrue(r.html.contains("<p>ok</p>") || r.html.contains("<p >ok</p>"))
        XCTAssertEqual(r.blockedRemoteImages, 0, "css/background removals are not counted as blocked <img>s")
    }

    func testForwardedMessageAndUnterminatedMultipart() {
        let m = EmailMessage.parse(eml("""
        Subject: Fwd
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: text/plain

        see attached
        --b
        Content-Type: message/rfc822

        Subject: inner
        Content-Type: text/plain

        inner body
        """))
        XCTAssertEqual(m.textBody?.trimmingCharacters(in: .whitespacesAndNewlines), "see attached")
        XCTAssertEqual(m.attachments.count, 1, "truncated final part is kept, not dropped")
        XCTAssertEqual(m.attachments.first?.mimeType, "message/rfc822")
        XCTAssertEqual(m.attachments.first?.filename, "Forwarded message.eml")
    }

    func testMalformedInputNeverCrashes() {
        for junk in ["", "\r\n\r\n", "Content-Type: multipart/mixed; boundary=\n\n--\n", "=?bogus?B?!!!?=", String(repeating: "--x", count: 500)] {
            _ = EmailMessage.parse(Data(junk.utf8)).markdownRepresentation()
        }
    }

    // MARK: Document integration — an opened .eml must be impossible to overwrite

    @MainActor
    func testOpenedEmailIsReadOnlyAndNeverWrittenBack() throws {
        let manager = DocumentManager.shared
        let saved = (manager.openDocuments, manager.selectedDocumentId, manager.autoSaveEnabled)
        defer {
            manager.openDocuments = saved.0
            manager.selectedDocumentId = saved.1
            manager.autoSaveEnabled = saved.2
        }
        manager.autoSaveEnabled = true
        manager.openDocuments = []

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-eml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.eml")
        let original = "From: a@example.com\r\nSubject: Keep me\r\nContent-Type: text/plain\r\n\r\nhello\r\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        manager.loadDocument(from: url)
        let doc = try XCTUnwrap(manager.openDocuments.first { $0.url == url })
        XCTAssertEqual(doc.kind, .email)
        XCTAssertTrue(doc.isReadOnly)
        XCTAssertEqual(doc.detectedEncoding, "Email")
        XCTAssertTrue(doc.content.contains("# Keep me"), "content is the rendered markdown")

        // Edits are refused outright (no dirty flag, no auto-save timer).
        manager.updateContent(for: doc.id, newContent: "# overwritten")
        XCTAssertEqual(manager.openDocuments.first { $0.id == doc.id }?.content, doc.content)
        XCTAssertFalse(manager.openDocuments.first { $0.id == doc.id }?.isDirty ?? true)

        // Explicit save is a no-op that reports failure.
        manager.saveDocument(id: doc.id)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original, "the .eml on disk must be byte-identical")

        // Checkbox toggling goes through updateContent and is therefore refused too.
        XCTAssertFalse(manager.toggleTaskItem(documentId: doc.id, ordinal: 0, renderedChecked: false, renderedText: "x"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)

        // Reload re-renders rather than re-reading as text.
        manager.reloadDocument(doc)
        XCTAssertTrue(manager.openDocuments.first { $0.id == doc.id }?.content.contains("# Keep me") == true)
        XCTAssertEqual(manager.openDocuments.first { $0.id == doc.id }?.kind, .email, "kind survives reload")
    }
}
