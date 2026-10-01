import Foundation

// MARK: - Outlook .msg → EmailMessage

/// Parses Outlook `.msg` files (MS-OXMSG: an OLE2 compound file of MAPI property streams)
/// into the same `EmailMessage` model `.eml` uses, so rendering, read-only handling, and
/// Quick Look come for free. Foundation-only; member of the app, the Quick Look extension,
/// and the tests. Never throws — anything unreadable degrades to empty fields.
nonisolated enum OutlookMessage {
    static func parse(_ data: Data) -> EmailMessage? {
        guard let file = CompoundFile(data: data) else { return nil }
        let root = MAPIPropertySet(file: file, storage: file.root, isTopLevel: true)

        let codepage = root.int32(0x3FDE) ?? root.int32(0x3FFD) ?? 1252
        let encoding = Charsets.encoding(forCodepage: codepage) ?? .windowsCP1252

        var transportHeaders: [(name: String, value: String)] = []
        if let raw = root.string(0x007D, ansi: encoding) {
            transportHeaders = MIMEEntity.parseHeaders(Data(raw.utf8)).map { ($0.name, RFC2047.decode($0.value)) }
        }
        func transport(_ name: String) -> String? {
            transportHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        // Subject: PR_SUBJECT, else prefix + normalized subject.
        var subject = root.string(0x0037, ansi: encoding)
        if subject == nil, let normalized = root.string(0x0E1D, ansi: encoding) {
            subject = (root.string(0x003D, ansi: encoding) ?? "") + normalized
        }

        // Sender: prefer the SMTP address; Exchange's PR_SENDER_EMAIL_ADDRESS is often an X.500
        // "/O=…" string, which is useless to a reader.
        let senderName = root.string(0x0C1A, ansi: encoding)
        // 0x5D01 PidTagSenderSmtpAddress; 0x5D02 the sent-representing variant; 0x5D0A/0x5D0B
        // are what current Exchange exports actually populate when 0x5D01 is absent.
        var senderAddress: String?
        for id: UInt16 in [0x5D01, 0x5D02, 0x5D0A, 0x5D0B, 0x0C1F] {
            if let a = root.string(id, ansi: encoding), a.contains("@") { senderAddress = a; break }
        }
        var from: [EmailMessage.Address] = []
        if senderName != nil || senderAddress != nil {
            from = [EmailMessage.Address(name: senderName, address: senderAddress ?? senderName ?? "")]
        } else if let t = transport("From") {
            from = EmailMessage.parseAddresses(t)
        }

        // Recipients from the __recip_version1.0_#NNNNNNNN storages.
        var to: [EmailMessage.Address] = []
        var cc: [EmailMessage.Address] = []
        for storage in file.children(of: file.root).filter({ $0.name.hasPrefix("__recip_version1.0_") }).sorted(by: { $0.name < $1.name }) {
            let props = MAPIPropertySet(file: file, storage: storage, isTopLevel: false)
            let name = props.string(0x3001, ansi: encoding)
            var address = props.string(0x39FE, ansi: encoding)
            if address == nil, let a = props.string(0x3003, ansi: encoding), a.contains("@") { address = a }
            let entry = EmailMessage.Address(name: name, address: address ?? name ?? "")
            switch props.int32(0x0C15) ?? 1 {
            case 2: cc.append(entry)
            case 3: break   // Bcc: not shown
            default: to.append(entry)
            }
        }
        if to.isEmpty, let displayTo = root.string(0x0E04, ansi: encoding), !displayTo.isEmpty {
            to = displayTo.split(separator: ";").map { EmailMessage.Address(name: nil, address: $0.trimmingCharacters(in: .whitespaces)) }
        }

        // Date: client submit time, else delivery time, else the transport Date header.
        let date = root.date(0x0039) ?? root.date(0x0E06) ?? transport("Date").flatMap(EmailMessage.parseDate)

        // Bodies. PR_HTML (0x1013) is bytes in the internet code page. Compressed RTF may wrap
        // HTML (\fromhtml1) — de-encapsulate — or be genuine RTF, which becomes plain text.
        var htmlBody: String?
        var textBody = root.string(0x1000, ansi: encoding)
        if let htmlData = root.binary(0x1013), !htmlData.isEmpty {
            htmlBody = String(data: htmlData, encoding: encoding) ?? String(data: htmlData, encoding: .utf8)
        }
        if htmlBody == nil, let compressed = root.binary(0x1009), let rtf = CompressedRTF.decompress(compressed) {
            let doc = RTFDocument(rtf: rtf, defaultEncoding: encoding)
            if doc.isEncapsulatedHTML {
                htmlBody = doc.decapsulatedHTML()
            } else if textBody == nil || textBody!.isEmpty {
                textBody = doc.plainText()
            }
        }

        // Attachments from the __attach_version1.0_#NNNNNNNN storages.
        var attachments: [EmailMessage.Attachment] = []
        for storage in file.children(of: file.root).filter({ $0.name.hasPrefix("__attach_version1.0_") }).sorted(by: { $0.name < $1.name }) {
            let props = MAPIPropertySet(file: file, storage: storage, isTopLevel: false)
            let method = props.int32(0x3705) ?? 1
            let longName = props.string(0x3707, ansi: encoding)
            let shortName = props.string(0x3704, ansi: encoding)
            let mime = props.string(0x370E, ansi: encoding)?.lowercased()
            let cid = props.string(0x3712, ansi: encoding)
            let hidden = props.bool(0x7FFE) ?? false

            var data: Data?
            var name = longName ?? shortName
            var mimeType = mime ?? "application/octet-stream"
            if method == 5 {
                // Embedded message: the 0x3701 "stream" is a storage holding a nested .msg.
                // Surface it as an attachment; rendering nested messages is out of scope.
                name = (name ?? props.string(0x0037, ansi: encoding).map { $0 + ".msg" }) ?? "Attached message.msg"
                mimeType = "application/vnd.ms-outlook"
                data = Data()
            } else {
                data = props.binary(0x3701)
            }
            guard let payload = data else { continue }
            if name == nil, let ext = Charsets.fileExtension(forMime: mimeType) { name = "attachment." + ext }
            attachments.append(EmailMessage.Attachment(
                filename: name ?? "attachment",
                mimeType: mimeType,
                data: payload,
                contentId: cid.map { c in c.hasPrefix("<") && c.hasSuffix(">") ? String(c.dropFirst().dropLast()) : c },
                isInline: hidden || cid != nil
            ))
        }

        var headers: [(name: String, value: String)] = transportHeaders
        if headers.isEmpty {
            if let subject { headers.append(("Subject", subject)) }
            if let f = from.first { headers.append(("From", f.display)) }
        }

        return EmailMessage(
            headers: headers,
            subject: subject?.trimmingCharacters(in: .whitespaces),
            from: from, to: to, cc: cc,
            replyTo: transport("Reply-To").map(EmailMessage.parseAddresses) ?? [],
            date: date, rawDate: transport("Date"),
            textBody: textBody, htmlBody: htmlBody,
            attachments: attachments
        )
    }
}

// MARK: - MAPI property set

/// Reads the properties of one storage: fixed-size values from `__properties_version1.0`,
/// variable-size values from `__substg1.0_<ID><TYPE>` streams.
nonisolated struct MAPIPropertySet {
    let file: CompoundFile
    let storage: CompoundFile.Entry
    private let fixed: [UInt16: (type: UInt16, value: UInt64)]

    init(file: CompoundFile, storage: CompoundFile.Entry, isTopLevel: Bool) {
        self.file = file
        self.storage = storage
        var table: [UInt16: (UInt16, UInt64)] = [:]
        if let entry = file.child(of: storage, named: "__properties_version1.0"), let data = file.read(entry) {
            let headerSize = isTopLevel ? 32 : 8
            var offset = headerSize
            while offset + 16 <= data.count {
                let tag = data.le32(at: offset)
                let value = data.le64(at: offset + 8)
                table[UInt16(tag >> 16)] = (UInt16(tag & 0xFFFF), value)
                offset += 16
            }
        }
        fixed = table
    }

    private func stream(id: UInt16, type: UInt16) -> Data? {
        let name = String(format: "__substg1.0_%04X%04X", id, type)
        guard let entry = file.child(of: storage, named: name) else { return nil }
        return file.read(entry)
    }

    /// PT_UNICODE (001F) first, then PT_STRING8 (001E) in the message code page.
    func string(_ id: UInt16, ansi: String.Encoding) -> String? {
        if let data = stream(id: id, type: 0x001F) {
            var s = String(data: data, encoding: .utf16LittleEndian) ?? ""
            while s.hasSuffix("\0") { s.removeLast() }
            return s
        }
        if let data = stream(id: id, type: 0x001E) {
            var s = String(data: data, encoding: ansi) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            while s.hasSuffix("\0") { s.removeLast() }
            return s
        }
        return nil
    }

    func binary(_ id: UInt16) -> Data? { stream(id: id, type: 0x0102) }

    func int32(_ id: UInt16) -> Int32? {
        guard let (type, value) = fixed[id], type == 0x0003 else { return nil }
        return Int32(truncatingIfNeeded: value & 0xFFFF_FFFF)
    }

    func bool(_ id: UInt16) -> Bool? {
        guard let (type, value) = fixed[id], type == 0x000B else { return nil }
        return (value & 0xFF) != 0
    }

    /// PT_SYSTIME: FILETIME, 100ns intervals since 1601-01-01 UTC.
    func date(_ id: UInt16) -> Date? {
        guard let (type, value) = fixed[id], type == 0x0040, value != 0 else { return nil }
        let seconds = Double(value) / 10_000_000.0 - 11_644_473_600.0
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Compound File Binary (OLE2)

/// Minimal reader for MS-CFB: FAT / DIFAT / mini-FAT chains and the directory tree.
nonisolated final class CompoundFile: @unchecked Sendable {
    struct Entry: Sendable {
        let id: Int
        let name: String
        let type: UInt8        // 1 storage, 2 stream, 5 root
        let left: Int
        let right: Int
        let child: Int
        let startSector: Int
        let size: Int
    }

    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize = 64
    private let miniStreamCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private(set) var entries: [Entry] = []
    private var miniStream: Data = Data()

    var root: Entry { entries[0] }

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let maxChain = 1 << 22   // defensive bound against FAT loops

    init?(data: Data) {
        guard data.count >= 512,
              [UInt8](data.prefix(8)) == [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] else { return nil }
        self.data = data
        let sectorShift = Int(data.le16(at: 30))
        guard sectorShift == 9 || sectorShift == 12 else { return nil }
        sectorSize = 1 << sectorShift
        miniStreamCutoff = Int(data.le32(at: 56))

        // FAT via DIFAT: 109 entries in the header, then a chain of DIFAT sectors.
        let fatSectorCount = Int(data.le32(at: 44))
        var fatSectors: [UInt32] = []
        for i in 0..<109 where fatSectors.count < fatSectorCount {
            let s = data.le32(at: 76 + i * 4)
            if s != Self.freeSector { fatSectors.append(s) }
        }
        var difat = data.le32(at: 68)
        var difatGuard = 0
        while difat != Self.endOfChain && difat != Self.freeSector && fatSectors.count < fatSectorCount && difatGuard < 10_000 {
            guard let sector = sectorData(Int(difat)) else { break }
            let perSector = sectorSize / 4 - 1
            for i in 0..<perSector where fatSectors.count < fatSectorCount {
                let s = sector.le32(at: i * 4)
                if s != Self.freeSector { fatSectors.append(s) }
            }
            difat = sector.le32(at: perSector * 4)
            difatGuard += 1
        }
        for s in fatSectors {
            guard let sector = sectorData(Int(s)) else { continue }
            for i in 0..<(sectorSize / 4) { fat.append(sector.le32(at: i * 4)) }
        }

        // Directory.
        let firstDirectory = Int(data.le32(at: 48))
        let directory = readChain(startSector: firstDirectory)
        var list: [Entry] = []
        var offset = 0
        while offset + 128 <= directory.count {
            let nameLength = Int(directory.le16(at: offset + 64))
            let nameBytes = directory.subdata(in: (offset)..<(offset + max(0, min(64, nameLength))))
            var name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
            while name.hasSuffix("\0") { name.removeLast() }
            let type = directory[directory.startIndex + offset + 66]
            let sizeLow = Int(directory.le32(at: offset + 120))
            list.append(Entry(
                id: list.count, name: name, type: type,
                left: Int(Int32(bitPattern: directory.le32(at: offset + 68))),
                right: Int(Int32(bitPattern: directory.le32(at: offset + 72))),
                child: Int(Int32(bitPattern: directory.le32(at: offset + 76))),
                startSector: Int(directory.le32(at: offset + 116)),
                size: sizeLow
            ))
            offset += 128
        }
        guard let first = list.first, first.type == 5 else { return nil }
        entries = list

        // Mini FAT + mini stream (the root entry's stream).
        let miniFatStart = Int(data.le32(at: 60))
        let miniFatData = readChain(startSector: miniFatStart)
        var mf: [UInt32] = []
        var o = 0
        while o + 4 <= miniFatData.count { mf.append(miniFatData.le32(at: o)); o += 4 }
        miniFat = mf
        miniStream = readChain(startSector: first.startSector).prefix(first.size)
    }

    // MARK: Tree

    func children(of storage: Entry) -> [Entry] {
        var result: [Entry] = []
        var stack = [storage.child]
        var seen = Set<Int>()
        while let id = stack.popLast() {
            guard id >= 0, id < entries.count, seen.insert(id).inserted else { continue }
            let e = entries[id]
            result.append(e)
            stack.append(e.left)
            stack.append(e.right)
        }
        return result
    }

    func child(of storage: Entry, named name: String) -> Entry? {
        children(of: storage).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Streams

    func read(_ entry: Entry) -> Data? {
        guard entry.type == 2 else { return nil }
        if entry.size < miniStreamCutoff {
            return readMiniChain(startSector: entry.startSector).prefix(entry.size)
        }
        return readChain(startSector: entry.startSector).prefix(entry.size)
    }

    private func sectorData(_ sector: Int) -> Data? {
        let start = (sector + 1) * sectorSize
        guard sector >= 0, start + sectorSize <= data.count else { return nil }
        return data.subdata(in: start..<(start + sectorSize))
    }

    private func readChain(startSector: Int) -> Data {
        var out = Data()
        var sector = UInt32(truncatingIfNeeded: startSector)
        var guardCount = 0
        while sector < Self.endOfChain - 1, guardCount < Self.maxChain {   // < 0xFFFF_FFFD
            guard let chunk = sectorData(Int(sector)) else { break }
            out.append(chunk)
            guard Int(sector) < fat.count else { break }
            sector = fat[Int(sector)]
            guardCount += 1
        }
        return out
    }

    private func readMiniChain(startSector: Int) -> Data {
        var out = Data()
        var sector = UInt32(truncatingIfNeeded: startSector)
        var guardCount = 0
        while sector < Self.endOfChain - 1, guardCount < Self.maxChain {
            let start = Int(sector) * miniSectorSize
            guard start + miniSectorSize <= miniStream.count else {
                if start < miniStream.count { out.append(miniStream.suffix(from: miniStream.startIndex + start)) }
                break
            }
            out.append(miniStream.subdata(in: (miniStream.startIndex + start)..<(miniStream.startIndex + start + miniSectorSize)))
            guard Int(sector) < miniFat.count else { break }
            sector = miniFat[Int(sector)]
            guardCount += 1
        }
        return out
    }
}

nonisolated extension Data {
    func le16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        let b = startIndex + offset
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func le32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let b = startIndex + offset
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }
    func le64(at offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        return UInt64(le32(at: offset)) | UInt64(le32(at: offset + 4)) << 32
    }
}

// MARK: - Compressed RTF (MS-OXRTFCP, "LZFu")

nonisolated enum CompressedRTF {
    /// The 207-byte initial dictionary from MS-OXRTFCP §2.1.2.2. Reconstructed and verified
    /// byte-for-byte against real Outlook output (every back-reference into the prefix must
    /// resolve to this text): a font-family header, color table, CRLF, and common control
    /// words. Note the literal CRLF at offsets 168–169.
    static let initialDictionary: [UInt8] = Array((
        "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman \\fswiss \\fmodern " +
        "\\fscript \\fdecor MS Sans SerifSymbolArialTimes New RomanCourier{\\colortbl\\red0\\green0\\blue0" +
        "\r\n\\par \\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx"
    ).utf8)

    /// Returns the RTF bytes, or nil if the header is not LZFu/MELA.
    static func decompress(_ data: Data, dictionary: [UInt8] = initialDictionary) -> Data? {
        guard data.count >= 16 else { return nil }
        let compressedSize = Int(data.le32(at: 0))
        let rawSize = Int(data.le32(at: 4))
        let magic = data.le32(at: 8)
        let payloadEnd = min(data.count, compressedSize + 4)
        if magic == 0x414C_454D {   // "MELA": stored uncompressed
            return data.subdata(in: 16..<min(data.count, 16 + rawSize))
        }
        guard magic == 0x7546_5A4C else { return nil }   // "LZFu"

        var dict = [UInt8](repeating: 0, count: 4096)
        let prefix = dictionary
        for (i, b) in prefix.enumerated() where i < 4096 { dict[i] = b }
        var writePos = prefix.count
        var out: [UInt8] = []
        out.reserveCapacity(rawSize)
        let bytes = [UInt8](data)
        var i = 16
        outer: while i < payloadEnd {
            let control = bytes[i]; i += 1
            for bit in 0..<8 {
                guard i < payloadEnd else { break outer }
                if (control >> bit) & 1 == 0 {
                    let b = bytes[i]; i += 1
                    out.append(b)
                    dict[writePos % 4096] = b
                    writePos += 1
                } else {
                    guard i + 1 < payloadEnd else { break outer }
                    let word = Int(bytes[i]) << 8 | Int(bytes[i + 1]); i += 2
                    let offset = word >> 4
                    let length = (word & 0x0F) + 2
                    if offset == writePos % 4096 { break outer }   // end marker
                    for k in 0..<length {
                        let b = dict[(offset + k) % 4096]
                        out.append(b)
                        dict[writePos % 4096] = b
                        writePos += 1
                    }
                }
                if out.count >= rawSize && rawSize > 0 { break outer }
            }
        }
        return Data(out)
    }
}

// MARK: - RTF reader (plain text, and HTML de-encapsulation per MS-OXRTFEX)

nonisolated struct RTFDocument {
    private let bytes: [UInt8]
    private let encoding: String.Encoding

    init(rtf: Data, defaultEncoding: String.Encoding) {
        bytes = [UInt8](rtf)
        var enc = defaultEncoding
        // \ansicpgN overrides the message code page.
        if let s = String(data: rtf.prefix(256), encoding: .ascii),
           let r = s.range(of: #"\\ansicpg(\d+)"#, options: .regularExpression),
           let cp = Int(s[r].dropFirst(8)), let e = Charsets.encoding(forCodepage: cp) {
            enc = e
        }
        encoding = enc
    }

    var isEncapsulatedHTML: Bool {
        // Latin-1 never fails to decode, so a high byte in a font name cannot hide the marker.
        guard let head = String(data: Data(bytes.prefix(512)), encoding: .isoLatin1) else { return false }
        return head.contains("\\fromhtml1")
    }

    func decapsulatedHTML() -> String { render(html: true) }
    func plainText() -> String { render(html: false) }

    /// Single-pass tokenizer. In HTML mode: `{\*\htmltag N …}` contents are emitted verbatim
    /// (they ARE the HTML); ordinary text is emitted escaped unless inside `\htmlrtf … \htmlrtf0`
    /// (RTF-only rendition). In text mode: skips the usual non-content destinations and turns
    /// \par / \line into newlines.
    private func render(html: Bool) -> String {
        var out = ""
        var pendingBytes: [UInt8] = []          // consecutive \'xx bytes, decoded together
        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            let s = String(bytes: pendingBytes, encoding: encoding) ?? String(bytes: pendingBytes, encoding: .windowsCP1252) ?? ""
            pendingBytes.removeAll()
            emitText(s)
        }
        var groupStack: [(skip: Bool, htmlTag: Bool, ucSkip: Int)] = [(false, false, 1)]
        var htmlRtf = false                      // \htmlrtf toggles (HTML mode)
        var skipNextUnicodeFallback = 0

        func emitText(_ s: String) {
            guard let top = groupStack.last, !top.skip else { return }
            if html {
                if top.htmlTag { out += s }            // raw HTML
                else if !htmlRtf { out += EmailHTMLSanitizer.escape(s) }
            } else {
                out += s
            }
        }
        func emitRaw(_ s: String) {                 // control-word output (newline/tab)
            guard let top = groupStack.last, !top.skip else { return }
            if html { if top.htmlTag || !htmlRtf { out += s } } else { out += s }
        }

        let skippedDestinations: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "object",
                                                "header", "footer", "headerl", "headerr", "footerl", "footerr",
                                                "xmlnstbl", "listtable", "listoverridetable", "rsidtbl",
                                                "generator", "themedata", "colorschememapping", "latentstyles",
                                                "datastore", "mhtmltag", "pntext", "fldinst", "revtbl"]
        var i = 0
        var pendingIgnorable = false
        let n = bytes.count
        while i < n {
            let c = bytes[i]
            switch c {
            case 0x7B: // {
                flushBytes()
                let parent = groupStack.last ?? (false, false, 1)
                groupStack.append((parent.skip, false, parent.ucSkip))
                pendingIgnorable = false
                i += 1
            case 0x7D: // }
                flushBytes()
                if groupStack.count > 1 { groupStack.removeLast() }
                pendingIgnorable = false
                i += 1
            case 0x5C: // backslash
                guard i + 1 < n else { i = n; break }
                let next = bytes[i + 1]
                if next == 0x27 { // \'xx
                    if i + 3 < n, let hi = hexValue(bytes[i + 2]), let lo = hexValue(bytes[i + 3]) {
                        if skipNextUnicodeFallback > 0 { skipNextUnicodeFallback -= 1 }
                        else { pendingBytes.append(hi << 4 | lo) }
                        i += 4
                    } else { i += 2 }
                } else if next == 0x2A { // \*
                    pendingIgnorable = true
                    i += 2
                } else if (next >= 0x61 && next <= 0x7A) || (next >= 0x41 && next <= 0x5A) {
                    // control word
                    var j = i + 1
                    var word = ""
                    while j < n, (bytes[j] >= 0x61 && bytes[j] <= 0x7A) || (bytes[j] >= 0x41 && bytes[j] <= 0x5A) {
                        word.append(Character(UnicodeScalar(bytes[j]))); j += 1
                    }
                    var param: Int?
                    var negative = false
                    if j < n, bytes[j] == 0x2D { negative = true; j += 1 }
                    var digits = ""
                    while j < n, bytes[j] >= 0x30 && bytes[j] <= 0x39 { digits.append(Character(UnicodeScalar(bytes[j]))); j += 1 }
                    if !digits.isEmpty, let v = Int(digits) { param = negative ? -v : v }
                    if j < n, bytes[j] == 0x20 { j += 1 }   // delimiter space is consumed
                    i = j
                    flushBytes()
                    handleControlWord(word, param)
                } else {
                    // control symbol: \{ \} \\ \~ \- \_ etc.
                    flushBytes()
                    switch next {
                    case 0x7B, 0x7D, 0x5C: emitText(String(UnicodeScalar(next)))
                    case 0x7E: emitText("\u{00A0}")
                    case 0x5F: emitText("\u{2011}")
                    case 0x0A, 0x0D: emitRaw("\n")
                    default: break
                    }
                    i += 2
                }
            case 0x0D, 0x0A:
                i += 1   // raw line breaks are not content
            default:
                // After \uN the next \uc characters are the ANSI fallback (usually a plain "?").
                if skipNextUnicodeFallback > 0 { skipNextUnicodeFallback -= 1 } else { pendingBytes.append(c) }
                i += 1
            }

            func handleControlWord(_ word: String, _ param: Int?) {
                let topIndex = groupStack.count - 1
                if pendingIgnorable {
                    pendingIgnorable = false
                    if html && word == "htmltag" {
                        groupStack[topIndex].htmlTag = true
                        return
                    }
                    // Unknown ignorable destination → skip the whole group.
                    groupStack[topIndex].skip = true
                    return
                }
                if skippedDestinations.contains(word) {
                    groupStack[topIndex].skip = true
                    return
                }
                switch word {
                case "htmlrtf":
                    if html { htmlRtf = (param ?? 1) != 0 }
                case "par", "line":
                    emitRaw(html ? "\r\n" : "\n")
                case "tab":
                    emitRaw("\t")
                case "uc":
                    groupStack[topIndex].ucSkip = param ?? 1
                case "u":
                    if let p = param {
                        let code = p < 0 ? p + 65536 : p
                        if let scalar = UnicodeScalar(code) { emitText(String(Character(scalar))) }
                        skipNextUnicodeFallback = groupStack[topIndex].ucSkip
                    }
                case "emdash": emitText("\u{2014}")
                case "endash": emitText("\u{2013}")
                case "lquote": emitText("\u{2018}")
                case "rquote": emitText("\u{2019}")
                case "ldblquote": emitText("\u{201C}")
                case "rdblquote": emitText("\u{201D}")
                case "bullet": emitText("\u{2022}")
                default: break
                }
            }
        }
        flushBytes()
        return out
    }

    private func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }
}

nonisolated extension Charsets {
    static func encoding(forCodepage cp: Int32) -> String.Encoding? { encoding(forCodepage: Int(cp)) }
    static func encoding(forCodepage cp: Int) -> String.Encoding? {
        switch cp {
        case 65001: return .utf8
        case 1200: return .utf16LittleEndian
        case 1201: return .utf16BigEndian
        case 1252: return .windowsCP1252
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        case 28591: return .isoLatin1
        case 28592: return .isoLatin2
        case 932: return .shiftJIS
        case 10000: return .macOSRoman
        case 20127: return .ascii
        default:
            let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(cp))
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }
}
