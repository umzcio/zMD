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

// MARK: - Outlook .msg

/// Builds a minimal, valid OLE2 compound file in memory so the .msg path can be tested without
/// shipping real mail. All streams go in the mini stream (every test stream is < 4096 bytes).
nonisolated struct TestCompoundFileBuilder {
    struct Node { let name: String; let isStorage: Bool; let data: Data; let children: [Node] }

    static func build(root children: [Node]) -> Data {
        // Directory entries, with child/left/right links. Siblings are chained as a degenerate
        // red-black tree (each node's "right" is the next sibling), which readers must accept.
        var entries: [(name: String, type: UInt8, child: Int32, right: Int32, start: UInt32, size: UInt32)] = []
        var mini = Data()
        var miniChains: [[UInt32]] = []   // per stream: its mini-sector indexes (contiguous)

        func add(_ node: Node) -> Int32 {
            let id = Int32(entries.count)
            if node.isStorage {
                entries.append((node.name, 1, -1, -1, 0, 0))
                var prev: Int32 = -1
                var first: Int32 = -1
                for c in node.children {
                    let cid = add(c)
                    if first < 0 { first = cid } else { entries[Int(prev)].right = cid }
                    prev = cid
                }
                entries[Int(id)].child = first
            } else {
                let startSector = UInt32(mini.count / 64)
                var padded = node.data
                while padded.count % 64 != 0 { padded.append(0) }
                mini.append(padded)
                let count = padded.count / 64
                miniChains.append((0..<count).map { startSector + UInt32($0) })
                entries.append((node.name, 2, -1, -1, startSector, UInt32(node.data.count)))
            }
            return id
        }
        entries.append(("Root Entry", 5, -1, -1, 0, 0))
        var prev: Int32 = -1
        var first: Int32 = -1
        for c in children {
            let cid = add(c)
            if first < 0 { first = cid } else { entries[Int(prev)].right = cid }
            prev = cid
        }
        entries[0].child = first

        // Mini FAT: chain each stream's sectors, end with 0xFFFFFFFE.
        var miniFat = [UInt32](repeating: 0xFFFF_FFFF, count: max(1, mini.count / 64))
        for chain in miniChains {
            for (i, s) in chain.enumerated() { miniFat[Int(s)] = i + 1 < chain.count ? chain[i + 1] : 0xFFFF_FFFE }
        }

        // Regular sectors: [0] FAT, [1...] directory, then mini FAT, then mini stream.
        let sector = 512
        func sectors(for byteCount: Int) -> Int { max(1, (byteCount + sector - 1) / sector) }
        var directory = Data()
        for e in entries {
            var d = Data(count: 128)
            let name = Data((e.name + "\0").utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            d.replaceSubrange(0..<name.count, with: name)
            d.replaceSubrange(64..<66, with: le16(UInt16(name.count)))
            d[66] = e.type
            d[67] = 1 // black
            d.replaceSubrange(68..<72, with: le32(0xFFFF_FFFF))          // left: none
            d.replaceSubrange(72..<76, with: le32(UInt32(bitPattern: e.right)))
            d.replaceSubrange(76..<80, with: le32(UInt32(bitPattern: e.child)))
            d.replaceSubrange(116..<120, with: le32(e.start))
            d.replaceSubrange(120..<124, with: le32(e.size))
            directory.append(d)
        }
        let dirSectors = sectors(for: directory.count)
        let miniFatData = Data(miniFat.flatMap { le32($0) })
        let miniFatSectors = sectors(for: miniFatData.count)
        let miniStreamSectors = sectors(for: max(1, mini.count))
        // Root entry's stream is the mini stream.
        let rootStart = UInt32(1 + dirSectors + miniFatSectors)
        directory.replaceSubrange(116..<120, with: le32(rootStart))
        directory.replaceSubrange(120..<124, with: le32(UInt32(mini.count)))

        // FAT (one sector = 128 entries).
        var fat = [UInt32](repeating: 0xFFFF_FFFF, count: 128)
        fat[0] = 0xFFFF_FFFD   // FAT sector marker
        func chain(_ from: Int, _ count: Int) { for i in 0..<count { fat[from + i] = i + 1 < count ? UInt32(from + i + 1) : 0xFFFF_FFFE } }
        chain(1, dirSectors)
        chain(1 + dirSectors, miniFatSectors)
        chain(Int(rootStart), miniStreamSectors)

        var header = Data(count: 512)
        header.replaceSubrange(0..<8, with: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]))
        header.replaceSubrange(24..<26, with: le16(0x003E))   // minor version
        header.replaceSubrange(26..<28, with: le16(0x0003))   // major version 3
        header.replaceSubrange(28..<30, with: le16(0xFFFE))   // byte order
        header.replaceSubrange(30..<32, with: le16(9))        // 512-byte sectors
        header.replaceSubrange(32..<34, with: le16(6))        // 64-byte mini sectors
        header.replaceSubrange(44..<48, with: le32(1))        // FAT sector count
        header.replaceSubrange(48..<52, with: le32(1))        // first directory sector
        header.replaceSubrange(56..<60, with: le32(4096))     // mini stream cutoff
        header.replaceSubrange(60..<64, with: le32(UInt32(1 + dirSectors)))   // first mini FAT sector
        header.replaceSubrange(64..<68, with: le32(UInt32(miniFatSectors)))
        header.replaceSubrange(68..<72, with: le32(0xFFFF_FFFE))              // no DIFAT chain
        header.replaceSubrange(76..<80, with: le32(0))                        // DIFAT[0] = FAT sector 0
        for i in 1..<109 { header.replaceSubrange((76 + i * 4)..<(80 + i * 4), with: le32(0xFFFF_FFFF)) }

        var file = header
        file.append(Data(fat.flatMap { le32($0) }))
        func pad(_ d: Data, to count: Int) -> Data { var x = d; while x.count < count * sector { x.append(0) }; return x }
        file.append(pad(directory, to: dirSectors))
        file.append(pad(miniFatData, to: miniFatSectors))
        file.append(pad(mini, to: miniStreamSectors))
        return file
    }

    static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8)]) }
    static func le32(_ v: UInt32) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }

    // MARK: MAPI helpers

    static func unicode(_ id: UInt16, _ s: String) -> Node {
        Node(name: String(format: "__substg1.0_%04X001F", id), isStorage: false,
             data: Data(s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }), children: [])
    }
    static func binary(_ id: UInt16, _ d: Data) -> Node {
        Node(name: String(format: "__substg1.0_%04X0102", id), isStorage: false, data: d, children: [])
    }
    /// `__properties_version1.0` with the given fixed props; `topLevel` chooses the 32- vs 8-byte header.
    static func properties(topLevel: Bool, int32: [UInt16: Int32] = [:], bool: [UInt16: Bool] = [:], filetime: [UInt16: UInt64] = [:]) -> Node {
        var d = Data(count: topLevel ? 32 : 8)
        func entry(_ id: UInt16, _ type: UInt16, _ value: UInt64) {
            d.append(le32(UInt32(id) << 16 | UInt32(type))); d.append(le32(0))
            d.append(le32(UInt32(value & 0xFFFF_FFFF))); d.append(le32(UInt32(value >> 32)))
        }
        for (k, v) in int32 { entry(k, 0x0003, UInt64(UInt32(bitPattern: v))) }
        for (k, v) in bool { entry(k, 0x000B, v ? 1 : 0) }
        for (k, v) in filetime { entry(k, 0x0040, v) }
        return Node(name: "__properties_version1.0", isStorage: false, data: d, children: [])
    }
}

nonisolated final class OutlookMessageTests: XCTestCase {
    typealias B = TestCompoundFileBuilder

    /// 2026-10-01 12:00:00 UTC as a FILETIME (100ns ticks since 1601).
    private let filetime: UInt64 = (UInt64(1_790_856_000) + 11_644_473_600) * 10_000_000

    func testParsesHeadersRecipientsBodyAndAttachmentFromACompoundFile() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let file = B.build(root: [
            B.properties(topLevel: true, int32: [0x3FDE: 1252], filetime: [0x0039: filetime]),
            B.unicode(0x0037, "Budget — final"),
            B.unicode(0x0C1A, "Ann Example"),
            B.unicode(0x0C1E, "EX"),
            B.unicode(0x0C1F, "/O=EXCHANGE/OU=…/CN=ANN"),          // X.500, must be ignored
            B.unicode(0x5D0A, "ann@example.edu"),                  // the SMTP fallback real exports use
            B.unicode(0x1000, "Plain body line 1\r\nline 2"),
            B.binary(0x1013, Data("<html><body><p>Hi <b>Zach</b></p><img src=\"cid:logo\"></body></html>".utf8)),
            B.Node(name: "__recip_version1.0_#00000000", isStorage: true, data: Data(), children: [
                B.properties(topLevel: false, int32: [0x0C15: 1]),
                B.unicode(0x3001, "Zach"), B.unicode(0x39FE, "zach@example.edu"),
            ]),
            B.Node(name: "__recip_version1.0_#00000001", isStorage: true, data: Data(), children: [
                B.properties(topLevel: false, int32: [0x0C15: 2]),
                B.unicode(0x3001, "Cc Person"), B.unicode(0x39FE, "cc@example.edu"),
            ]),
            B.Node(name: "__attach_version1.0_#00000000", isStorage: true, data: Data(), children: [
                B.properties(topLevel: false, int32: [0x3705: 1], bool: [0x7FFE: true]),
                B.unicode(0x3707, "logo.png"), B.unicode(0x370E, "image/png"), B.unicode(0x3712, "logo"),
                B.binary(0x3701, png),
            ]),
            B.Node(name: "__attach_version1.0_#00000001", isStorage: true, data: Data(), children: [
                B.properties(topLevel: false, int32: [0x3705: 1]),
                B.unicode(0x3707, "Q4 budget.xlsx"), B.binary(0x3701, Data([1, 2, 3, 4, 5])),
            ]),
        ])

        let m = try XCTUnwrap(OutlookMessage.parse(file))
        XCTAssertEqual(m.subject, "Budget — final")
        XCTAssertEqual(m.from.first?.name, "Ann Example")
        XCTAssertEqual(m.from.first?.address, "ann@example.edu", "X.500 address skipped, SMTP fallback used")
        XCTAssertEqual(m.to.map(\.address), ["zach@example.edu"])
        XCTAssertEqual(m.cc.map(\.address), ["cc@example.edu"])
        XCTAssertEqual(try XCTUnwrap(m.date).timeIntervalSince1970, 1_790_856_000, accuracy: 1)
        XCTAssertEqual(m.textBody, "Plain body line 1\r\nline 2")
        XCTAssertTrue(m.htmlBody?.contains("<b>Zach</b>") == true, "PR_HTML decoded in the message code page")
        XCTAssertEqual(m.attachments.count, 2)
        XCTAssertEqual(m.fileAttachments.map(\.filename), ["Q4 budget.xlsx"], "cid-referenced hidden logo is inline, not listed")
        XCTAssertEqual(m.attachments.first { $0.contentId == "logo" }?.data, png)

        let md = m.markdownRepresentation()
        XCTAssertTrue(md.contains("src=\"data:image/png;base64,\(png.base64EncodedString())\""), "cid: resolved from the attachment")
        XCTAssertTrue(md.contains("- Q4 budget.xlsx ("))
    }

    func testNonCompoundDataIsRejectedNotCrashed() {
        XCTAssertNil(OutlookMessage.parse(Data("From: a@b\r\n\r\nnot a msg".utf8)))
        XCTAssertNil(OutlookMessage.parse(Data()))
        XCTAssertNil(OutlookMessage.parse(Data(repeating: 0xD0, count: 600)))
        XCTAssertNil(CompoundFile(data: Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 600)), "valid magic but garbage structure")
    }

    // MARK: Compressed RTF

    func testDictionaryIsExactly207BytesWithCRLFAtOffset168() {
        let d = CompressedRTF.initialDictionary
        XCTAssertEqual(d.count, 207)
        XCTAssertEqual(d[168], 0x0D); XCTAssertEqual(d[169], 0x0A)
        XCTAssertEqual(String(bytes: d[52..<60], encoding: .ascii), "\\froman ")
        XCTAssertEqual(String(bytes: d[133..<140], encoding: .ascii), "Courier")
        XCTAssertEqual(String(bytes: d[194..<207], encoding: .ascii), "\\b\\i\\u\\tab\\tx")
    }

    /// Hand-assembled LZFu stream: a back-reference into the dictionary, literals, a
    /// back-reference into freshly written output, then the end marker.
    func testLZFuDecompressesReferencesIntoTheDictionaryAndIntoOutput() throws {
        var payload: [UInt8] = []
        // Control 0b0000_0101: token 0 = ref, token 1 = literal, token 2 = ref, then literals.
        // Token 0: offset 0, length 6 → "{\rtf1"  ⇒ word = (0 << 4) | (6 - 2)
        // Token 1: literal "X"
        // Token 2: offset 207, length 3 → the "{\r" just written (output-region reference).
        payload += [0b0000_0101]
        payload += [0x00, 0x04]
        payload += [UInt8(ascii: "X")]
        payload += [UInt8(207 >> 4), UInt8((207 & 0xF) << 4 | 1)]
        payload += Array("ab}".utf8)
        // Second control byte: bit0 = ref → end marker (offset == write position).
        let writePos = 207 + 6 + 1 + 3 + 3
        payload += [0b0000_0001, UInt8(writePos >> 4), UInt8((writePos & 0xF) << 4)]
        var data = Data()
        data.append(B.le32(UInt32(payload.count + 12)))            // compressed size (excludes this field)
        data.append(B.le32(13))                                     // raw size
        data.append(Data("LZFu".utf8))
        data.append(B.le32(0))                                      // crc (not checked)
        data.append(Data(payload))
        let out = try XCTUnwrap(CompressedRTF.decompress(data))
        XCTAssertEqual(String(data: out, encoding: .ascii), "{\\rtf1X{\\rab}")
    }

    func testMELAPassesRawRTFThroughAndJunkIsRejected() throws {
        let rtf = "{\\rtf1 hi}"
        var data = Data(); data.append(B.le32(UInt32(rtf.utf8.count + 12))); data.append(B.le32(UInt32(rtf.utf8.count)))
        data.append(Data("MELA".utf8)); data.append(B.le32(0)); data.append(Data(rtf.utf8))
        XCTAssertEqual(String(data: try XCTUnwrap(CompressedRTF.decompress(data)), encoding: .ascii), rtf)
        XCTAssertNil(CompressedRTF.decompress(Data("not compressed rtf at all".utf8)))
    }

    // MARK: RTF de-encapsulation

    func testFromHtmlRTFDecapsulatesToTheOriginalHTML() {
        let rtf = #"{\rtf1\ansi\ansicpg1252\fromhtml1 \deff0{\fonttbl{\f0\fswiss Arial;}}{\colortbl\red0\green0\blue0;}"# +
            #"{\*\htmltag243 <html>}{\*\htmltag2 <body>}{\*\htmltag64 <p class="x">}\htmlrtf \pard\plain\f0\fs20 \htmlrtf0 "# +
            #"Caf\'e9 \u8212? costs {\*\htmltag84 <b>}5\htmlrtf \b \htmlrtf0 0\htmlrtf \b0 \htmlrtf0 {\*\htmltag92 </b>}"# +
            #"{\*\htmltag72 </p>}\htmlrtf \par \htmlrtf0 {\*\mhtmltag0 ignored}{\*\htmltag3 </body>}{\*\htmltag251 </html>}}"#
        let doc = RTFDocument(rtf: Data(rtf.utf8), defaultEncoding: .windowsCP1252)
        XCTAssertTrue(doc.isEncapsulatedHTML)
        let html = doc.decapsulatedHTML()
        XCTAssertEqual(html, "<html><body><p class=\"x\">Café — costs <b>50</b></p></body></html>")
    }

    func testPlainRTFBecomesTextWithParagraphsAndSkipsTables() {
        let rtf = #"{\rtf1\ansi\deff0{\fonttbl{\f0 Arial;}}{\colortbl;\red0\green0\blue0;}{\*\generator Riched20;}\pard First\'e9 line\par Second\tab tabbed\line third}"#
        let doc = RTFDocument(rtf: Data(rtf.utf8), defaultEncoding: .windowsCP1252)
        XCTAssertFalse(doc.isEncapsulatedHTML)
        XCTAssertEqual(doc.plainText(), "Firsté line\nSecond\ttabbed\nthird")
    }

    // MARK: Document integration

    @MainActor
    func testOpenedMsgIsReadOnlyEmailDocument() throws {
        let manager = DocumentManager.shared
        let saved = (manager.openDocuments, manager.selectedDocumentId)
        defer { manager.openDocuments = saved.0; manager.selectedDocumentId = saved.1 }
        manager.openDocuments = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zmd-msg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("note.msg")
        let file = B.build(root: [B.properties(topLevel: true), B.unicode(0x0037, "Msg subject"), B.unicode(0x1000, "body")])
        try file.write(to: url)
        manager.loadDocument(from: url)
        let doc = try XCTUnwrap(manager.openDocuments.first { $0.url == url })
        XCTAssertEqual(doc.kind, .email)
        XCTAssertTrue(doc.content.contains("# Msg subject"))
        manager.updateContent(for: doc.id, newContent: "x")
        XCTAssertEqual(try Data(contentsOf: url), file, "the .msg must never be written")
    }
}

// MARK: - Code-review regressions (v2.10.0)

nonisolated final class EmailReviewRegressionTests: XCTestCase {
    typealias B = TestCompoundFileBuilder

    private func eml(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    func testDuplicateContentIDsDoNotTrap() {
        let png = Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()
        let m = EmailMessage.parse(eml("""
        From: a@example.com
        Subject: dup
        Content-Type: multipart/related; boundary="r"

        --r
        Content-Type: text/html

        <p>x</p><img src="cid:logo">
        --r
        Content-Type: image/png
        Content-ID: <logo>
        Content-Transfer-Encoding: base64

        \(png)
        --r
        Content-Type: image/png
        Content-ID: <logo>
        Content-Transfer-Encoding: base64

        \(png)
        --r--
        """))
        XCTAssertEqual(m.attachments.count, 2)
        let (html, _) = m.renderedBodyHTML()
        XCTAssertTrue(html.contains("data:image/png;base64,"), "first duplicate wins and still resolves")
    }

    func testCSSImportIsStrippedLikeRemoteURL() {
        let r = EmailHTMLSanitizer.sanitize("""
        <html><head><style>@import "https://tracker.example/p.css"; @import url(https://t.example/x.css); p { color: red }</style></head>
        <body><p style="background:url(https://t.example/b.png)">hi</p></body></html>
        """, inlineParts: [:])
        XCTAssertFalse(r.html.contains("@import"))
        XCTAssertFalse(r.html.lowercased().contains("https://"))
        XCTAssertTrue(r.html.contains("color: red"), "the rest of the stylesheet survives")
    }

    func testRawUTF8HeadersDecodeAndLatin1StillFallsBack() {
        let utf8 = EmailMessage.parse(eml("Subject: Café plans — ok\nFrom: a@example.com\n\nbody"))
        XCTAssertEqual(utf8.subject, "Café plans — ok")
        var latin = Data("Subject: Caf".utf8); latin.append(0xE9); latin.append(Data(" plans\r\n\r\nbody".utf8))
        XCTAssertEqual(EmailMessage.parse(latin).subject, "Café plans")
        XCTAssertEqual(EmailMessage.parse(eml("Subject: =?utf-8?Q?Caf=C3=A9?=\n\nb")).subject, "Café", "encoded words unaffected")
    }

    func testBoundaryThatPrefixesANestedBoundaryDoesNotSplitTheInnerPart() {
        let m = EmailMessage.parse(eml("""
        Subject: nested
        Content-Type: multipart/mixed; boundary="part"

        --part
        Content-Type: multipart/alternative; boundary="part1"

        --part1
        Content-Type: text/plain

        plain
        --part1
        Content-Type: text/html

        <p>HTML BODY</p>
        --part1--
        --part
        Content-Type: application/pdf; name="a.pdf"
        Content-Disposition: attachment; filename="a.pdf"

        %PDF
        --part--
        """))
        XCTAssertEqual(m.htmlBody?.contains("HTML BODY"), true)
        XCTAssertEqual(m.textBody, "plain")
        XCTAssertEqual(m.fileAttachments.map(\.filename), ["a.pdf"])
    }

    func testLaterHTMLOutsideAnAlternativeIsAppendedNotSubstituted() {
        let m = EmailMessage.parse(eml("""
        Subject: mixed
        Content-Type: multipart/mixed; boundary="m"

        --m
        Content-Type: multipart/alternative; boundary="a"

        --a
        Content-Type: text/plain

        plain
        --a
        Content-Type: text/html

        <p>MAIN</p>
        --a--
        --m
        Content-Type: text/html

        <p>TRAILING FRAGMENT</p>
        --m--
        """))
        let html = m.htmlBody ?? ""
        XCTAssertTrue(html.contains("MAIN"), "the alternative's HTML must not be replaced by a trailing leaf")
        XCTAssertTrue(html.contains("TRAILING FRAGMENT"))
        XCTAssertLessThan(html.range(of: "MAIN")!.lowerBound, html.range(of: "TRAILING")!.lowerBound)
    }

    func testAlternativeStillPrefersTheLastHTMLAndKeepsPlainFallback() {
        let m = EmailMessage.parse(eml("""
        Subject: alt
        Content-Type: multipart/alternative; boundary="a"

        --a
        Content-Type: text/plain

        plain
        --a
        Content-Type: text/html

        <p>FIRST</p>
        --a
        Content-Type: text/html

        <p>SECOND</p>
        --a--
        """))
        XCTAssertEqual(m.htmlBody?.contains("SECOND"), true)
        XCTAssertEqual(m.htmlBody?.contains("FIRST"), false)
        XCTAssertEqual(m.textBody, "plain")
    }

    func testCodepageOutOfRangeIsRejectedNotTrapped() {
        XCTAssertNil(Charsets.encoding(forCodepage: -1))
        XCTAssertNil(Charsets.encoding(forCodepage: Int32.min))
        XCTAssertNil(Charsets.encoding(forCodepage: 99_999_999_999))
        XCTAssertEqual(Charsets.encoding(forCodepage: 1252), .windowsCP1252)
        let doc = RTFDocument(rtf: Data(#"{\rtf1\ansi\ansicpg99999999999 hi}"#.utf8), defaultEncoding: .windowsCP1252)
        XCTAssertEqual(doc.plainText(), "hi")
    }

    func testLoopingFATAndMiniFATAreBoundedByFileSize() {
        var file = B.build(root: [B.properties(topLevel: true), B.unicode(0x0037, "s"), B.unicode(0x1000, "b")])
        // Sector 0 is the FAT: entry for the directory sector (1) points back to itself.
        file.replaceSubrange((512 + 4)..<(512 + 8), with: B.le32(1))
        // Mini FAT lives at sector 2: make the first mini stream loop on itself as well.
        file.replaceSubrange(1024..<1028, with: B.le32(0))
        let start = Date()
        let cf = CompoundFile(data: file)
        let root = cf.map { MAPIPropertySet(file: $0, storage: $0.root, isTopLevel: true) }
        _ = root?.string(0x0037, ansi: .windowsCP1252)
        _ = OutlookMessage.parse(file)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "a 2 KB file must not expand into gigabytes before the guard trips")
    }

    func testTruncationNoticeNeverAppliesToCompoundFiles() {
        XCTAssertGreaterThan(QuickLookHTML.maxCompoundFileBytes, QuickLookHTML.maxInputBytes,
                             "a .msg must be read whole, under a cap larger than the prefix cap used for text")
    }
}
