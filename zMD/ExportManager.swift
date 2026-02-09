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
                    ToastManager.shared.show("Exported as PDF", style: .success)
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
                ToastManager.shared.show("Exported as HTML", style: .success)
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
                    ToastManager.shared.show("Exported as RTF", style: .success)
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
                    try self.createCustomDOCX(content: content, outputURL: url, fileName: fileName)
                    ToastManager.shared.show("Exported as Word", style: .success)
                } catch {
                    self.alertManager.showExportError("DOCX", error: error)
                }
            }
        }
    }

    // Property to track hyperlinks during document generation
    private var hyperlinkRelationships: [(id: String, url: String)] = []
    private var nextHyperlinkId = 6 // rId1-5 reserved for numbering, styles, settings, header, footer
    private var numberedListCount = 0 // tracks how many separate numbered lists for numId generation

    private func createCustomDOCX(content: String, outputURL: URL, fileName: String? = nil) throws {
        // Reset hyperlink tracking for new document
        hyperlinkRelationships = []
        nextHyperlinkId = 6

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
            <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>
            <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
            <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
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

        // Create word/_rels/document.xml.rels
        var documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
            <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
            <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
            <Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        """

        for hyperlink in hyperlinkRelationships {
            documentRels += "\n    <Relationship Id=\"\(hyperlink.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(xmlEscape(hyperlink.url))\" TargetMode=\"External\"/>"
        }

        documentRels += "\n</Relationships>"
        try documentRels.write(to: wordRelsDir.appendingPathComponent("document.xml.rels"), atomically: true, encoding: .utf8)

        // Create word/header1.xml
        let docTitle = xmlEscape(fileName?.replacingOccurrences(of: ".md", with: "") ?? "Document")
        let headerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <w:p>
                <w:pPr><w:jc w:val="right"/></w:pPr>
                <w:r>
                    <w:rPr><w:i/><w:iCs/><w:color w:val="888888"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>
                    <w:t>\(docTitle)</w:t>
                </w:r>
            </w:p>
        </w:hdr>
        """
        try headerXML.write(to: wordDir.appendingPathComponent("header1.xml"), atomically: true, encoding: .utf8)

        // Create word/footer1.xml with page numbers
        let footerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
            <w:p>
                <w:pPr><w:jc w:val="center"/></w:pPr>
                <w:r>
                    <w:rPr><w:color w:val="888888"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>
                    <w:t xml:space="preserve">Page </w:t>
                </w:r>
                <w:r>
                    <w:rPr><w:color w:val="888888"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>
                    <w:fldChar w:fldCharType="begin"/>
                </w:r>
                <w:r>
                    <w:rPr><w:color w:val="888888"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>
                    <w:instrText>PAGE</w:instrText>
                </w:r>
                <w:r>
                    <w:rPr><w:color w:val="888888"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>
                    <w:fldChar w:fldCharType="separate"/>
                </w:r>
                <w:r>
                    <w:rPr><w:color w:val="888888"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>
                    <w:t>1</w:t>
                </w:r>
                <w:r>
                    <w:rPr><w:color w:val="888888"/><w:sz w:val="16"/><w:szCs w:val="16"/></w:rPr>
                    <w:fldChar w:fldCharType="end"/>
                </w:r>
            </w:p>
        </w:ftr>
        """
        try footerXML.write(to: wordDir.appendingPathComponent("footer1.xml"), atomically: true, encoding: .utf8)

        // Create word/settings.xml
        let settingsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" xmlns:o="urn:schemas-microsoft-com:office:office">
            <w:defaultTabStop w:val="720"/>
            <w:characterSpacingControl w:val="doNotCompress"/>
            <w:compat>
                <w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/>
            </w:compat>
            <m:mathPr>
                <m:mathFont m:val="Cambria Math"/>
            </m:mathPr>
        </w:settings>
        """
        try settingsXML.write(to: wordDir.appendingPathComponent("settings.xml"), atomically: true, encoding: .utf8)

        // Create word/numbering.xml
        // numId 1 = bullets (abstractNum 0), numId 2 = base numbered (abstractNum 1)
        // numIds 3+ = separate numbered lists, each restarting at 1
        var numberingXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:abstractNum w:abstractNumId="0">
                <w:multiLevelType w:val="hybridMultilevel"/>
                <w:lvl w:ilvl="0">
                    <w:start w:val="1"/>
                    <w:numFmt w:val="bullet"/>
                    <w:lvlText w:val="\u{2022}"/>
                    <w:lvlJc w:val="left"/>
                    <w:pPr>
                        <w:ind w:left="720" w:hanging="360"/>
                    </w:pPr>
                </w:lvl>
                <w:lvl w:ilvl="1">
                    <w:start w:val="1"/>
                    <w:numFmt w:val="bullet"/>
                    <w:lvlText w:val="\u{25CB}"/>
                    <w:lvlJc w:val="left"/>
                    <w:pPr>
                        <w:ind w:left="1440" w:hanging="360"/>
                    </w:pPr>
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
                <w:lvl w:ilvl="1">
                    <w:start w:val="1"/>
                    <w:numFmt w:val="lowerLetter"/>
                    <w:lvlText w:val="%2."/>
                    <w:lvlJc w:val="left"/>
                    <w:pPr>
                        <w:ind w:left="1440" w:hanging="360"/>
                    </w:pPr>
                </w:lvl>
            </w:abstractNum>
            <w:num w:numId="1">
                <w:abstractNumId w:val="0"/>
            </w:num>
            <w:num w:numId="2">
                <w:abstractNumId w:val="1"/>
            </w:num>
        """
        // Add a <w:num> for each separate numbered list, with restart override
        for listIdx in 1...max(numberedListCount, 1) {
            let numId = 2 + listIdx
            numberingXML += "\n    <w:num w:numId=\"\(numId)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        numberingXML += "\n</w:numbering>"
        try numberingXML.write(to: wordDir.appendingPathComponent("numbering.xml"), atomically: true, encoding: .utf8)

        // Create word/styles.xml
        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
            <w:docDefaults>
                <w:rPrDefault>
                    <w:rPr>
                        <w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/>
                        <w:sz w:val="22"/>
                        <w:szCs w:val="22"/>
                        <w:lang w:val="en-US"/>
                    </w:rPr>
                </w:rPrDefault>
                <w:pPrDefault/>
            </w:docDefaults>
            <w:style w:type="paragraph" w:default="1" w:styleId="Normal">
                <w:name w:val="Normal"/>
                <w:qFormat/>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading1">
                <w:name w:val="heading 1"/>
                <w:uiPriority w:val="9"/>
                <w:qFormat/>
                <w:pPr>
                    <w:spacing w:before="360" w:after="200"/>
                    <w:outlineLvl w:val="0"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:bCs/>
                    <w:color w:val="6D2040"/>
                    <w:sz w:val="32"/>
                    <w:szCs w:val="32"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading2">
                <w:name w:val="heading 2"/>
                <w:uiPriority w:val="9"/>
                <w:qFormat/>
                <w:pPr>
                    <w:spacing w:before="280" w:after="160"/>
                    <w:outlineLvl w:val="1"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:bCs/>
                    <w:color w:val="8C3A5A"/>
                    <w:sz w:val="26"/>
                    <w:szCs w:val="26"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading3">
                <w:name w:val="heading 3"/>
                <w:uiPriority w:val="9"/>
                <w:qFormat/>
                <w:pPr>
                    <w:spacing w:before="200" w:after="120"/>
                    <w:outlineLvl w:val="2"/>
                </w:pPr>
                <w:rPr>
                    <w:b/>
                    <w:bCs/>
                    <w:color w:val="A05070"/>
                    <w:sz w:val="22"/>
                    <w:szCs w:val="22"/>
                </w:rPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="Heading4">
                <w:name w:val="heading 4"/>
                <w:uiPriority w:val="9"/>
                <w:qFormat/>
                <w:pPr>
                    <w:outlineLvl w:val="3"/>
                </w:pPr>
                <w:rPr>
                    <w:i/>
                    <w:iCs/>
                    <w:color w:val="6D2040"/>
                </w:rPr>
            </w:style>
            <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont">
                <w:name w:val="Default Paragraph Font"/>
                <w:uiPriority w:val="1"/>
                <w:semiHidden/>
            </w:style>
            <w:style w:type="table" w:default="1" w:styleId="TableNormal">
                <w:name w:val="Normal Table"/>
                <w:uiPriority w:val="99"/>
                <w:semiHidden/>
                <w:tblPr>
                    <w:tblInd w:w="0" w:type="dxa"/>
                    <w:tblCellMar>
                        <w:top w:w="0" w:type="dxa"/>
                        <w:left w:w="108" w:type="dxa"/>
                        <w:bottom w:w="0" w:type="dxa"/>
                        <w:right w:w="108" w:type="dxa"/>
                    </w:tblCellMar>
                </w:tblPr>
            </w:style>
            <w:style w:type="paragraph" w:styleId="ListParagraph">
                <w:name w:val="List Paragraph"/>
                <w:qFormat/>
                <w:pPr>
                    <w:spacing w:before="20" w:after="80"/>
                    <w:ind w:left="720"/>
                </w:pPr>
            </w:style>
            <w:style w:type="character" w:styleId="Hyperlink">
                <w:name w:val="Hyperlink"/>
                <w:uiPriority w:val="99"/>
                <w:rPr>
                    <w:color w:val="0563C1"/>
                    <w:u w:val="single"/>
                </w:rPr>
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
                    <w:szCs w:val="18"/>
                </w:rPr>
            </w:style>
        </w:styles>
        """
        try stylesXML.write(to: wordDir.appendingPathComponent("styles.xml"), atomically: true, encoding: .utf8)

        // Create ZIP archive
        try createZipArchive(sourceURL: tempDir, destinationURL: outputURL)
    }

    // MARK: - DOCX Document XML Generation

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
        var inNumberedList = false
        var currentNumberedNumId = 2 // default numId for numbered lists
        var inBlockquote = false
        numberedListCount = 0

        while i < lines.count {
            let line = lines[i]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Code blocks
            if trimmedLine.hasPrefix("```") {
                if inCodeBlock {
                    inCodeBlock = false
                } else {
                    if inList { inList = false; inNumberedList = false }
                    if inBlockquote { inBlockquote = false }
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

            // Blockquotes
            if trimmedLine.hasPrefix("> ") {
                if inList { inList = false; inNumberedList = false }
                let quoteText = String(trimmedLine.dropFirst(2))
                xml += createBlockquoteParagraph(text: quoteText)
                inBlockquote = true
                i += 1
                continue
            } else if inBlockquote {
                inBlockquote = false
            }

            // Tables
            if trimmedLine.hasPrefix("|") && trimmedLine.hasSuffix("|") {
                if inList { inList = false; inNumberedList = false }

                // Collect all table rows to determine column count and widths
                var tableRows: [[String]] = []
                var separatorIndex = -1
                var tableStart = i

                while tableStart < lines.count {
                    let tl = lines[tableStart].trimmingCharacters(in: .whitespaces)
                    guard tl.hasPrefix("|") else { break }

                    if tl.contains("---") || tl.range(of: #"\|[\s:-]+\|"#, options: .regularExpression) != nil {
                        separatorIndex = tableRows.count
                        tableStart += 1
                        continue
                    }

                    let cells = tl
                        .split(separator: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }

                    if !cells.isEmpty {
                        tableRows.append(cells)
                    }
                    tableStart += 1
                }

                let columnCount = tableRows.map { $0.count }.max() ?? 1
                // Page width: 12240 - 1440 left - 1440 right = 9360 DXA
                let tableWidth = 9360
                let columnWidth = tableWidth / columnCount

                xml += "<w:tbl>"
                xml += "<w:tblPr>"
                xml += "<w:tblW w:w=\"\(tableWidth)\" w:type=\"dxa\"/>"
                xml += "<w:tblBorders>"
                xml += "<w:top w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                xml += "<w:left w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                xml += "<w:bottom w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                xml += "<w:right w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                xml += "<w:insideH w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                xml += "<w:insideV w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"auto\"/>"
                xml += "</w:tblBorders>"
                xml += "<w:tblCellMar>"
                xml += "<w:left w:w=\"10\" w:type=\"dxa\"/>"
                xml += "<w:right w:w=\"10\" w:type=\"dxa\"/>"
                xml += "</w:tblCellMar>"
                xml += "<w:tblLook w:val=\"0000\" w:firstRow=\"0\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"0\"/>"
                xml += "</w:tblPr>"
                xml += "<w:tblGrid>"
                for _ in 0..<columnCount {
                    xml += "<w:gridCol w:w=\"\(columnWidth)\"/>"
                }
                xml += "</w:tblGrid>"

                for (rowIndex, cells) in tableRows.enumerated() {
                    let isHeader = rowIndex == 0 && separatorIndex >= 0
                    xml += "<w:tr>"

                    for colIndex in 0..<columnCount {
                        let cellText = colIndex < cells.count ? cells[colIndex] : ""
                        xml += "<w:tc>"
                        xml += "<w:tcPr>"
                        xml += "<w:tcW w:w=\"\(columnWidth)\" w:type=\"dxa\"/>"
                        xml += "<w:tcBorders>"
                        xml += "<w:top w:val=\"single\" w:sz=\"1\" w:space=\"0\" w:color=\"AAAAAA\"/>"
                        xml += "<w:left w:val=\"single\" w:sz=\"1\" w:space=\"0\" w:color=\"AAAAAA\"/>"
                        xml += "<w:bottom w:val=\"single\" w:sz=\"1\" w:space=\"0\" w:color=\"AAAAAA\"/>"
                        xml += "<w:right w:val=\"single\" w:sz=\"1\" w:space=\"0\" w:color=\"AAAAAA\"/>"
                        xml += "</w:tcBorders>"

                        if isHeader {
                            xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"6D2040\"/>"
                        } else if rowIndex % 2 == 0 && separatorIndex >= 0 {
                            xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"E0E0E0\"/>"
                        }

                        xml += "<w:tcMar>"
                        xml += "<w:top w:w=\"60\" w:type=\"dxa\"/>"
                        xml += "<w:left w:w=\"100\" w:type=\"dxa\"/>"
                        xml += "<w:bottom w:w=\"60\" w:type=\"dxa\"/>"
                        xml += "<w:right w:w=\"100\" w:type=\"dxa\"/>"
                        xml += "</w:tcMar>"
                        xml += "</w:tcPr>"
                        xml += "<w:p>"

                        if isHeader {
                            xml += createHeaderCellRun(text: cellText)
                        } else {
                            xml += createRunsForFormattedText(cellText)
                        }

                        xml += "</w:p>"
                        xml += "</w:tc>"
                    }

                    xml += "</w:tr>"
                }

                xml += "</w:tbl>"
                // Add spacing paragraph after table
                xml += "<w:p><w:pPr><w:spacing w:before=\"120\"/></w:pPr></w:p>"
                i = tableStart
                continue
            }

            // Headings
            if trimmedLine.hasPrefix("#### ") {
                if inList { inList = false; inNumberedList = false }
                xml += createHeadingParagraph(text: String(trimmedLine.dropFirst(5)), level: 4)
            } else if trimmedLine.hasPrefix("### ") {
                if inList { inList = false; inNumberedList = false }
                xml += createHeadingParagraph(text: String(trimmedLine.dropFirst(4)), level: 3)
            } else if trimmedLine.hasPrefix("## ") {
                if inList { inList = false; inNumberedList = false }
                xml += createHeadingParagraph(text: String(trimmedLine.dropFirst(3)), level: 2)
            } else if trimmedLine.hasPrefix("# ") {
                if inList { inList = false; inNumberedList = false }
                xml += createHeadingParagraph(text: String(trimmedLine.dropFirst(2)), level: 1)
            }
            // Bullet Lists (including indented sub-items)
            else if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") {
                let itemText = String(trimmedLine.dropFirst(2))
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let level = min(indent / 2, 2) // 0, 1, or 2 based on indentation
                xml += createListParagraph(text: itemText, numId: 1, level: level)
                inList = true
            }
            // Numbered Lists (including indented: 1. 2. 3. etc)
            else if let match = trimmedLine.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let itemText = String(trimmedLine[match.upperBound...])
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
                let level = min(indent / 2, 2)
                if !inNumberedList {
                    // Starting a new numbered list — assign a new numId
                    numberedListCount += 1
                    currentNumberedNumId = 2 + numberedListCount // numId 3, 4, 5, etc.
                    inNumberedList = true
                }
                xml += createListParagraph(text: itemText, numId: currentNumberedNumId, level: level)
                inList = true
            }
            // Horizontal rule (---, ___, ***)
            else if trimmedLine.range(of: #"^([-_*])\1{2,}$"#, options: .regularExpression) != nil {
                if inList { inList = false; inNumberedList = false }
                xml += createHorizontalRule()
            }
            // Empty line
            else if trimmedLine.isEmpty {
                if inList { inList = false; inNumberedList = false }
            }
            // Regular paragraph
            else if !trimmedLine.isEmpty {
                if inList { inList = false; inNumberedList = false }
                xml += createNormalParagraph(text: line)
            }

            i += 1
        }

        xml += """
                <w:sectPr>
                    <w:headerReference w:type="default" r:id="rId4"/>
                    <w:footerReference w:type="default" r:id="rId5"/>
                    <w:pgSz w:w="12240" w:h="15840"/>
                    <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720"/>
                </w:sectPr>
            </w:body>
        </w:document>
        """

        return xml
    }

    // MARK: - DOCX Paragraph Helpers

    private func createHeadingParagraph(text: String, level: Int) -> String {
        return """
        <w:p><w:pPr><w:pStyle w:val="Heading\(level)"/></w:pPr>\(createRunsForFormattedText(formatInlineMarkdownForDOCX(text)))</w:p>
        """
    }

    private func createNormalParagraph(text: String) -> String {
        return """
        <w:p><w:pPr><w:spacing w:after="160"/></w:pPr>\(createRunsForFormattedText(text))</w:p>
        """
    }

    private func createListParagraph(text: String, numId: Int, level: Int = 0) -> String {
        return """
        <w:p><w:pPr><w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="\(level)"/><w:numId w:val="\(numId)"/></w:numPr></w:pPr>\(createRunsForFormattedText(text))</w:p>
        """
    }

    private func createCodeParagraph(text: String) -> String {
        return """
        <w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr><w:r><w:t xml:space="preserve">\(xmlEscape(text))</w:t></w:r></w:p>
        """
    }

    private func createBlockquoteParagraph(text: String) -> String {
        return """
        <w:p><w:pPr><w:pBdr><w:left w:val="single" w:sz="12" w:space="8" w:color="CCCCCC"/></w:pBdr><w:ind w:left="360"/><w:spacing w:after="120"/></w:pPr><w:r><w:rPr><w:i/><w:color w:val="555555"/></w:rPr><w:t xml:space="preserve">\(xmlEscape(text))</w:t></w:r></w:p>
        """
    }

    private func createHorizontalRule() -> String {
        return """
        <w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="CCCCCC"/></w:pBdr><w:spacing w:before="200" w:after="200"/></w:pPr></w:p>
        """
    }

    private func createHeaderCellRun(text: String) -> String {
        return "<w:r><w:rPr><w:b/><w:bCs/><w:color w:val=\"FFFFFF\"/></w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r>"
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

