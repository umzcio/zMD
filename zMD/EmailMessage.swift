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

        private mutating func appendHTML(_ s: String) { html = html.map { $0 + "\n" + s } ?? s }
        private mutating func appendText(_ s: String) { text = text.map { $0 + "\n\n" + s } ?? s }

        mutating func collect(_ entity: MIMEEntity, inRelated: Bool) {
            let type = entity.contentType
            if type.type == "multipart" {
                if type.subtype == "alternative" {
                    // Alternatives are ordered by increasing fidelity: keep the richest one (the
                    // last that yields HTML, else the last with text) but register every
                    // alternative's resources so cid: references still resolve.
                    var bestHTML: String?
                    var bestText: String?
                    for part in entity.parts {
                        var candidate = BodyCollector()
                        candidate.collect(part, inRelated: inRelated)
                        attachments.append(contentsOf: candidate.attachments)
                        if let h = candidate.html { bestHTML = h }
                        if let t = candidate.text { bestText = t }   // kept as the plain-text fallback
                    }
                    if let bestHTML { appendHTML(bestHTML) }
                    if let bestText { appendText(bestText) }
                    return
                }
                let related = inRelated || type.subtype == "related"
                for (index, part) in entity.parts.enumerated() {
                    // In multipart/related only the root (first) part may be body; siblings
                    // are resources even when they are text/html.
                    collect(part, inRelated: related && index > 0)
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
                    appendHTML(string)            // outside an alternative, later HTML parts are more body, not a replacement
                } else if type.subtype == "plain" {
                    appendText(string)
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
                    name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"", options: .literal)
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

    /// Multipart nesting deeper than this is kept as an opaque leaf. Real mail nests a handful of
    /// levels (forwarded, signed, related, alternative); a crafted file nested tens of thousands
    /// deep used to recurse until the stack overflowed (security finding, 2026-11).
    static let maxNestingDepth = 32
    /// Total entities parsed per message; anything past it is dropped.
    static let maxPartCount = 2_000

    static func parse(_ data: Data) -> MIMEEntity {
        var remainingParts = maxPartCount
        return parse(data, depth: 0, remainingParts: &remainingParts)
    }

    private static func parse(_ data: Data, depth: Int, remainingParts: inout Int) -> MIMEEntity {
        remainingParts -= 1
        let (headerData, bodyData) = splitHeaders(data)
        let headers = parseHeaders(headerData)
        var entity = MIMEEntity(rawHeaders: headers, body: bodyData, parts: [])
        let type = entity.contentType
        if type.type == "multipart", let boundary = type.boundary, !boundary.isEmpty, depth < maxNestingDepth {
            var parts: [MIMEEntity] = []
            for partData in splitMultipart(bodyData, boundary: boundary) {
                guard remainingParts > 0 else { break }
                parts.append(parse(partData, depth: depth + 1, remainingParts: &remainingParts))
            }
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

    /// Unfold continuation lines and split `Name: value`. Headers are tried as UTF-8 first
    /// (SMTPUTF8 / 8BITMIME mail carries raw UTF-8 subjects) and fall back to Latin-1, which
    /// never fails, so no byte is lost before RFC 2047 decoding. Encoded words are pure ASCII
    /// and decode identically either way.
    static func parseHeaders(_ data: Data) -> [(name: String, value: String)] {
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
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
    /// delimiter belongs to the delimiter, not the part (RFC 2046 §5.1.1). Parts are slices of
    /// `body` (shared storage), so nesting does not copy the message once per level.
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delimiter = Array(("--" + boundary).utf8)
        var parts: [Data] = []
        var partStart: Int?
        var i = 0
        func isDelimiter(at index: Int) -> (Bool, closing: Bool, next: Int)? {
            guard index + delimiter.count <= bytes.count, bytes[index..<index + delimiter.count].elementsEqual(delimiter) else { return nil }
            var j = index + delimiter.count
            var closing = false
            if j + 1 < bytes.count, bytes[j] == 0x2D, bytes[j + 1] == 0x2D { closing = true; j += 2 }
            // Skip transport padding, then require the line to END here: `--part` must not match
            // a nested `--part1` (RFC 2046 boundaries are distinct, not prefix-free).
            while j < bytes.count, bytes[j] == 0x20 || bytes[j] == 0x09 { j += 1 }
            guard j == bytes.count || bytes[j] == 0x0D || bytes[j] == 0x0A else { return nil }
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
                    parts.append(body[(body.startIndex + start)..<(body.startIndex + end)])
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
            parts.append(body[(body.startIndex + start)...])
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
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"", options: .literal)
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
                bytes = TransferEncoding.decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ", options: .literal).utf8))
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

/// A markdown line holding exactly this makes the rest of the document one raw HTML block
/// (`MarkdownParser.htmlToEndMarker`). Defined here because this file is compiled into targets
/// that do not include the parser.
nonisolated enum RawHTMLMarker {
    static let toEndOfDocument = "<!-- zmd:html-to-end -->"
}


nonisolated extension EmailMessage {
    /// The markdown zMD displays for an email: header block, attachment list, then the body as
    /// a single sanitized HTML block. The body is LAST on purpose — email HTML is routinely
    /// unbalanced, and an unbalanced HTML block runs to the end of the document in zMD's parser,
    /// so nothing may follow it.
    ///
    /// Remote content (http(s) images, CSS url()s) is blocked by default: AppKit's HTML importer
    /// fetches whatever the markup references, and HTML email is full of tracking pixels.
    func markdownRepresentation(inlineImageBudget: Int = EmailHTMLSanitizer.defaultInlineImageBudget) -> String {
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

        let (bodyHTML, blockedRemote) = renderedBodyHTML(inlineImageBudget: inlineImageBudget)
        if blockedRemote > 0 {
            out += "*\(blockedRemote) remote image\(blockedRemote == 1 ? "" : "s") not loaded.*\n\n"
        }
        out += "---\n\n"
        // The marker makes the parser take everything after it as one HTML block, however the
        // body's tags are (un)balanced — no part of an email body is ever read as markdown.
        out += RawHTMLMarker.toEndOfDocument + "\n"
        out += bodyHTML
        out += "\n"
        return out
    }

    /// The body as one HTML block, sanitized. Prefers the HTML part; falls back to the plain
    /// text rendered literally (escaped, whitespace preserved) so markdown-looking text in an
    /// email is never reinterpreted.
    func renderedBodyHTML(inlineImageBudget: Int = EmailHTMLSanitizer.defaultInlineImageBudget) -> (html: String, blockedRemoteImages: Int) {
        if let htmlBody, !htmlBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let inline = Dictionary(attachments.compactMap { a -> (String, Attachment)? in
                guard let cid = a.contentId else { return nil }
                return (cid.lowercased(), a)
            }, uniquingKeysWith: { first, _ in first })   // duplicate Content-IDs happen in forwarded mail; never trap
            let result = EmailHTMLSanitizer.sanitize(htmlBody, inlineParts: inline, inlineImageBudget: inlineImageBudget)
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
        s.replacingOccurrences(of: "\r", with: " ", options: .literal).replacingOccurrences(of: "\n", with: " ", options: .literal)
    }

    static func escapeMarkdownInline(_ s: String) -> String {
        // Per scalar, not per Character: a `[` with a combining mark after it is one grapheme
        // that `"…".contains(ch)` would not match, yet the HTML and DOCX exports see the bare `[`.
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\r" { out.append(" "); continue }
            if "\\`*_[]<>#|~$".unicodeScalars.contains(scalar) { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
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
///
/// Allowlist, not denylist: the HTML is tokenized (tags, attributes, text, comments) and the
/// output is REBUILT from known-safe elements and attributes only. The old single-pass regex
/// denylist missed `srcset`, `<picture><source>`, `<input type=image>`, `poster`, SVG
/// `<image href>`, tags rebuilt around an inner removal and entity- or escape-encoded CSS URLs,
/// and AppKit's HTML importer fetched whatever survived (security finding, 2026-11). Output
/// built this way cannot reference the network:
///  - Elements outside `allowedElements` are unwrapped (their text kept); `droppedElements`
///    (script, media, forms, SVG, …) disappear with their content. Comments are dropped.
///  - Attributes outside `allowedAttributes` are dropped. `href` survives only on `<a>` and only
///    for http/https/mailto; nothing else may carry a URL.
///  - `<img>` keeps only a `data:` raster image or a `cid:` reference resolved to one; anything
///    else becomes a placeholder (remote ones are counted).
///  - `style` attributes and `<style>` blocks lose every declaration that could fetch (`url(`,
///    `image-set(`, `@import`, …); one that cannot be judged (CSS escapes, unknown entities) is
///    dropped whole.
///  - Every emitted tag is closed, so the result is balanced whatever the input was.
/// Text is copied through unchanged apart from `<` and `>`, so whitespace (`pre-wrap` bodies)
/// and character references survive exactly.
nonisolated enum EmailHTMLSanitizer {
    struct Result: Sendable {
        let html: String
        let blockedRemoteImages: Int
    }

    private static let options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

    static let allowedElements: Set<String> = [
        "a", "abbr", "address", "article", "aside", "b", "big", "blockquote", "br", "caption", "center",
        "cite", "code", "col", "colgroup", "dd", "del", "dfn", "div", "dl", "dt", "em", "figcaption",
        "figure", "font", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "i", "img", "ins",
        "kbd", "label", "li", "main", "mark", "nav", "ol", "p", "pre", "q", "s", "samp", "section",
        "small", "span", "strike", "strong", "sub", "sup", "table", "tbody", "td", "tfoot", "th", "thead",
        "tr", "tt", "u", "ul", "var", "wbr",
    ]
    /// Removed together with everything inside them.
    static let droppedElements: Set<String> = [
        "applet", "audio", "button", "canvas", "datalist", "dialog", "form", "frameset", "map", "math",
        "object", "optgroup", "option", "picture", "select", "svg", "template", "video",
    ]
    /// Void elements that are dropped (no content to skip).
    private static let droppedVoidElements: Set<String> = [
        "area", "base", "basefont", "bgsound", "embed", "frame", "input", "isindex", "keygen", "link",
        "meta", "param", "source", "track",
    ]
    static let allowedAttributes: Set<String> = [
        "align", "alt", "bgcolor", "border", "cellpadding", "cellspacing", "class", "color", "cols",
        "colspan", "dir", "face", "height", "hspace", "lang", "nowrap", "rowspan", "size", "span",
        "start", "summary", "title", "type", "valign", "vspace", "width",
    ]
    private static let voidElements: Set<String> = ["br", "col", "hr", "img", "wbr"]
    private static let rasterImageTypes: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp", "image/bmp", "image/tiff",
    ]

    /// Base64 bytes of inlined `cid:` images one message may render, in total.
    static let defaultInlineImageBudget = 32 * 1024 * 1024
    /// Allowed elements open at once; deeper start tags are unwrapped.
    static let maxOpenElements = 256

    static func sanitize(_ input: String, inlineParts: [String: EmailMessage.Attachment],
                         inlineImageBudget: Int = defaultInlineImageBudget) -> Result {
        var builder = Builder(inlineParts: inlineParts, inlineImageBudget: inlineImageBudget)
        var tokenizer = HTMLTokenizer(input)
        var dropping: (name: String, depth: Int)?

        while let token = tokenizer.next() {
            if var drop = dropping {
                // Inside a dropped element: only track nesting of the same name.
                switch token {
                case .startTag(let name, _, let selfClosing) where name == drop.name && !selfClosing:
                    drop.depth += 1
                    dropping = drop
                case .endTag(let name) where name == drop.name:
                    drop.depth -= 1
                    dropping = drop.depth == 0 ? nil : drop
                default:
                    break
                }
                continue
            }
            switch token {
            case .text(let text):
                builder.appendText(text)
            case .rawText(let name, let content):
                if name == "style", let css = cleanStylesheet(content) { builder.styles.append(css) }
            case .startTag(let rawName, let attributes, let selfClosing):
                let name = rawName == "image" ? "img" : rawName   // HTML parsers alias <image> to <img>
                if droppedElements.contains(name) {
                    if !selfClosing { dropping = (name, 1) }
                } else if allowedElements.contains(name) {
                    builder.open(name, attributes: attributes)
                }
                // Everything else (html, head, body, font-less wrappers, unknown tags, dropped
                // void elements) is unwrapped: the tag goes, its content stays.
            case .endTag(let name):
                builder.close(name)
            }
        }
        builder.closeAll()

        let combined = (builder.styles.map { "<style>\($0)</style>" }.joined(separator: "\n") + "\n" + builder.html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(html: combined, blockedRemoteImages: builder.blocked)
    }

    private struct Builder {
        let inlineParts: [String: EmailMessage.Attachment]
        var html = ""
        var styles: [String] = []
        var blocked = 0
        private var openElements: [String] = []
        /// Base64 bytes of `cid:` images still allowed in the output.
        private var inlineImageBudget: Int
        private var refusedInlineImages = Set<String>()

        init(inlineParts: [String: EmailMessage.Attachment], inlineImageBudget: Int) {
            self.inlineParts = inlineParts
            self.inlineImageBudget = inlineImageBudget
        }

        /// Text keeps its character references (`&nbsp;`, `&amp;`) as written: in text content a
        /// reference can only ever produce characters, never markup. Only `<` and `>` need care.
        mutating func appendText(_ text: String) {
            html += text.replacingOccurrences(of: "<", with: "&lt;", options: .literal)
                .replacingOccurrences(of: ">", with: "&gt;", options: .literal)
        }

        mutating func open(_ name: String, attributes: [(name: String, value: String)]) {
            if name == "img" {
                appendImage(attributes)
                return
            }
            let isVoid = EmailHTMLSanitizer.voidElements.contains(name)
            // Past the depth cap a start tag is unwrapped, so `close` never searches a stack
            // longer than the cap — N unclosed tags then M stray end tags used to cost N × M.
            if !isVoid, openElements.count >= EmailHTMLSanitizer.maxOpenElements { return }
            html += "<\(name)"
            for (attributeName, value) in attributes {
                if attributeName == "href" {
                    if name == "a", let safe = EmailHTMLSanitizer.safeLinkTarget(value) {
                        html += " href=\"\(EmailHTMLSanitizer.escape(safe))\""
                    }
                } else if attributeName == "style" {
                    if let css = EmailHTMLSanitizer.cleanDeclarations(value), !css.isEmpty {
                        html += " style=\"\(EmailHTMLSanitizer.escape(css))\""
                    }
                } else if EmailHTMLSanitizer.allowedAttributes.contains(attributeName) {
                    html += " \(attributeName)=\"\(EmailHTMLSanitizer.escape(value))\""
                }
            }
            html += ">"
            if !isVoid { openElements.append(name) }
        }

        /// Closes `name` and anything opened inside it; an end tag with no open element is ignored.
        mutating func close(_ name: String) {
            guard EmailHTMLSanitizer.allowedElements.contains(name),
                  let index = openElements.lastIndex(of: name) else { return }
            while openElements.count > index {
                html += "</\(openElements.removeLast())>"
            }
        }

        mutating func closeAll() {
            while let name = openElements.popLast() { html += "</\(name)>" }
        }

        private mutating func appendImage(_ attributes: [(name: String, value: String)]) {
            func attribute(_ key: String) -> String? { attributes.first { $0.name == key }?.value }
            let src = (attribute("src") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = src.lowercased()
            let dataURI: String?
            if lower.hasPrefix("cid:") {
                let cid = String(src.dropFirst(4)).lowercased()
                if let part = inlineParts[cid], let mime = EmailHTMLSanitizer.rasterImageType(part.mimeType) {
                    // Each reference inlines the whole part again; the budget bounds the output
                    // whatever the reference count (one 1 MB part referenced 20,000 times was
                    // ~27 GB of HTML; security finding, 2026-11).
                    let encodedLength = (part.data.count + 2) / 3 * 4
                    guard encodedLength <= inlineImageBudget else {
                        // One placeholder per image, not per reference.
                        if refusedInlineImages.insert(cid).inserted {
                            html += EmailHTMLSanitizer.placeholder("inline image not shown")
                        }
                        return
                    }
                    inlineImageBudget -= encodedLength
                    dataURI = "data:\(mime);base64,\(part.data.base64EncodedString())"
                } else {
                    html += EmailHTMLSanitizer.placeholder("missing inline image")
                    return
                }
            } else if lower.hasPrefix("data:") {
                dataURI = EmailHTMLSanitizer.isRasterDataURI(lower) ? src : nil
            } else {
                dataURI = nil
            }
            guard let dataURI else {
                if lower.isEmpty { return }
                let isRemote = lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("//")
                if isRemote { blocked += 1 }
                html += EmailHTMLSanitizer.placeholder(isRemote ? "remote image not loaded" : "image not loaded")
                return
            }
            html += "<img src=\"\(EmailHTMLSanitizer.escape(dataURI))\""
            for key in ["alt", "width", "height", "title", "align", "border"] {
                if let value = attribute(key) { html += " \(key)=\"\(EmailHTMLSanitizer.escape(value))\"" }
            }
            if let css = attribute("style").flatMap(EmailHTMLSanitizer.cleanDeclarations), !css.isEmpty {
                html += " style=\"\(EmailHTMLSanitizer.escape(css))\""
            }
            html += ">"
        }
    }

    /// `type/subtype` if it is a raster image type that may be inlined, else nil. The MIME type
    /// comes from the attachment's headers — attacker text — and is only ever echoed from the
    /// fixed allowlist.
    static func rasterImageType(_ mimeType: String) -> String? {
        let normalized = mimeType.trimmingCharacters(in: .whitespaces).lowercased()
        return rasterImageTypes.contains(normalized) ? normalized : nil
    }

    private static func isRasterDataURI(_ lower: String) -> Bool {
        let afterScheme = lower.dropFirst("data:".count)
        guard let end = afterScheme.firstIndex(where: { $0 == ";" || $0 == "," }) else { return false }
        return rasterImageTypes.contains(String(afterScheme[..<end]))
    }

    /// http, https and mailto links only, judged per Unicode scalar like a browser's URL parser.
    /// `href` arrives entity-decoded; a reference the decoder does not know stays literal and so
    /// can only make the scheme fail the allowlist.
    static func safeLinkTarget(_ href: String) -> String? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = trimmed.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        guard let colon = scalars.firstIndex(of: ":") else { return nil }
        let scheme = String(String.UnicodeScalarView(scalars[..<colon])).lowercased()
        return ["http", "https", "mailto"].contains(scheme) ? trimmed : nil
    }

    // MARK: CSS

    /// Tokens that let CSS fetch something, matched in lowercased text with whitespace removed.
    private static let fetchingCSS = ["url(", "image-set(", "image(", "cross-fade(", "element(", "@import",
                                      "expression(", "behavior:", "-moz-binding", "src:"]
    /// CSS functions whose argument is a resource to fetch; replaced by `none` in stylesheets.
    private static let fetchingFunctions: Set<String> = [
        "url", "image-set", "-webkit-image-set", "image", "cross-fade", "-webkit-cross-fade", "element", "-moz-element",
    ]

    /// A `style` attribute (already entity-decoded) with every fetching declaration removed; nil
    /// when it cannot be judged and must go entirely.
    ///
    /// Every decision is made on the exact text that is emitted, by a scanner that knows CSS
    /// strings and comments. The old version stripped `/* … */` with a regex that did not know
    /// strings, so `"/*"` and `"*/"` in quoted values hid a `url(` between them from the check
    /// while the browser still fetched it (security finding, 2026-11).
    static func cleanDeclarations(_ css: String) -> String? {
        guard let stripped = CSSText.strippingComments(css) else { return nil }
        let kept = CSSText.splitTopLevel(stripped, on: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !canFetch($0, ignoring: []) }
        let out = kept.joined(separator: "; ")
        return canFetch(out, ignoring: []) ? nil : out
    }

    /// A `<style>` block with fetching rules neutralized (`url(…)` and friends become `none`,
    /// `@import` rules are removed); nil when it must go entirely. The emitted text is checked
    /// again after rewriting, and may never contain `<` — rewriting used to be able to join
    /// `</sty` and `le>` into an end tag the check had not seen (security finding, 2026-11).
    static func cleanStylesheet(_ css: String) -> String? {
        guard let stripped = CSSText.strippingComments(css),
              let neutralized = CSSText.neutralizingFetches(stripped, functions: fetchingFunctions) else { return nil }
        // `src:` and `behavior:` are harmless once every url() is `none` (`@font-face { src: none }`).
        return canFetch(neutralized, ignoring: ["src:", "behavior:"]) ? nil : neutralized
    }

    /// True when `css` could fetch, contains markup or escape characters, or holds a character
    /// reference the decoder left alone. Per scalar, so no neighbouring mark can hide a `<`.
    private static func canFetch(_ css: String, ignoring: Set<String>) -> Bool {
        if css.unicodeScalars.contains(where: { $0 == "<" || $0 == ">" || $0 == "\\" }) { return true }
        if css.range(of: #"&[#a-zA-Z]"#, options: .regularExpression) != nil { return true }
        var squashed = String.UnicodeScalarView()
        for scalar in css.lowercased().unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            squashed.append(scalar)
        }
        let text = String(squashed)
        return fetchingCSS.contains { !ignoring.contains($0) && text.range(of: $0, options: .literal) != nil }
    }

    private static func placeholder(_ text: String) -> String {
        "<span style=\"display:inline-block; padding:2px 6px; border:1px solid #999; border-radius:3px; color:#888; font-size:0.85em;\">[\(text)]</span>"
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;", options: .literal)
         .replacingOccurrences(of: "<", with: "&lt;", options: .literal)
         .replacingOccurrences(of: ">", with: "&gt;", options: .literal)
         .replacingOccurrences(of: "\"", with: "&quot;", options: .literal)
    }

    /// Turn bare http(s) URLs in already-escaped text into links.
    static func autolink(_ escaped: String) -> String {
        replacing(#"(https?://[^\s<>"']+[^\s<>"'.,;:!?)])"#, in: escaped, with: "<a href=\"$1\">$1</a>")
    }

    // MARK: regex helpers

    private static func replacing(_ pattern: String, in s: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

// MARK: - HTML tokenizer

/// A small, forgiving HTML tokenizer for `EmailHTMLSanitizer`: start and end tags with
/// entity-decoded attributes, text, and the content of raw-text elements (`<style>`,
/// `<script>`, …). Comments, doctypes and processing instructions are skipped. It never fails:
/// a `<` that does not start markup is text, and an unterminated tag at end of input is
/// dropped, as browsers do.
nonisolated struct HTMLTokenizer {
    enum Token {
        case text(String)
        case startTag(name: String, attributes: [(name: String, value: String)], selfClosing: Bool)
        case endTag(String)
        case rawText(name: String, content: String)
    }

    static let rawTextElements: Set<String> = [
        "iframe", "noembed", "noframes", "noscript", "plaintext", "script", "style", "textarea", "title", "xmp",
    ]

    private let s: [Unicode.Scalar]
    private var i = 0

    init(_ input: String) { s = Array(input.unicodeScalars) }

    mutating func next() -> Token? {
        while i < s.count {
            if s[i] == "<" {
                switch markup() {
                case .token(let token): return token
                case .skipped: continue
                case .notMarkup: break
                }
            }
            // Text up to the next `<` (a `<` that was not markup is part of it).
            let start = i
            i += 1
            while i < s.count, s[i] != "<" { i += 1 }
            return .text(Self.string(s[start..<i]))
        }
        return nil
    }

    private enum Markup { case token(Token), skipped, notMarkup }

    private mutating func markup() -> Markup {
        let next = i + 1 < s.count ? s[i + 1] : nil
        if next == "!" {
            if hasPrefix("<!--", at: i) {
                i = indexAfter("-->", from: i + 4) ?? s.count
            } else {
                i = indexAfter(">", from: i + 2) ?? s.count   // doctype, CDATA, conditional comments
            }
            return .skipped
        }
        if next == "?" {
            i = indexAfter(">", from: i + 2) ?? s.count
            return .skipped
        }
        if next == "/" {
            guard i + 2 < s.count, Self.isLetter(s[i + 2]) else {
                i = indexAfter(">", from: i + 2) ?? s.count   // `</>` and `</ …>` are bogus comments
                return .skipped
            }
            i += 2
            let name = readName()
            // End tags may carry (ignored) attributes; one cut off by end of input is dropped.
            guard readAttributes() != nil else { return .skipped }
            return .token(.endTag(name))
        }
        guard let next, Self.isLetter(next) else { return .notMarkup }
        i += 1
        let name = readName()
        guard let (attributes, selfClosing) = readAttributes() else { return .skipped }   // EOF inside the tag
        if Self.rawTextElements.contains(name) {
            let contentStart = i
            let contentEnd = findEndTag(name, from: i) ?? s.count
            let content = Self.string(s[contentStart..<contentEnd])
            i = contentEnd < s.count ? (indexAfter(">", from: contentEnd) ?? s.count) : s.count
            return .token(.rawText(name: name, content: content))
        }
        return .token(.startTag(name: name, attributes: attributes, selfClosing: selfClosing))
    }

    private mutating func readName() -> String {
        let start = i
        while i < s.count, !Self.isSpace(s[i]), s[i] != "/", s[i] != ">" { i += 1 }
        return Self.string(s[start..<i]).lowercased()
    }

    /// Attributes up to and including the closing `>`; nil when input ends first.
    private mutating func readAttributes() -> (attributes: [(name: String, value: String)], selfClosing: Bool)? {
        var attributes: [(name: String, value: String)] = []
        var selfClosing = false
        while i < s.count {
            let c = s[i]
            if c == ">" { i += 1; return (attributes, selfClosing) }
            if Self.isSpace(c) { i += 1; continue }
            if c == "/" { selfClosing = true; i += 1; continue }
            selfClosing = false
            let nameStart = i
            i += 1   // the first character may be `=` (an odd but legal attribute name)
            while i < s.count, !Self.isSpace(s[i]), s[i] != "/", s[i] != ">", s[i] != "=" { i += 1 }
            let name = Self.string(s[nameStart..<i]).lowercased()
            while i < s.count, Self.isSpace(s[i]) { i += 1 }
            var value = ""
            if i < s.count, s[i] == "=" {
                i += 1
                while i < s.count, Self.isSpace(s[i]) { i += 1 }
                if i < s.count, s[i] == "\"" || s[i] == "'" {
                    let quote = s[i]
                    let valueStart = i + 1
                    i = valueStart
                    while i < s.count, s[i] != quote { i += 1 }
                    value = Self.string(s[valueStart..<min(i, s.count)])
                    if i < s.count { i += 1 }
                } else {
                    let valueStart = i
                    while i < s.count, !Self.isSpace(s[i]), s[i] != ">" { i += 1 }
                    value = Self.string(s[valueStart..<i])
                }
            }
            attributes.append((name, Self.decodeCharacterReferences(value)))
        }
        return nil
    }

    private func hasPrefix(_ prefix: String, at index: Int) -> Bool {
        var j = index
        for p in prefix.unicodeScalars {
            guard j < s.count, s[j] == p else { return false }
            j += 1
        }
        return true
    }

    private func indexAfter(_ terminator: String, from start: Int) -> Int? {
        let t = Array(terminator.unicodeScalars)
        var j = max(start, 0)
        while j + t.count <= s.count {
            if s[j] == t[0], Array(s[j..<(j + t.count)]) == t { return j + t.count }
            j += 1
        }
        return nil
    }

    /// Index of `</name` (any case) followed by whitespace, `/` or `>`.
    private func findEndTag(_ name: String, from start: Int) -> Int? {
        let n = Array(name.unicodeScalars)
        var j = start
        while j + 2 + n.count <= s.count {
            if s[j] == "<", s[j + 1] == "/" {
                var matches = true
                for k in 0..<n.count where Self.lower(s[j + 2 + k]) != n[k] { matches = false; break }
                if matches {
                    let after = j + 2 + n.count
                    if after == s.count || Self.isSpace(s[after]) || s[after] == "/" || s[after] == ">" { return j }
                }
            }
            j += 1
        }
        return nil
    }

    private static func isLetter(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private static func isSpace(_ c: Unicode.Scalar) -> Bool {
        c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{0C}"
    }

    private static func lower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32)! : c
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    // MARK: Character references

    private static let namedReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "colon": ":", "semi": ";", "comma": ",", "period": ".", "sol": "/", "bsol": "\\",
        "lpar": "(", "rpar": ")", "lsqb": "[", "rsqb": "]", "lcub": "{", "rcub": "}",
        "equals": "=", "num": "#", "excl": "!", "quest": "?", "commat": "@", "percnt": "%",
        "Tab": "\t", "NewLine": "\n",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "copy": "\u{A9}",
        "reg": "\u{AE}", "trade": "\u{2122}", "middot": "\u{B7}", "bull": "\u{2022}",
    ]
    /// Legacy references browsers also accept without the trailing `;`.
    private static let legacyReferences: Set<String> = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    /// Decodes numeric references (with or without `;`) and the named ones above. Anything else
    /// stays literal; callers that judge URLs or CSS treat a leftover `&name` as unjudgeable.
    static func decodeCharacterReferences(_ value: String) -> String {
        guard value.unicodeScalars.contains("&") else { return value }
        let v = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var j = 0
        while j < v.count {
            guard v[j] == "&", j + 1 < v.count else { out.append(v[j]); j += 1; continue }
            if v[j + 1] == "#" {
                var k = j + 2
                let hex = k < v.count && (v[k] == "x" || v[k] == "X")
                if hex { k += 1 }
                let digitsStart = k
                while k < v.count, hex ? v[k].properties.isASCIIHexDigit : (v[k] >= "0" && v[k] <= "9") { k += 1 }
                if k > digitsStart {
                    let digits = string(v[digitsStart..<k])
                    let code = UInt32(digits.prefix(8), radix: hex ? 16 : 10) ?? 0xFFFD
                    out.append(Unicode.Scalar(code).flatMap { $0.value == 0 ? nil : $0 } ?? "\u{FFFD}")
                    if k < v.count, v[k] == ";" { k += 1 }
                    j = k
                    continue
                }
            } else {
                var k = j + 1
                while k < v.count, isLetter(v[k]) || (v[k] >= "0" && v[k] <= "9") { k += 1 }
                let name = string(v[(j + 1)..<k])
                if let replacement = namedReferences[name] {
                    if k < v.count, v[k] == ";" {
                        out.append(contentsOf: replacement.unicodeScalars)
                        j = k + 1
                        continue
                    }
                    if legacyReferences.contains(name), !(k < v.count && v[k] == "=") {
                        out.append(contentsOf: replacement.unicodeScalars)
                        j = k
                        continue
                    }
                }
            }
            out.append(v[j])
            j += 1
        }
        return String(out)
    }
}

// MARK: - CSS text

/// Linear, string- and comment-aware passes over CSS for `EmailHTMLSanitizer`. They fail closed:
/// anything a browser could read differently (an unterminated string, a backslash escape, an
/// unclosed fetch function) makes them return nil so the caller drops the CSS.
nonisolated enum CSSText {
    /// `css` with comments removed (an unterminated comment runs to the end, as in browsers) and
    /// strings kept verbatim. Nil for a backslash anywhere or a string that does not close on
    /// its line.
    static func strippingComments(_ css: String) -> String? {
        let s = Array(css.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" { return nil }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                i += 2
                while i < s.count, !(s[i] == "*" && i + 1 < s.count && s[i + 1] == "/") { i += 1 }
                i = min(i + 2, s.count)
                continue
            }
            if c == "\"" || c == "'" {
                guard let end = stringEnd(s, from: i) else { return nil }
                out.append(contentsOf: s[i...end])
                i = end + 1
                continue
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// Splits on `separator` outside strings and parentheses. Input has no comments.
    static func splitTopLevel(_ css: String, on separator: Unicode.Scalar) -> [String] {
        let s = Array(css.unicodeScalars)
        var parts: [String] = []
        var current = String.UnicodeScalarView()
        var depth = 0
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\"" || c == "'", let end = stringEnd(s, from: i) {
                current.append(contentsOf: s[i...end])
                i = end + 1
                continue
            }
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if c == separator, depth == 0 {
                parts.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(c)
            }
            i += 1
        }
        parts.append(String(current))
        return parts
    }

    /// Replaces each fetching function call (`url(…)`, `image-set(…)`, …) with `none` and
    /// removes `@import` rules, outside strings. Input has no comments. Nil when a function or
    /// an `@import` is not closed.
    static func neutralizingFetches(_ css: String, functions: Set<String>) -> String? {
        let s = Array(css.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\"" || c == "'" {
                guard let end = stringEnd(s, from: i) else { return nil }
                out.append(contentsOf: s[i...end])
                i = end + 1
                continue
            }
            if c == "@", lowercasedIdentifier(s, from: i + 1) == "import" {
                guard let end = topLevelIndex(of: ";", in: s, from: i) else { return nil }
                i = end + 1
                continue
            }
            if isIdentifierStart(c), i == 0 || !isIdentifierPart(s[i - 1]) {
                let name = lowercasedIdentifier(s, from: i)
                let afterName = i + name.unicodeScalars.count
                if afterName < s.count, s[afterName] == "(", functions.contains(name) {
                    guard let close = matchingParen(s, from: afterName) else { return nil }
                    out.append(contentsOf: "none".unicodeScalars)
                    i = close + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    // MARK: helpers

    /// Index of the quote closing the string that opens at `start`; nil at a newline or end.
    private static func stringEnd(_ s: [Unicode.Scalar], from start: Int) -> Int? {
        let quote = s[start]
        var j = start + 1
        while j < s.count {
            if s[j] == quote { return j }
            if s[j] == "\n" || s[j] == "\r" || s[j] == "\u{0C}" { return nil }
            j += 1
        }
        return nil
    }

    private static func matchingParen(_ s: [Unicode.Scalar], from open: Int) -> Int? {
        var depth = 0
        var j = open
        while j < s.count {
            let c = s[j]
            if c == "\"" || c == "'" {
                guard let end = stringEnd(s, from: j) else { return nil }
                j = end + 1
                continue
            }
            if c == "(" { depth += 1 }
            if c == ")" {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    private static func topLevelIndex(of target: Unicode.Scalar, in s: [Unicode.Scalar], from start: Int) -> Int? {
        var depth = 0
        var j = start
        while j < s.count {
            let c = s[j]
            if c == "\"" || c == "'" {
                guard let end = stringEnd(s, from: j) else { return nil }
                j = end + 1
                continue
            }
            if c == "(" { depth += 1 } else if c == ")" { depth = max(0, depth - 1) }
            if c == target, depth == 0 { return j }
            j += 1
        }
        return nil
    }

    private static func isIdentifierStart(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "-" || c == "_"
    }

    private static func isIdentifierPart(_ c: Unicode.Scalar) -> Bool {
        isIdentifierStart(c) || (c >= "0" && c <= "9")
    }

    private static func lowercasedIdentifier(_ s: [Unicode.Scalar], from start: Int) -> String {
        var out = String.UnicodeScalarView()
        var j = start
        while j < s.count, isIdentifierPart(s[j]) {
            let c = s[j]
            out.append((c >= "A" && c <= "Z") ? Unicode.Scalar(c.value + 32)! : c)
            j += 1
        }
        return String(out)
    }
}
