import Foundation

nonisolated enum InlineMarkdown {
    enum Token: Equatable, Sendable {
        case text(String)
        case lineBreak
        case code(String)
        case math(String)
        case strong(String)
        case emphasis(String)
        case strikethrough(String)
        case highlight(String)
        case image(alt: String, source: String)
        case link(label: String, destination: String)
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        var index = text.startIndex
        // Shared across the whole paragraph so every `[` / `![` does not rescan to the end for
        // a `]` or `)` that is not there (quadratic on crafted input; security finding, 2026-11).
        var closeBracket = ForwardFinder(target: "]")
        var closeParen = ForwardFinder(target: ")")

        func flushText() {
            guard !buffer.isEmpty else { return }
            tokens.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < text.endIndex {
            if text[index] == "\\",
               let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex,
               isEscapable(text[next]) {
                buffer.append(text[next])
                index = text.index(after: next)
                continue
            }

            if let breakRange = lineBreakRange(in: text, at: index) {
                flushText()
                tokens.append(.lineBreak)
                index = breakRange.upperBound
                continue
            }

            if let token = codeToken(in: text, at: index) {
                flushText()
                tokens.append(.code(token.content))
                index = token.end
                continue
            }

            if let token = mathToken(in: text, at: index) {
                flushText()
                tokens.append(.math(token.content))
                index = token.end
                continue
            }

            if let token = imageToken(in: text, at: index, closeBracket: &closeBracket, closeParen: &closeParen) {
                flushText()
                tokens.append(.image(alt: token.alt, source: token.source))
                index = token.end
                continue
            }

            if let token = linkToken(in: text, at: index, closeBracket: &closeBracket, closeParen: &closeParen) {
                flushText()
                tokens.append(.link(label: token.label, destination: token.destination))
                index = token.end
                continue
            }

            if let token = delimitedToken(in: text, at: index, delimiter: "**") {
                flushText()
                tokens.append(.strong(token.content))
                index = token.end
                continue
            }

            if let token = delimitedToken(in: text, at: index, delimiter: "~~") {
                flushText()
                tokens.append(.strikethrough(token.content))
                index = token.end
                continue
            }

            if let token = delimitedToken(in: text, at: index, delimiter: "*") {
                flushText()
                tokens.append(.emphasis(token.content))
                index = token.end
                continue
            }

            if let token = delimitedToken(in: text, at: index, delimiter: "==") {
                flushText()
                tokens.append(.highlight(token.content))
                index = token.end
                continue
            }

            buffer.append(text[index])
            text.formIndex(after: &index)
        }

        flushText()
        return tokens
    }

    private static func isEscapable(_ character: Character) -> Bool {
        #"\\`*_{}[]()#+-.!|~"#.contains(character)
    }

    /// Only a short window is examined: running the regex over `text[index...]` at every
    /// character bridged the whole remaining paragraph each time.
    private static func lineBreakRange(in text: String, at index: String.Index) -> Range<String.Index>? {
        guard text[index] == "<" else { return nil }
        let windowEnd = text.index(index, offsetBy: 64, limitedBy: text.endIndex) ?? text.endIndex
        return text[index..<windowEnd].range(of: #"^<br\s*/?>"#, options: [.regularExpression, .caseInsensitive])
    }

    /// `firstIndex(of:)` with memory: a search from `start` that found the target at `r` (or
    /// nothing) answers every later search starting between `start` and `r` without scanning.
    struct ForwardFinder {
        let target: Character
        private var searchedFrom: String.Index?
        private var result: String.Index?

        init(target: Character) { self.target = target }

        mutating func find(in text: String, from start: String.Index) -> String.Index? {
            if let from = searchedFrom, start >= from {
                guard let found = result else { return nil }   // none from `from` to the end
                if start <= found { return found }
            }
            let found = text[start...].firstIndex(of: target)
            searchedFrom = start
            result = found
            return found
        }
    }

    private static func codeToken(in text: String, at index: String.Index) -> (content: String, end: String.Index)? {
        if let token = delimitedToken(in: text, at: index, delimiter: "``") {
            return token
        }
        return delimitedToken(in: text, at: index, delimiter: "`")
    }

    private static func mathToken(in text: String, at index: String.Index) -> (content: String, end: String.Index)? {
        guard text[index] == "$" else { return nil }
        if index > text.startIndex, text[text.index(before: index)] == "$" { return nil }

        let contentStart = text.index(after: index)
        guard contentStart < text.endIndex else { return nil }
        let firstContent = text[contentStart]
        guard firstContent != "$",
              firstContent != " ",
              !firstContent.isNumber else {
            return nil
        }

        var cursor = contentStart
        var scanned = 0
        while cursor < text.endIndex && scanned < 200 {
            let character = text[cursor]
            if character == "\n" || character == "\r" || character == "\u{2028}" || character == "\u{2029}" { return nil }
            if character == "$" {
                guard cursor > contentStart,
                      text[text.index(before: cursor)] != " " else {
                    return nil
                }
                let after = text.index(after: cursor)
                if after < text.endIndex {
                    let next = text[after]
                    if next == "$" || next.isNumber { return nil }
                }
                return (String(text[contentStart..<cursor]), after)
            }
            text.formIndex(after: &cursor)
            scanned += 1
        }

        return nil
    }

    private static func delimitedToken(in text: String, at index: String.Index, delimiter: String) -> (content: String, end: String.Index)? {
        guard text[index...].hasPrefix(delimiter),
              let contentStart = text.index(index, offsetBy: delimiter.count, limitedBy: text.endIndex),
              contentStart < text.endIndex else {
            return nil
        }

        var searchStart = contentStart
        while searchStart < text.endIndex,
              let closeRange = text[searchStart...].range(of: delimiter) {
            guard contentStart < closeRange.lowerBound else { return nil }

            // A closing delimiter preceded by an unescaped backslash is itself
            // escaped text, not a real close — keep scanning past it.
            let precedingBackslashes = text[contentStart..<closeRange.lowerBound]
                .reversed()
                .prefix(while: { $0 == "\\" })
                .count
            if precedingBackslashes % 2 == 1 {
                searchStart = closeRange.upperBound
                continue
            }

            let content = String(text[contentStart..<closeRange.lowerBound])
            return (content, closeRange.upperBound)
        }

        return nil
    }

    private static func imageToken(in text: String, at index: String.Index, closeBracket: inout ForwardFinder, closeParen: inout ForwardFinder) -> (alt: String, source: String, end: String.Index)? {
        guard text[index...].hasPrefix("!["),
              let altStart = text.index(index, offsetBy: 2, limitedBy: text.endIndex),
              let altEnd = closeBracket.find(in: text, from: altStart) else {
            return nil
        }

        let openParen = text.index(after: altEnd)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }
        let sourceStart = text.index(after: openParen)
        guard sourceStart < text.endIndex,
              let sourceEnd = closeParen.find(in: text, from: sourceStart),
              sourceStart < sourceEnd else {
            return nil
        }

        return (
            String(text[altStart..<altEnd]),
            String(text[sourceStart..<sourceEnd]),
            text.index(after: sourceEnd)
        )
    }

    private static func linkToken(in text: String, at index: String.Index, closeBracket: inout ForwardFinder, closeParen: inout ForwardFinder) -> (label: String, destination: String, end: String.Index)? {
        guard text[index] == "[",
              let labelStart = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
              labelStart < text.endIndex,
              let labelEnd = closeBracket.find(in: text, from: labelStart),
              labelStart < labelEnd else {
            return nil
        }

        let openParen = text.index(after: labelEnd)
        guard openParen < text.endIndex, text[openParen] == "(" else { return nil }
        let destinationStart = text.index(after: openParen)
        guard destinationStart < text.endIndex,
              let destinationEnd = closeParen.find(in: text, from: destinationStart),
              destinationStart < destinationEnd else {
            return nil
        }

        return (
            String(text[labelStart..<labelEnd]),
            String(text[destinationStart..<destinationEnd]),
            text.index(after: destinationEnd)
        )
    }
}
