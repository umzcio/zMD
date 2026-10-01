import Foundation

// MARK: - Model

/// A parsed RFC 5322 / MIME email (.eml), plus the rendering that turns it into the markdown
/// zMD's existing pipeline displays and exports.
///
/// Foundation-only and `nonisolated` on purpose: this file is a member of the app, the Quick
/// Look extension, and the test target. Anything AppKit here breaks the extension build.
nonisolated struct EmailMessage: Sendable {
    struct Address: Sendable, Equatable {
        let name: String?
        let address: String

        /// `Name <addr>` when a display name exists, else the bare address.
        var display: String {
            if let name, !name.isEmpty, name != address { return "\(name) <\(address)>" }
            return address
        }
    }

    struct Attachment: Sendable {
        let filename: String
        let mimeType: String
        let data: Data
        /// `Content-ID` without the angle brackets, for `cid:` references from the HTML body.
        let contentId: String?
        /// Content-Disposition was `inline` (or the part lives in a multipart/related).
        let isInline: Bool
    }

    /// Decoded, unfolded headers in original order (names as written).
    let headers: [(name: String, value: String)]
    let subject: String?
    let from: [Address]
    let to: [Address]
    let cc: [Address]
    let replyTo: [Address]
    let date: Date?
    /// The raw `Date:` header, shown when the date could not be parsed.
    let rawDate: String?
    let textBody: String?
    let htmlBody: String?
    let attachments: [Attachment]

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Attachments the user would think of as files — excludes inline resources that the HTML
    /// body references via `cid:` (those are rendered in place, not listed).
    var fileAttachments: [Attachment] {
        let referencedIds = Set(Self.contentIdReferences(in: htmlBody ?? ""))
        return attachments.filter { attachment in
            guard let cid = attachment.contentId, attachment.isInline else { return true }
            return !referencedIds.contains(cid.lowercased())
        }
    }

    static func contentIdReferences(in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"cid:([^"'\s>)]+)"#, options: .caseInsensitive) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { html[$0].lowercased() }
        }
    }
}

// MARK: - Parsing

nonisolated extension EmailMessage {
    /// Parse raw `.eml` bytes. Never throws: a malformed message degrades to "whatever headers
    /// could be read + the body as plain text" rather than refusing to open.
    static func parse(_ data: Data) -> EmailMessage {
        let entity = MIMEEntity.parse(data)
        var collector = BodyCollector()
        collector.collect(entity, inRelated: false)

        let headers = entity.decodedHeaders
        func h(_ n: String) -> String? { headers.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value }

        let rawDate = h("Date")
        return EmailMessage(
            headers: headers,
            subject: h("Subject")?.trimmingCharacters(in: .whitespaces),
            from: parseAddresses(h("From")),
            to: parseAddresses(h("To")),
            cc: parseAddresses(h("Cc")),
            replyTo: parseAddresses(h("Reply-To")),
            date: rawDate.flatMap(parseDate),
            rawDate: rawDate,
            textBody: collector.text,
            htmlBody: collector.html,
            attachments: collector.attachments
        )
    }

    /// Walks the MIME tree choosing the body and collecting attachments.
    /// - multipart/alternative: the LAST text/html wins over text/plain (parts are ordered by
    ///   increasing preference per RFC 2046); the plain version is still kept as the fallback.
    /// - multipart/related: the first part is the body, the rest are inline resources.
    /// - multipart/mixed (and anything else): first text part(s) are body, other leaves are
    ///   attachments.
    private struct BodyCollector {
        var text: String?
        var html: String?
        var attachments: [Attachment] = []

        mutating func collect(_ entity: MIMEEntity, inRelated: Bool) {
            let type = entity.contentType
            if type.type == "multipart" {
                let related = inRelated || type.subtype == "related"
                for (index, part) in entity.parts.enumerated() {
                    // In multipart/related only the root (first) part may be body; siblings
                    // are resources even when they are text/html.
                    collect(part, inRelated: related && index > 0 ? true : related && index == 0 ? false : inRelated)
                }
                return
            }
            if type.type == "message" && type.subtype == "rfc822" {
                attachments.append(entity.asAttachment(defaultName: "Forwarded message.eml", inline: false))
                return
            }
            let isAttachmentDisposition = entity.disposition.type == "attachment"
            if type.type == "text", !isAttachmentDisposition, !inRelated {
                let string = entity.decodedText()
                if type.subtype == "html" {
                    if html == nil || true { html = string }   // later alternatives are preferred
                } else if type.subtype == "plain" {
                    if text == nil { text = string } else { text! += "\n\n" + string }
                } else if text == nil {
                    text = string
                }
                return
            }
            // Everything else is an attachment or inline resource.
            let inline = entity.disposition.type == "inline" || inRelated || (entity.contentId != nil && !isAttachmentDisposition)
            attachments.append(entity.asAttachment(defaultName: "attachment", inline: inline))
        }
    }

    // MARK: Addresses

    /// `Name <a@b>`, `"Name" <a@b>`, `a@b (Name)`, `a@b`, groups and commas inside quotes.
    static func parseAddresses(_ header: String?) -> [Address] {
        guard let header, !header.isEmpty else { return [] }
        var result: [Address] = []
        for item in splitTopLevel(header, on: ",") {
            let s = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            if let open = s.lastIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
                let addr = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                var name = String(s[..<open]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                    name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
                }
                result.append(Address(name: name.isEmpty ? nil : name, address: addr))
            } else if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
                let addr = String(s[..<open]).trimmingCharacters(in: .whitespaces)
                let name = String(s[s.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                result.append(Address(name: name.isEmpty ? nil : name, address: addr))
            } else {
                result.append(Address(name: nil, address: s))
            }
        }
        return result
    }

    /// Split on `separator` outside double quotes, angle brackets, and parentheses.
    static func splitTopLevel(_ s: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var depth = 0
        var previous: Character?
        for ch in s {
            if ch == "\"" && previous != "\\" { inQuotes.toggle() }
            else if !inQuotes {
                if ch == "<" || ch == "(" { depth += 1 }
                else if ch == ">" || ch == ")" { depth = max(0, depth - 1) }
                else if ch == separator && depth == 0 {
                    parts.append(current); current = ""; previous = ch; continue
                }
            }
            current.append(ch)
            previous = ch
        }
        parts.append(current)
        return parts
    }

    // MARK: Dates

    private static let dateFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z",
        "d MMM yy HH:mm:ss Z",
    ]

    static func parseDate(_ raw: String) -> Date? {
        // Drop a trailing "(PDT)"-style comment and collapse whitespace.
        var s = raw
        if let paren = s.firstIndex(of: "(") { s = String(s[..<paren]) }
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        // Obsolete zone names RFC 5322 still allows.
        let zones = ["UT": "+0000", "GMT": "+0000", "EST": "-0500", "EDT": "-0400", "CST": "-0600",
                     "CDT": "-0500", "MST": "-0700", "MDT": "-0600", "PST": "-0800", "PDT": "-0700", "Z": "+0000"]
        for (name, offset) in zones where s.hasSuffix(" " + name) {
            s = String(s.dropLast(name.count)) + offset
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: s) { return date }
        }
        return nil
    }
}

// MARK: - MIME entity

/// One MIME entity: headers plus either leaf body bytes or child parts.
nonisolated struct MIMEEntity: Sendable {
    struct ContentType: Sendable {
        let type: String        // lowercased, e.g. "text"
        let subtype: String     // lowercased, e.g. "html"
        let parameters: [String: String]
        var charset: String? { parameters["charset"] }
        var boundary: String? { parameters["boundary"] }
    }
    struct Disposition: Sendable {
        let type: String?       // "attachment" / "inline" / nil
        let parameters: [String: String]
    }

    /// Raw (unfolded, undecoded) headers in order.
    let rawHeaders: [(name: String, value: String)]
    let body: Data
    let parts: [MIMEEntity]

    var decodedHeaders: [(name: String, value: String)] {
        rawHeaders.map { ($0.name, RFC2047.decode($0.value)) }
    }

    func rawHeader(_ name: String) -> String? {
        rawHeaders.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentType: ContentType {
        guard let raw = rawHeader("Content-Type") else {
            return ContentType(type: "text", subtype: "plain", parameters: ["charset": "us-ascii"])
        }
        let (value, params) = MIMEHeaderValue.parse(raw)
        let pieces = value.lowercased().split(separator: "/", maxSplits: 1).map(String.init)
        return ContentType(type: pieces.first ?? "text", subtype: pieces.count > 1 ? pieces[1] : "plain", parameters: params)
    }

    var disposition: Disposition {
        guard let raw = rawHeader("Content-Disposition") else { return Disposition(type: nil, parameters: [:]) }
        let (value, params) = MIMEHeaderValue.parse(raw)
        return Disposition(type: value.lowercased(), parameters: params)
    }

    var contentId: String? {
        guard var cid = rawHeader("Content-ID")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if cid.hasPrefix("<") { cid.removeFirst() }
        if cid.hasSuffix(">") { cid.removeLast() }
        return cid.isEmpty ? nil : cid
    }

    var filename: String? {
        if let name = disposition.parameters["filename"] { return RFC2047.decode(name) }
        if let name = contentType.parameters["name"] { return RFC2047.decode(name) }
        return nil
    }

    /// Body bytes after Content-Transfer-Encoding is undone.
    func decodedBody() -> Data {
        let encoding = (rawHeader("Content-Transfer-Encoding") ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased()
        switch encoding {
        case "base64": return TransferEncoding.decodeBase64(body)
        case "quoted-printable": return TransferEncoding.decodeQuotedPrintable(body)
        default: return body
        }
    }

    /// Body as text, honoring the part's charset (falling back through UTF-8 and CP1252).
    func decodedText() -> String {
        let data = decodedBody()
        let charset = contentType.charset
        if let charset, let encoding = Charsets.encoding(named: charset), let s = String(data: data, encoding: encoding) {
            return s
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    func asAttachment(defaultName: String, inline: Bool) -> EmailMessage.Attachment {
        let type = contentType
        let mime = "\(type.type)/\(type.subtype)"
        var name = filename ?? defaultName
        if filename == nil, let ext = Charsets.fileExtension(forMime: mime) { name += "." + ext }
        return EmailMessage.Attachment(filename: name, mimeType: mime, data: decodedBody(), contentId: contentId, isInline: inline)
    }

    // MARK: Parsing

    static func parse(_ data: Data) -> MIMEEntity {
        let (headerData, bodyData) = splitHeaders(data)
        let headers = parseHeaders(headerData)
        var entity = MIMEEntity(rawHeaders: headers, body: bodyData, parts: [])
        let type = entity.contentType
        if type.type == "multipart", let boundary = type.boundary, !boundary.isEmpty {
            let parts = splitMultipart(bodyData, boundary: boundary).map(parse)
            entity = MIMEEntity(rawHeaders: headers, body: bodyData, parts: parts)
        }
        return entity
    }

    /// Header block ends at the first blank line (CRLF CRLF or LF LF). A message with no blank
    /// line is all headers.
    static func splitHeaders(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                // "\n\n"
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { return (data.prefix(i), data.dropFirst(i + 2)) }
                // "\n\r\n"
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A { return (data.prefix(i), data.dropFirst(i + 3)) }
            }
            i += 1
        }
        return (data, Data())
    }

    /// Unfold continuation lines and split `Name: value`. Header bytes are decoded as Latin-1
    /// so nothing is lost before RFC 2047 decoding.
    static func parseHeaders(_ data: Data) -> [(name: String, value: String)] {
        let text = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        var logical: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !logical.isEmpty {
                logical[logical.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                logical.append(line)
            }
        }
        return logical.compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { return nil }
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            return (name, value)
        }
    }

    /// Bodies between `--boundary` delimiter lines, up to `--boundary--`. The CRLF before a
    /// delimiter belongs to the delimiter, not the part (RFC 2046 §5.1.1).
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [Data] = []
        var partStart: Int?
        var i = 0
        func isDelimiter(at index: Int) -> (Bool, closing: Bool, next: Int)? {
            guard index + delimiter.count <= bytes.count, Array(bytes[index..<index + delimiter.count]) == delimiter else { return nil }
            var j = index + delimiter.count
            var closing = false
            if j + 1 < bytes.count, bytes[j] == 0x2D, bytes[j + 1] == 0x2D { closing = true; j += 2 }
            // Skip transport padding and the line end.
            while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
            if j < bytes.count, bytes[j] == 0x0D { j += 1 }
            if j < bytes.count, bytes[j] == 0x0A { j += 1 }
            return (true, closing, j)
        }
        while i < bytes.count {
            let atLineStart = i == 0 || bytes[i - 1] == 0x0A
            if atLineStart, let (_, closing, next) = isDelimiter(at: i) {
                if let start = partStart {
                    var end = i
                    if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                    if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                    parts.append(Data(bytes[start..<end]))
                }
                if closing { break }
                partStart = next
                i = next
                continue
            }
            i += 1
        }
        // Unterminated multipart (truncated file): keep the trailing part rather than drop it.
        if let start = partStart, i >= bytes.count, start < bytes.count {
            parts.append(Data(bytes[start...]))
        }
        return parts
    }
}

// MARK: - Header value grammar

/// `value; param=token; param="quoted"; param*=utf-8''pct-encoded; param*0=...; param*1=...`
nonisolated enum MIMEHeaderValue {
    static func parse(_ raw: String) -> (value: String, parameters: [String: String]) {
        let pieces = EmailMessage.splitTopLevel(raw, on: ";")
        let value = pieces.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var params: [String: String] = [:]
        var continuations: [String: [(Int, String, Bool)]] = [:]   // name -> (index, value, encoded)
        for piece in pieces.dropFirst() {
            let p = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = p.firstIndex(of: "=") else { continue }
            var name = String(p[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var val = String(p[p.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            var encoded = false
            if name.hasSuffix("*") { encoded = true; name.removeLast() }
            // RFC 2231 continuation: name*0, name*1 ...
            if let star = name.lastIndex(of: "*"), let index = Int(name[name.index(after: star)...]) {
                let base = String(name[..<star])
                continuations[base, default: []].append((index, val, encoded))
                continue
            }
            params[name] = encoded ? decodeRFC2231(val) : val
        }
        for (name, chunks) in continuations {
            let sorted = chunks.sorted { $0.0 < $1.0 }
            // Only the first chunk carries charset'lang'; later encoded chunks are bare pct-encoded.
            var charset: String.Encoding = .utf8
            var assembled = ""
            for (index, chunk, encoded) in sorted {
                if !encoded { assembled += chunk; continue }
                var body = chunk
                if index == 0, let (cs, rest) = splitCharsetPrefix(chunk) { charset = cs; body = rest }
                assembled += percentDecode(body, encoding: charset)
            }
            params[name] = assembled
        }
        return (value, params)
    }

    private static func splitCharsetPrefix(_ s: String) -> (String.Encoding, String)? {
        let bits = s.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard bits.count == 3 else { return nil }
        return (Charsets.encoding(named: String(bits[0])) ?? .utf8, String(bits[2]))
    }

    static func decodeRFC2231(_ s: String) -> String {
        if let (cs, rest) = splitCharsetPrefix(s) { return percentDecode(rest, encoding: cs) }
        return percentDecode(s, encoding: .utf8)
    }

    private static func percentDecode(_ s: String, encoding: String.Encoding) -> String {
        var bytes: [UInt8] = []
        var chars = Array(s.utf8)
        var i = 0
        while i < chars.count {
            if chars[i] == 0x25, i + 2 < chars.count, let v = UInt8(String(bytes: chars[(i+1)...(i+2)], encoding: .ascii) ?? "", radix: 16) {
                bytes.append(v); i += 3
            } else { bytes.append(chars[i]); i += 1 }
        }
        chars = []
        return String(bytes: bytes, encoding: encoding) ?? String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - RFC 2047 encoded words

nonisolated enum RFC2047 {
    private static let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)

    /// Decode every `=?charset?B|Q?text?=` in `s`. Whitespace BETWEEN two encoded words is
    /// dropped (RFC 2047 §6.2); whitespace next to ordinary text is kept.
    static func decode(_ s: String) -> String {
        guard let regex, s.contains("=?") else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var result = ""
        var cursor = 0
        var previousEnd: Int?
        for m in matches {
            let between = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let onlyWhitespace = !between.isEmpty && between.trimmingCharacters(in: .whitespaces).isEmpty
            if !(previousEnd != nil && onlyWhitespace) { result += between }
            let charset = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let payload = ns.substring(with: m.range(at: 3))
            let bytes: Data
            if enc == "B" {
                bytes = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
            } else {
                // Q: like quoted-printable but "_" is a space.
                bytes = TransferEncoding.decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            }
            let encoding = Charsets.encoding(named: charset) ?? .utf8
            result += String(data: bytes, encoding: encoding) ?? String(data: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)
            cursor = NSMaxRange(m.range)
            previousEnd = cursor
        }
        result += ns.substring(from: cursor)
        return result
    }
}

// MARK: - Transfer encodings

nonisolated enum TransferEncoding {
    static func decodeBase64(_ data: Data) -> Data {
        // Strip everything that isn't base64 alphabet (line breaks, stray whitespace).
        let cleaned = data.filter { b in
            (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) || b == 0x2B || b == 0x2F || b == 0x3D
        }
        var s = String(decoding: cleaned, as: UTF8.self)
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s) ?? Data()
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D { // '='
                // Soft line break: "=\r\n" or "=\n" (allow trailing spaces before the break).
                var j = i + 1
                while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
                if j < bytes.count, bytes[j] == 0x0D { j += 1 }
                if j < bytes.count, bytes[j] == 0x0A { i = j + 1; continue }
                if j >= bytes.count { i = j; continue }
                if i + 2 < bytes.count, let hi = hex(bytes[i + 1]), let lo = hex(bytes[i + 2]) {
                    out.append(hi << 4 | lo); i += 3; continue
                }
                out.append(b); i += 1
            } else {
                out.append(b); i += 1
            }
        }
        return Data(out)
    }
}

// MARK: - Charsets

nonisolated enum Charsets {
    static func encoding(named name: String) -> String.Encoding? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        switch n {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii": return .ascii
        case "iso-8859-1", "latin1", "latin-1", "l1": return .isoLatin1
        case "iso-8859-2": return .isoLatin2
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1250", "cp1250": return .windowsCP1250
        case "utf-16", "utf16": return .utf16
        case "utf-16le": return .utf16LittleEndian
        case "utf-16be": return .utf16BigEndian
        case "macintosh", "mac-roman", "macroman": return .macOSRoman
        case "shift_jis", "shift-jis", "sjis": return .shiftJIS
        case "iso-2022-jp": return .iso2022JP
        case "euc-jp": return .japaneseEUC
        default:
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            guard cf != kCFStringEncodingInvalidId else { return nil }
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        }
    }

    static func fileExtension(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "application/pdf": return "pdf"
        case "text/plain": return "txt"
        case "text/html": return "html"
        case "text/calendar": return "ics"
        default: return nil
        }
    }
}

// MARK: - Rendering to markdown

nonisolated extension EmailMessage {
    /// The markdown zMD displays for an email: header block, attachment list, then the body as
    /// a single sanitized HTML block. The body is LAST on purpose — email HTML is routinely
    /// unbalanced, and an unbalanced HTML block runs to the end of the document in zMD's parser,
    /// so nothing may follow it.
    ///
    /// Remote content (http(s) images, CSS url()s) is blocked by default: AppKit's HTML importer
    /// fetches whatever the markup references, and HTML email is full of tracking pixels.
    func markdownRepresentation() -> String {
        var out = ""

        // Frontmatter block: zMD renders it as a key/value metadata table — the right look
        // for From / To / Cc / Date.
        out += "---\n"
        out += "Subject: \(Self.frontmatterValue(subject ?? "(No subject)"))\n"
        if !from.isEmpty { out += "From: \(Self.frontmatterValue(from.map(\.display).joined(separator: ", ")))\n" }
        if !to.isEmpty { out += "To: \(Self.frontmatterValue(to.map(\.display).joined(separator: ", ")))\n" }
        if !cc.isEmpty { out += "Cc: \(Self.frontmatterValue(cc.map(\.display).joined(separator: ", ")))\n" }
        if !replyTo.isEmpty { out += "Reply-To: \(Self.frontmatterValue(replyTo.map(\.display).joined(separator: ", ")))\n" }
        if let date { out += "Date: \(Self.frontmatterValue(Self.displayDate(date)))\n" }
        else if let rawDate { out += "Date: \(Self.frontmatterValue(rawDate))\n" }
        out += "---\n\n"

        out += "# \(Self.escapeMarkdownInline(subject ?? "(No subject)"))\n\n"

        let files = fileAttachments
        if !files.isEmpty {
            out += "**Attachments**\n\n"
            for a in files {
                out += "- \(Self.escapeMarkdownInline(a.filename)) (\(Self.formatBytes(a.data.count)))\n"
            }
            out += "\n"
        }

        let (bodyHTML, blockedRemote) = renderedBodyHTML()
        if blockedRemote > 0 {
            out += "*\(blockedRemote) remote image\(blockedRemote == 1 ? "" : "s") not loaded.*\n\n"
        }
        out += "---\n\n"
        out += bodyHTML
        out += "\n"
        return out
    }

    /// The body as one HTML block, sanitized. Prefers the HTML part; falls back to the plain
    /// text rendered literally (escaped, whitespace preserved) so markdown-looking text in an
    /// email is never reinterpreted.
    func renderedBodyHTML() -> (html: String, blockedRemoteImages: Int) {
        if let htmlBody, !htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let inline = Dictionary(uniqueKeysWithValues: attachments.compactMap { a -> (String, Attachment)? in
                guard let cid = a.contentId else { return nil }
                return (cid.lowercased(), a)
            })
            let result = EmailHTMLSanitizer.sanitize(htmlBody, inlineParts: inline)
            return ("<div class=\"email-body\">\n\(result.html)\n</div>", result.blockedRemoteImages)
        }
        let text = textBody ?? ""
        let escaped = EmailHTMLSanitizer.escape(text)
        let linked = EmailHTMLSanitizer.autolink(escaped)
        return ("<div class=\"email-body\"><div style=\"white-space: pre-wrap; word-wrap: break-word;\">\(linked)</div></div>", 0)
    }

    // MARK: helpers

    private static func frontmatterValue(_ s: String) -> String {
        // Frontmatter lines must stay on one line; the renderer splits on the first colon only.
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    static func escapeMarkdownInline(_ s: String) -> String {
        var out = ""
        for ch in s.replacingOccurrences(of: "\n", with: " ") {
            if "\\`*_[]<>#|~$".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func displayDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func formatBytes(_ count: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(count))
    }
}

// MARK: - HTML sanitizer

/// Makes email HTML safe and private to render through zMD's HTML-block path.
///  - Strips script/iframe/object/embed/link/meta/base elements and on* handlers. (The AppKit
///    importer doesn't run scripts, but the exported HTML is opened by other programs.)
///  - Blocks REMOTE images: `<img src="http…">` becomes a placeholder; `background=` and CSS
///    `url(http…)` are removed. This is the tracking-pixel defense and is not optional.
///  - Resolves `cid:` images to `data:` URIs from the message's inline parts.
///  - Keeps only the <body> contents (plus any <style> blocks from <head>), since the result is
///    embedded inside zMD's own document.
nonisolated enum EmailHTMLSanitizer {
    struct Result: Sendable {
        let html: String
        let blockedRemoteImages: Int
    }

    private static let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

    static func sanitize(_ input: String, inlineParts: [String: EmailMessage.Attachment]) -> Result {
        var html = input
        var blocked = 0

        // Keep <style> blocks from <head>, then reduce to the body contents.
        let styles = matches(#"<style\b[^>]*>.*?</style\s*>"#, in: html)
        if let body = firstGroup(#"<body\b[^>]*>(.*?)</body\s*>"#, in: html) {
            html = body
        } else {
            html = removing(#"<head\b[^>]*>.*?</head\s*>"#, from: html)
            html = removing(#"</?(?:html|body)\b[^>]*>"#, from: html)
        }

        // Dangerous / pointless elements.
        for pattern in [#"<script\b[^>]*>.*?</script\s*>"#, #"<iframe\b[^>]*>.*?</iframe\s*>"#,
                        #"<object\b[^>]*>.*?</object\s*>"#, #"<embed\b[^>]*/?>"#, #"<link\b[^>]*/?>"#,
                        #"<meta\b[^>]*/?>"#, #"<base\b[^>]*/?>"#, #"<title\b[^>]*>.*?</title\s*>"#] {
            html = removing(pattern, from: html)
        }
        // Event handlers and javascript: URLs.
        html = removing(#"\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, from: html)
        html = replacing(#"(href\s*=\s*["']?)\s*javascript:[^"'\s>]*"#, in: html, with: "$1#")

        // Images: resolve cid:, block remote, keep data:.
        if let imgRegex = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: options) {
            let ns = html as NSString
            var rebuilt = ""
            var cursor = 0
            for m in imgRegex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                rebuilt += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                let tag = ns.substring(with: m.range)
                let src = firstGroup(#"\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, in: tag, groups: [1, 2, 3])?.trimmingCharacters(in: .whitespaces) ?? ""
                let lower = src.lowercased()
                if lower.hasPrefix("cid:") {
                    let cid = String(src.dropFirst(4)).lowercased()
                    if let part = inlineParts[cid] {
                        let uri = "data:\(part.mimeType);base64,\(part.data.base64EncodedString())"
                        rebuilt += replacing(#"\bsrc\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, in: tag, with: "src=\"\(uri)\"")
                    } else {
                        rebuilt += placeholder("missing inline image")
                    }
                } else if lower.hasPrefix("data:") {
                    rebuilt += tag
                } else if lower.isEmpty {
                    rebuilt += ""
                } else {
                    blocked += 1
                    rebuilt += placeholder("remote image not loaded")
                }
                cursor = NSMaxRange(m.range)
            }
            rebuilt += ns.substring(from: cursor)
            html = rebuilt
        }
        // Other remote fetches: background attributes and CSS url().
        html = removing(#"\s+background\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, from: html)
        html = replacing(#"url\(\s*["']?\s*(?:https?:|//)[^)]*\)"#, in: html, with: "none")

        let cleanedStyles = styles.map { replacing(#"url\(\s*["']?\s*(?:https?:|//)[^)]*\)"#, in: $0, with: "none") }
        let combined = (cleanedStyles.joined(separator: "\n") + "\n" + html).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(html: combined, blockedRemoteImages: blocked)
    }

    private static func placeholder(_ text: String) -> String {
        "<span style=\"display:inline-block; padding:2px 6px; border:1px solid #999; border-radius:3px; color:#888; font-size:0.85em;\">[\(text)]</span>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Turn bare http(s) URLs in already-escaped text into links.
    static func autolink(_ escaped: String) -> String {
        replacing(#"(https?://[^\s<>"']+[^\s<>"'.,;:!?)])"#, in: escaped, with: "<a href=\"$1\">$1</a>")
    }

    // MARK: regex helpers

    private static func removing(_ pattern: String, from s: String) -> String { replacing(pattern, in: s, with: "") }

    private static func replacing(_ pattern: String, in s: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func firstGroup(_ pattern: String, in s: String, groups: [Int] = [1]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let m = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        for g in groups where g < m.numberOfRanges {
            if let r = Range(m.range(at: g), in: s) { return String(s[r]) }
        }
        return nil
    }
}
