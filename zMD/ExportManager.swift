import SwiftUI
import AppKit
import UniformTypeIdentifiers

class ExportManager {
    static let shared = ExportManager()
    private let parser = MarkdownParser.shared
    private let alertManager = AlertManager.shared

    private init() {}

    // MARK: - PDF Export
    func exportToPDF(content: String, fileName: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = fileName.replacingOccurrences(of: ".md", with: ".pdf")
        savePanel.title = "Export as PDF"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            DispatchQueue.main.async {
                do {
                    // Create PDF using NSAttributedString (sandbox-friendly)
                    let html = self.parser.toHTML(content, includeStyles: true)

                    guard let htmlData = html.data(using: .utf8) else {
                        self.alertManager.showExportError("PDF", reason: "Failed to encode HTML content")
                        return
                    }

                    // Convert HTML to attributed string
                    let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ]

                    guard let attributedString = NSAttributedString(html: htmlData, options: options, documentAttributes: nil) else {
                        self.alertManager.showExportError("PDF", reason: "Failed to create styled content")
                        return
                    }

                    // Create PDF context
                    let pageSize = CGSize(width: 8.5 * 72, height: 11 * 72) // Letter size
                    let pageRect = CGRect(origin: .zero, size: pageSize)
                    let printInfo = NSPrintInfo()
                    printInfo.paperSize = pageSize
                    printInfo.leftMargin = 54 // 0.75 inches
                    printInfo.rightMargin = 54
                    printInfo.topMargin = 54
                    printInfo.bottomMargin = 54

                    // Calculate text bounds
                    let textRect = NSRect(
                        x: printInfo.leftMargin,
                        y: printInfo.topMargin,
                        width: pageSize.width - printInfo.leftMargin - printInfo.rightMargin,
                        height: pageSize.height - printInfo.topMargin - printInfo.bottomMargin
                    )

                    let pdfData = NSMutableData()
                    guard let consumer = CGDataConsumer(data: pdfData as CFMutableData) else {
                        self.alertManager.showExportError("PDF", reason: "Failed to create PDF data consumer")
                        return
                    }

                    var mediaBox = pageRect
                    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                        self.alertManager.showExportError("PDF", reason: "Failed to create PDF context")
                        return
                    }

                    let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
                    NSGraphicsContext.current = nsContext

                    // Calculate total height needed
                    let layoutManager = NSLayoutManager()
                    let textContainer = NSTextContainer(size: CGSize(width: textRect.width, height: .greatestFiniteMagnitude))
                    let textStorage = NSTextStorage(attributedString: attributedString)

                    layoutManager.addTextContainer(textContainer)
                    textStorage.addLayoutManager(layoutManager)

                    layoutManager.glyphRange(for: textContainer)
                    let usedRect = layoutManager.usedRect(for: textContainer)

                    // Draw pages
                    var currentY: CGFloat = 0
                    let pageHeight = textRect.height

                    while currentY < usedRect.height {
                        context.beginPage(mediaBox: &mediaBox)

                        context.saveGState()

                        // Set clipping region to text area
                        context.clip(to: textRect)

                        // Create draw rect with offset for current page
                        let drawRect = NSRect(
                            x: textRect.minX,
                            y: textRect.minY - currentY,
                            width: textRect.width,
                            height: usedRect.height
                        )

                        attributedString.draw(in: drawRect)

                        context.restoreGState()
                        context.endPage()

                        currentY += pageHeight
                    }

                    context.closePDF()

                    try pdfData.write(to: url)
                } catch {
                    self.alertManager.showExportError("PDF", error: error)
                }
            }
        }
    }

    // MARK: - HTML Export
    func exportToHTML(content: String, fileName: String, includeStyles: Bool = true) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.html]
        savePanel.nameFieldStringValue = fileName.replacingOccurrences(of: ".md", with: ".html")
        savePanel.title = includeStyles ? "Export as HTML" : "Export as HTML (without styles)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            let html = self.parser.toHTML(content, includeStyles: includeStyles)

            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.alertManager.showExportError("HTML", error: error)
            }
        }
    }

    // MARK: - Word/RTF Export
    func exportToWord(content: String, fileName: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.rtf]
        savePanel.nameFieldStringValue = fileName.replacingOccurrences(of: ".md", with: ".rtf")
        savePanel.title = "Export as RTF (Word Compatible)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            DispatchQueue.main.async {
                // Convert markdown to HTML first, then to attributed string, then to RTF
                let html = self.parser.toHTML(content, includeStyles: true)

                guard let data = html.data(using: .utf8) else {
                    self.alertManager.showExportError("RTF", reason: "Failed to encode HTML content")
                    return
                }

                guard let attributedString = NSAttributedString(
                    html: data,
                    options: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue
                    ],
                    documentAttributes: nil
                ) else {
                    self.alertManager.showExportError("RTF", reason: "Failed to create styled content")
                    return
                }

                do {
                    let rtfData = try attributedString.data(
                        from: NSRange(location: 0, length: attributedString.length),
                        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                    )
                    try rtfData.write(to: url)
                } catch {
                    self.alertManager.showExportError("RTF", error: error)
                }
            }
        }
    }

    // MARK: - DOCX Export (Custom Generator)
    func exportToDOCX(content: String, fileName: String) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "docx")].compactMap { $0 }
        savePanel.nameFieldStringValue = fileName.replacingOccurrences(of: ".md", with: ".docx")
        savePanel.title = "Export as Word Document (DOCX)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            DispatchQueue.main.async {
                do {
                    try self.createCustomDOCX(content: content, outputURL: url)
                } catch {
                    self.alertManager.showExportError("DOCX", error: error)
                }
            }
        }
    }

    // Property to track hyperlinks during document generation
    private var hyperlinkRelationships: [(id: String, url: String)] = []
    private var nextHyperlinkId = 3 // Start at 3 since rId1 and rId2 are taken

    private func createCustomDOCX(content: String, outputURL: URL) throws {
        // Reset hyperlink tracking for new document
        hyperlinkRelationships = []
        nextHyperlinkId = 3

        // Create temporary directory for DOCX structure
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Create DOCX directory structure
        let wordDir = tempDir.appendingPathComponent("word")
        let relsDir = tempDir.appendingPathComponent("_rels")
        let wordRelsDir = wordDir.appendingPathComponent("_rels")

        try FileManager.default.createDirectory(at: wordDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)

        // Generate document.xml content
        let documentXML = generateDocumentXML(markdown: content)
        try documentXML.write(to: wordDir.appendingPathComponent("document.xml"), atomically: true, encoding: .utf8)

        // Create [Content_Types].xml
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="xml" ContentType="application/xml"/>
            <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
            <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>
            <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        </Types>
        """
        try contentTypes.write(to: tempDir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)

        // Create _rels/.rels
        let mainRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        try mainRels.write(to: relsDir.appendingPathComponent(".rels"), atomically: true, encoding: .utf8)

        // Create word/_rels/document.xml.rels with hyperlink relationships
        var documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """

        // Add hyperlink relationships
        for hyperlink in hyperlinkRelationships {
            documentRels += """

                <Relationship Id="\(hyperlink.id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="\(xmlEscape(hyperlink.url))" TargetMode="External"/>
            """
        }

        documentRels += """

        </Relationships>
        """
        try documentRels.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)

        // Create word/numbering.xml for list styles
        let numberingXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:abstractNum w:abstractNumId="0">
                <w:multiLevelType w:val="hybridMultilevel"/>
                <w:lvl w:ilvl="0">
                    <w:start w:val="1"/>
                    <w:numFmt w:val="bullet"/>
                    <w:lvlText w:val="\u{F0B7}"/>
                    <w:lvlJc w:val="left"/>
                    <w:pPr>
                        <w:ind w:left="720" w:hanging="360"/>
                    </w:pPr>
                    <w:rPr>
                        <w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/>
                    </w:rPr>
                </w:lvl>
            </w:abstractNum>
            <w:abstractNum w:abstractNumId="1">
                <w:multiLevelType w:val="hybridMultilevel"/>
                <w:lvl w:ilvl="0">
                    <w:start w:val="1"/>
                    <w:numFmt w:val="decimal"/>
                    <w:lvlText w:val="%1."/>
                    <w:lvlJc w:val="left"/>
                    <w:pPr>
                        <w:ind w:left="720" w:hanging="360"/>
                    </w:pPr>
                </w:lvl>
            </w:abstractNum>
            <w:num w:numId="1">
                <w:abstractNumId w:val="0"/>
            </w:num>
            <w:num w:numId="2">
                <w:abstractNumId w:val="1"/>
            </w:num>
        </w:numbering>
        """
        try numberingXML.write(to: wordDir.appendingPathComponent("numbering.xml"), atomically: true, encoding: .utf8)

        // Create word/styles.xml for proper Word styling
        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:docDefaults>
                <w:rPrDefault>
                    <w:rPr>
                        <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>
                        <w:sz w:val="22"/>
                        <w:szCs w:val="22"/>
                    </w:rPr>
                </w:rPrDefault>
                <w:pPrDefault>
                    <w:pPr>
                        <w:spacing w:after="160" w:line="276" w:lineRule="auto"/>
                    </w:pPr>
                </w:pPrDefault>
            </w:docDefaults>
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
                <w:name w:val="Normal"/>
                <w:qFormat/>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading1">
                <w:name w:val="heading 1"/>
                <w:basedOn w:val="Normal"/>
                <w:next w:val="Normal"/>
                <w:qFormat/>
                <w:pPr>
                    <w:keepNext/>
                    <w:keepLines/>
                    <w:spacing w:before="480" w:after="0"/>
                    <w:outlineLvl w:val="0"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:bCs/>
                    <w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/>
                    <w:color w:val="2E74B5" w:themeColor="accent1" w:themeShade="BF"/>
                    <w:sz w:val="32"/>
                    <w:szCs w:val="32"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading2">
                <w:name w:val="heading 2"/>
                <w:basedOn w:val="Normal"/>
                <w:next w:val="Normal"/>
                <w:qFormat/>
                <w:pPr>
                    <w:keepNext/>
                    <w:keepLines/>
                    <w:spacing w:before="240" w:after="0"/>
                    <w:outlineLvl w:val="1"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:bCs/>
                    <w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/>
                    <w:color w:val="2E74B5" w:themeColor="accent1" w:themeShade="BF"/>
                    <w:sz w:val="26"/>
                    <w:szCs w:val="26"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading3">
                <w:name w:val="heading 3"/>
                <w:basedOn w:val="Normal"/>
                <w:next w:val="Normal"/>
                <w:qFormat/>
                <w:pPr>
                    <w:keepNext/>
                    <w:keepLines/>
                    <w:spacing w:before="240" w:after="0"/>
                    <w:outlineLvl w:val="2"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:bCs/>
                    <w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/>
                    <w:color w:val="1F4D78" w:themeColor="accent1" w:themeShade="7F"/>
                    <w:sz w:val="24"/>
                    <w:szCs w:val="24"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading4">
                <w:name w:val="heading 4"/>
                <w:basedOn w:val="Normal"/>
                <w:next w:val="Normal"/>
                <w:qFormat/>
                <w:pPr>
                    <w:keepNext/>
                    <w:keepLines/>
                    <w:spacing w:before="120" w:after="0"/>
                    <w:outlineLvl w:val="3"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:bCs/>
                    <w:rFonts w:ascii="Calibri Light" w:hAnsi="Calibri Light"/>
                    <w:i/>
                    <w:iCs/>
                    <w:color w:val="2E74B5" w:themeColor="accent1" w:themeShade="BF"/>
                </w:rPr>
            </w:style>
            <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">
                <w:name w:val="Default Paragraph Font"/>
                <w:semiHidden/>
            </w:style>
            <w:style w:type="table" w:default="1" w:styleId="TableNormal">
                <w:name w:val="Normal Table"/>
                <w:semiHidden/>
                <w:tblPr>
                    <w:tblCellMar>
                        <w:top w:w="0" w:type="dxa"/>
                        <w:left w:w="108" w:type="dxa"/>
                        <w:bottom w:w="0" w:type="dxa"/>
                        <w:right w:w="108" w:type="dxa"/>
                    </w:tblCellMar>
                </w:tblPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Code">
                <w:name w:val="Code"/>
                <w:basedOn w:val="Normal"/>
                <w:pPr>
                    <w:spacing w:after="0"/>
                    <w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/>
                </w:pPr>
                <w:rPr>
                    <w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>
                    <w:sz w:val="18"/>
                </w:rPr>
            </w:style>
        </w:styles>
        """
        try stylesXML.write(to: wordDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)

        // Create ZIP archive
        try createZipArchive(sourceURL: tempDir, destinationURL: outputURL)
    }

    private func generateDocumentXML(markdown: String) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
            <w:body>
        """

        let lines = markdown.components(separatedBy: .newlines)
        var i = 0
        var inCodeBlock = false
        var inList = false

        while i < lines.count {
            let line = lines[i]

            // Code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    inCodeBlock = false
                } else {
                    if inList { inList = false }
                    inCodeBlock = true
                }
                i += 1
                continue
            }

            if inCodeBlock {
                xml += createCodeParagraph(text: line)
                i += 1
                continue
            }

            // Tables
            if line.hasPrefix("|") && line.hasSuffix("|") {
                if inList { inList = false }

                xml += "<w:tbl>"
                xml += """
                    <w:tblPr>
                        <w:tblStyle w:val="TableGrid"/>
                        <w:tblW w:w="5000" w:type="pct"/>
                        <w:tblBorders>
                            <w:top w:val="single" w:sz="4" w:space="0" w:color="666666"/>
                            <w:left w:val="single" w:sz="4" w:space="0" w:color="666666"/>
                            <w:bottom w:val="single" w:sz="4" w:space="0" w:color="666666"/>
                            <w:right w:val="single" w:sz="4" w:space="0" w:color="666666"/>
                            <w:insideH w:val="single" w:sz="4" w:space="0" w:color="666666"/>
                            <w:insideV w:val="single" w:sz="4" w:space="0" w:color="666666"/>
                        </w:tblBorders>
                    </w:tblPr>
                    <w:tblGrid/>
                """

                var isFirstRow = true
                while i < lines.count && lines[i].hasPrefix("|") {
                    let currentLine = lines[i].trimmingCharacters(in: .whitespaces)

                    // Skip separator row
                    if currentLine.contains("---") || currentLine.contains("--") {
                        i += 1
                        isFirstRow = false
                        continue
                    }

                    let cells = currentLine
                        .split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    if !cells.isEmpty {
                        xml += "<w:tr>"
                        for cell in cells {
                            xml += "<w:tc>"
                            xml += "<w:tcPr>"
                            if isFirstRow {
                                xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"E8E8E8\"/>"
                            }
                            xml += "<w:tcBorders>"
                            xml += "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"666666\"/>"
                            xml += "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"666666\"/>"
                            xml += "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"666666\"/>"
                            xml += "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"666666\"/>"
                            xml += "</w:tcBorders>"
                            xml += "</w:tcPr>"
                            xml += "<w:p>"

                            // For header row, make text bold AND process inline formatting
                            if isFirstRow {
                                // Process inline formatting but wrap in bold
                                let formattedRuns = createRunsForFormattedText(cell)
                                // Add bold to all runs in the cell
                                xml += formattedRuns.replacingOccurrences(of: "<w:rPr>", with: "<w:rPr><w:b/>")
                                    .replacingOccurrences(of: "<w:r>", with: "<w:r><w:rPr><w:b/></w:rPr>")
                                    // Clean up double rPr tags
                                    .replacingOccurrences(of: "<w:rPr><w:b/><w:rPr>", with: "<w:rPr>")
                            } else {
                                // Regular cell - just process inline formatting
                                xml += createRunsForFormattedText(cell)
                            }

                            xml += "</w:p>"
                            xml += "</w:tc>"
                        }
                        xml += "</w:tr>"
                    }

                    i += 1
                }
                xml += "</w:tbl>"
                continue
            }

            // Headings
            if line.hasPrefix("#### ") {
                if inList { inList = false }
                xml += createHeadingParagraph(text: String(line.dropFirst(5)), level: 4)
            } else if line.hasPrefix("### ") {
                if inList { inList = false }
                xml += createHeadingParagraph(text: String(line.dropFirst(4)), level: 3)
            } else if line.hasPrefix("## ") {
                if inList { inList = false }
                xml += createHeadingParagraph(text: String(line.dropFirst(3)), level: 2)
            } else if line.hasPrefix("# ") {
                if inList { inList = false }
                xml += createHeadingParagraph(text: String(line.dropFirst(2)), level: 1)
            }
            // Bullet Lists
            else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                let itemText = String(line.dropFirst(2))
                xml += createListParagraph(text: itemText, numbered: false)
                inList = true
            }
            // Numbered Lists (1. 2. 3. etc)
            else if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let itemText = String(line[match.upperBound...])
                xml += createListParagraph(text: itemText, numbered: true)
                inList = true
            }
            // Horizontal rule (---, ___, ***)
            else if line.trimmingCharacters(in: .whitespaces).range(of: #"^([-_*])\1{2,}$"#, options: .regularExpression) != nil {
                if inList { inList = false }
                xml += createHorizontalRule()
            }
            // Empty line
            else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if inList { inList = false }
            }
            // Regular paragraph
            else if !line.isEmpty {
                if inList { inList = false }
                xml += createNormalParagraph(text: line)
            }

            i += 1
        }

        xml += """
                <w:sectPr>
                    <w:pgSz w:w="12240" w:h="15840"/>
                    <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>
                </w:sectPr>
            </w:body>
        </w:document>
        """

        return xml
    }

    private func createHeadingParagraph(text: String, level: Int) -> String {
        return """
            <w:p>
                <w:pPr>
                    <w:pStyle w:val="Heading\(level)"/>
                </w:pPr>
                <w:r>
                    <w:t>\(xmlEscape(formatInlineMarkdownForDOCX(text)))</w:t>
                </w:r>
            </w:p>
        """
    }

    private func createNormalParagraph(text: String) -> String {
        return """
            <w:p>
                <w:pPr>
                    <w:spacing w:after="160"/>
                </w:pPr>
                \(createRunsForFormattedText(text))
            </w:p>
        """
    }

    private func createListParagraph(text: String, numbered: Bool) -> String {
        // numId 1 = bullets, numId 2 = numbers
        let numId = numbered ? "2" : "1"
        return """
            <w:p>
                <w:pPr>
                    <w:numPr>
                        <w:ilvl w:val="0"/>
                        <w:numId w:val="\(numId)"/>
                    </w:numPr>
                </w:pPr>
                \(createRunsForFormattedText(text))
            </w:p>
        """
    }

    private func createCodeParagraph(text: String) -> String {
        return """
            <w:p>
                <w:pPr>
                    <w:pStyle w:val="Code"/>
                </w:pPr>
                <w:r>
                    <w:t xml:space="preserve">\(xmlEscape(text))</w:t>
                </w:r>
            </w:p>
        """
    }

    private func createHorizontalRule() -> String {
        return """
            <w:p>
                <w:r>
                    <w:pict>
                        <v:rect style="width:0;height:1.5pt" o:hralign="center" o:hrstd="t" o:hr="t"/>
                    </w:pict>
                </w:r>
            </w:p>
        """
    }

    private func createRunsForFormattedText(_ text: String) -> String {
        // Parse inline markdown formatting (bold, italic, code, links)
        var result = ""

        // Pattern matches: [text](url), **bold**, *italic*, or `code`
        // We need to handle them in order of appearance
        let combinedPattern = #"(\[([^\]]+)\]\(([^\)]+)\))|(\*\*([^\*]+)\*\*)|(\*([^\*]+)\*)|(`([^`]+)`)"#

        guard let regex = try? NSRegularExpression(pattern: combinedPattern) else {
            return createSimpleRun(text: text)
        }

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        if matches.isEmpty {
            return createSimpleRun(text: text)
        }

        var lastEnd = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }

            // Add text before this match
            if lastEnd < range.lowerBound {
                result += createSimpleRun(text: String(text[lastEnd..<range.lowerBound]))
            }

            // Determine match type and add formatted run
            if let linkTextRange = Range(match.range(at: 2), in: text),
               let linkURLRange = Range(match.range(at: 3), in: text) {
                // Link [text](url)
                result += createLinkRun(text: String(text[linkTextRange]), url: String(text[linkURLRange]))
            } else if let boldContentRange = Range(match.range(at: 5), in: text) {
                // Bold **text**
                result += createBoldRun(text: String(text[boldContentRange]))
            } else if let italicContentRange = Range(match.range(at: 7), in: text) {
                // Italic *text*
                result += createItalicRun(text: String(text[italicContentRange]))
            } else if let codeContentRange = Range(match.range(at: 9), in: text) {
                // Code `text`
                result += createCodeRun(text: String(text[codeContentRange]))
            }

            lastEnd = range.upperBound
        }

        // Add remaining text
        if lastEnd < text.endIndex {
            result += createSimpleRun(text: String(text[lastEnd...]))
        }

        return result
    }

    private func createSimpleRun(text: String) -> String {
        guard !text.isEmpty else { return "" }
        return """
            <w:r>
                <w:t xml:space="preserve">\(xmlEscape(text))</w:t>
            </w:r>
        """
    }

    private func createBoldRun(text: String) -> String {
        return """
            <w:r>
                <w:rPr>
                    <w:b/>
                </w:rPr>
                <w:t>\(xmlEscape(text))</w:t>
            </w:r>
        """
    }

    private func createItalicRun(text: String) -> String {
        return """
            <w:r>
                <w:rPr>
                    <w:i/>
                </w:rPr>
                <w:t>\(xmlEscape(text))</w:t>
            </w:r>
        """
    }

    private func createCodeRun(text: String) -> String {
        return """
            <w:r>
                <w:rPr>
                    <w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>
                    <w:shd w:val="clear" w:color="auto" w:fill="F5F5F5"/>
                </w:rPr>
                <w:t>\(xmlEscape(text))</w:t>
            </w:r>
        """
    }

    private func createLinkRun(text: String, url: String) -> String {
        // Generate unique relationship ID for this hyperlink
        let rId = "rId\(nextHyperlinkId)"
        nextHyperlinkId += 1

        // Track this hyperlink for the relationships file
        hyperlinkRelationships.append((id: rId, url: url))

        return """
            <w:hyperlink r:id="\(rId)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
                <w:r>
                    <w:rPr>
                        <w:color w:val="0563C1"/>
                        <w:u w:val="single"/>
                    </w:rPr>
                    <w:t>\(xmlEscape(text))</w:t>
                </w:r>
            </w:hyperlink>
        """
    }

    private func formatInlineMarkdownForDOCX(_ text: String) -> String {
        // Strip markdown formatting for headings (will be applied via DOCX styles)
        return text
            .replacingOccurrences(of: #"\*\*([^\*]+)\*\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\*([^\*]+)\*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
    }

    private func xmlEscape(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func createZipArchive(sourceURL: URL, destinationURL: URL) throws {
        // Create ZIP in temp directory first (sandbox-safe), then move it
        let tempZip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = sourceURL
        process.arguments = ["-r", "-X", tempZip.path, "."]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ExportManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create ZIP archive"])
        }

        // Remove existing file if it exists
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        // Move the ZIP to the final destination (respects sandbox permissions)
        try FileManager.default.moveItem(at: tempZip, to: destinationURL)
    }

}

