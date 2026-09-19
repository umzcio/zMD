import Foundation

/// Pure, Foundation-only helpers for the Quick Look preview extension: bounded file reading,
/// text decoding, and post-processing of `MarkdownParser.toHTML` output so it renders inside the
/// Quick Look sandbox (no network, no script execution needed).
///
/// Deliberately free of any QuickLookUI / MarkdownParser dependency so the same file can be
/// compiled into the zMDTests target and unit-tested without hosting an app extension.
nonisolated enum QuickLookHTML {
    /// Upper bound on how much of a file is read for a preview. Quick Look runs while the user is
    /// arrowing through Finder; a multi-hundred-MB log file renamed `.md` must not stall it.
    static let maxInputBytes = 2 * 1024 * 1024

    /// Markdown appended to the source when the file was cut at `maxInputBytes`.
    static let truncationNotice = "\n\n---\n\n*Preview truncated — open the file in zMD to see the whole document.*\n"

    // MARK: - Reading

    /// Reads at most `maxBytes` from `url`. `truncated` is true when the file had more.
    static func readPrefix(of url: URL, maxBytes: Int = maxInputBytes) throws -> (data: Data, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Ask for one extra byte: that is how we learn the file continues past the cap without a
        // separate (and, inside the sandbox, not always permitted) attributes lookup.
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        if data.count > maxBytes {
            return (data.prefix(maxBytes), true)
        }
        return (data, false)
    }

    // MARK: - Decoding

    /// UTF-8 first, then BOM-marked UTF-16, then Windows-1252 as the catch-all.
    ///
    /// UTF-16 is only accepted with a BOM: `String(data:encoding: .utf16)` "succeeds" on nearly
    /// any even-length byte string, so trying it blind would turn every Latin-1 file into CJK
    /// garbage before CP1252 ever got a chance. This mirrors the app's own
    /// `DocumentManager.decodeFileData` ordering.
    ///
    /// - Parameter truncated: the data was cut at an arbitrary byte offset, so a trailing
    ///   partial UTF-8 sequence is expected and must not push the file into the CP1252 fallback.
    static func decode(_ data: Data, truncated: Bool = false) -> String {
        let bytes = [UInt8](data.prefix(2))
        let hasUTF16BOM = bytes == [0xFF, 0xFE] || bytes == [0xFE, 0xFF]

        if !hasUTF16BOM {
            // Dropping up to 3 bytes covers the longest incomplete UTF-8 tail (a 4-byte scalar
            // missing its last byte). Only done for truncated input — a complete file with a bad
            // tail is genuinely not UTF-8.
            let maxTrim = truncated ? 3 : 0
            for trim in 0...maxTrim where data.count >= trim {
                if let text = String(data: data.dropLast(trim), encoding: .utf8) {
                    return stripBOM(text)
                }
            }
        } else {
            // An odd byte count can only come from truncation mid code unit; drop the stray byte.
            let even = data.count % 2 == 0 ? data : data.dropLast()
            if let text = String(data: even, encoding: .utf16) {
                return stripBOM(text)
            }
        }

        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        // CP1252 leaves five byte values undefined; Latin-1 maps every byte.
        if let text = String(data: data, encoding: .isoLatin1) {
            return text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func stripBOM(_ text: String) -> String {
        text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    // MARK: - HTML post-processing

    /// Makes a `MarkdownParser.toHTML` document safe to render with no network and no scripting:
    ///  1. display-math `<script type="math/tex…">` carriers become visible `<pre>` source text
    ///     (stripping them with the other scripts would silently delete the user's LaTeX);
    ///  2. every remaining `<script>` element and every `<link>` tag is removed, so the preview
    ///     never waits on the Mermaid / KaTeX CDNs the sandbox cannot reach;
    ///  3. a CSP plus preview-specific styles (dark mode, padding) are injected into `<head>`.
    ///
    /// Regex stripping is sound here only because the parser HTML-escapes all user content
    /// (inline text, code, raw HTML blocks): the only literal `<script`/`<link` in its output are
    /// the ones it emitted itself.
    static func makeOfflineSafe(_ html: String) -> String {
        var result = replaceDisplayMathScripts(in: html)
        result = removeMatches(of: #"<script\b[^>]*>.*?</script\s*>[ \t]*\n?"#, in: result)
        result = removeMatches(of: #"<link\b[^>]*>[ \t]*\n?"#, in: result)

        if let headEnd = result.range(of: "</head>", options: .caseInsensitive) {
            result.insert(contentsOf: headInjection + "\n", at: headEnd.lowerBound)
        } else {
            // toHTML always emits a <head>; if that ever changes, still ship the styles.
            result = headInjection + "\n" + result
        }
        return result
    }

    private static let regexOptions: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

    private static func removeMatches(of pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func replaceDisplayMathScripts(in text: String) -> String {
        let pattern = #"<script\s+type="math/tex[^"]*"\s*>(.*?)</script\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: regexOptions) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Back to front so earlier match ranges stay valid while the string is edited.
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let body = Range(match.range(at: 1), in: result) else { continue }
            // Undo the parser's `</` → `<\/` script-breakout guard, then escape for element context.
            let latex = result[body].replacingOccurrences(of: "<\\/", with: "</")
            result.replaceSubrange(whole, with: "<pre class=\"math-source\"><code>\(escapeHTML(latex))</code></pre>")
        }
        return result
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Injected after the parser's own `<style>` so these rules win the cascade.
    ///
    /// - CSP: belt and braces on top of the stripping above — nothing may execute and nothing may
    ///   be fetched, so a remote `<img>` cannot make the preview wait on a blocked connection.
    /// - The parser's stylesheet is a print/export sheet: hard-coded black-on-(implicit)-white,
    ///   zero body padding, justified text. It has no `prefers-color-scheme` rules, so without
    ///   the dark block below a preview would flash white in Dark Mode.
    static let headInjection = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
        <style>
            :root { color-scheme: light dark; }
            body {
                padding: 24px 32px;
                max-width: 860px;
                margin: 0 auto;
                background-color: #ffffff;
                color: #1d1d1f;
            }
            p { text-align: start; }
            img { max-width: 100%; height: auto; }
            pre { white-space: pre-wrap; word-wrap: break-word; }
            a { color: #0969da; }
            @media (prefers-color-scheme: dark) {
                body { background-color: #1e1e1e; color: #e6e6e6; }
                h1 { border-bottom-color: #555; }
                a { color: #6cb6ff; }
                code { background-color: #2d2d2d; }
                pre { background-color: #262626; border-color: #3a3a3a; }
                pre code { background: none; }
                th, td { border-color: #555; }
                th { background-color: #2f2f2f; }
                blockquote { border-left-color: #666; color: #b0b0b0; }
                hr { border-top-color: #555; }
                .frontmatter { background-color: #262626; border-color: #3a3a3a; }
                /* GitHub's DARK-theme alert accents; the parser's sheet carries the light ones. */
                .markdown-alert-note { border-left-color: #4493f8; } .markdown-alert-note .markdown-alert-title { color: #4493f8; }
                .markdown-alert-tip { border-left-color: #3fb950; } .markdown-alert-tip .markdown-alert-title { color: #3fb950; }
                .markdown-alert-important { border-left-color: #ab7df8; } .markdown-alert-important .markdown-alert-title { color: #ab7df8; }
                .markdown-alert-warning { border-left-color: #d29922; } .markdown-alert-warning .markdown-alert-title { color: #d29922; }
                .markdown-alert-caution { border-left-color: #f85149; } .markdown-alert-caution .markdown-alert-title { color: #f85149; }
            }
        </style>
        """
}
