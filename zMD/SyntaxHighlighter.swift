import AppKit

/// Simple syntax highlighter for code blocks
class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private init() {}

    // MARK: - Colors (matching common dark/light themes)

    private var keywordColor: NSColor { NSColor.systemPurple }
    private var stringColor: NSColor { NSColor.systemGreen }
    private var commentColor: NSColor { NSColor.systemGray }
    private var numberColor: NSColor { NSColor.systemOrange }
    private var typeColor: NSColor { NSColor.systemTeal }
    private var functionColor: NSColor { NSColor.systemBlue }

    // MARK: - Language Keywords

    private let swiftKeywords = Set([
        "func", "var", "let", "if", "else", "for", "while", "return", "import",
        "class", "struct", "enum", "protocol", "extension", "guard", "switch",
        "case", "default", "break", "continue", "throw", "throws", "try", "catch",
        "async", "await", "actor", "private", "public", "internal", "fileprivate",
        "static", "override", "final", "lazy", "weak", "unowned", "nil", "true",
        "false", "self", "Self", "super", "init", "deinit", "where", "in", "is",
        "as", "typealias", "associatedtype", "some", "any", "@State", "@Binding",
        "@Published", "@ObservedObject", "@StateObject", "@EnvironmentObject"
    ])

    private let pythonKeywords = Set([
        "def", "class", "if", "elif", "else", "for", "while", "return", "import",
        "from", "as", "try", "except", "finally", "raise", "with", "lambda",
        "pass", "break", "continue", "and", "or", "not", "in", "is", "None",
        "True", "False", "self", "global", "nonlocal", "yield", "async", "await"
    ])

    private let jsKeywords = Set([
        "function", "var", "let", "const", "if", "else", "for", "while", "return",
        "import", "export", "from", "class", "extends", "new", "this", "super",
        "try", "catch", "finally", "throw", "async", "await", "yield", "switch",
        "case", "default", "break", "continue", "typeof", "instanceof", "in",
        "of", "true", "false", "null", "undefined", "void", "delete"
    ])

    private let cKeywords = Set([
        "int", "char", "float", "double", "void", "long", "short", "unsigned",
        "signed", "if", "else", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "goto", "struct", "union", "enum", "typedef",
        "const", "static", "extern", "register", "volatile", "sizeof", "NULL",
        "true", "false", "inline", "restrict", "auto"
    ])

    private let bashKeywords = Set([
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
        "esac", "function", "return", "exit", "echo", "read", "local", "export",
        "source", "alias", "unalias", "set", "unset", "shift", "true", "false",
        "cd", "pwd", "ls", "cp", "mv", "rm", "mkdir", "rmdir", "cat", "grep",
        "sed", "awk", "find", "xargs", "sort", "uniq", "wc", "head", "tail"
    ])

    private let sqlKeywords = Set([
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN",
        "IS", "NULL", "ORDER", "BY", "ASC", "DESC", "GROUP", "HAVING", "JOIN",
        "LEFT", "RIGHT", "INNER", "OUTER", "ON", "AS", "INSERT", "INTO", "VALUES",
        "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "INDEX", "VIEW", "DROP",
        "ALTER", "ADD", "COLUMN", "PRIMARY", "KEY", "FOREIGN", "REFERENCES",
        "CONSTRAINT", "UNIQUE", "DEFAULT", "CHECK", "UNION", "ALL", "DISTINCT",
        "TOP", "LIMIT", "OFFSET", "CASE", "WHEN", "THEN", "ELSE", "END", "COUNT",
        "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST", "CONVERT"
    ])

    // MARK: - Public API

    func highlight(code: String, language: String?) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let result = NSMutableAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: NSColor.textColor
        ])

        guard let lang = language?.lowercased() else {
            return result
        }

        // Apply highlighting based on language
        switch lang {
        case "swift":
            highlightGeneric(result, keywords: swiftKeywords)
        case "python", "py":
            highlightPython(result)
        case "javascript", "js", "typescript", "ts":
            highlightGeneric(result, keywords: jsKeywords)
        case "c", "cpp", "c++", "objc", "objective-c":
            highlightGeneric(result, keywords: cKeywords)
        case "bash", "sh", "shell", "zsh":
            highlightBash(result)
        case "sql":
            highlightSQL(result)
        case "json":
            highlightJSON(result)
        case "html", "xml":
            highlightHTML(result)
        default:
            // Generic highlighting for unknown languages
            highlightGeneric(result, keywords: swiftKeywords.union(jsKeywords).union(pythonKeywords))
        }

        return result
    }

    // MARK: - Language-specific Highlighters

    private func highlightGeneric(_ result: NSMutableAttributedString, keywords: Set<String>) {
        let text = result.string

        // Highlight strings (double and single quoted)
        highlightPattern(#""[^"\\]*(?:\\.[^"\\]*)*""#, in: result, color: stringColor)
        highlightPattern(#"'[^'\\]*(?:\\.[^'\\]*)*'"#, in: result, color: stringColor)

        // Highlight comments
        highlightPattern(#"//[^\n]*"#, in: result, color: commentColor)
        highlightPattern(#"/\*[\s\S]*?\*/"#, in: result, color: commentColor)

        // Highlight numbers
        highlightPattern(#"\b\d+\.?\d*\b"#, in: result, color: numberColor)

        // Highlight keywords
        for keyword in keywords {
            highlightWord(keyword, in: result, color: keywordColor)
        }
    }

    private func highlightPython(_ result: NSMutableAttributedString) {
        // Strings (including triple-quoted)
        highlightPattern(#"\"\"\"[\s\S]*?\"\"\""#, in: result, color: stringColor)
        highlightPattern(#"'''[\s\S]*?'''"#, in: result, color: stringColor)
        highlightPattern(#""[^"\\]*(?:\\.[^"\\]*)*""#, in: result, color: stringColor)
        highlightPattern(#"'[^'\\]*(?:\\.[^'\\]*)*'"#, in: result, color: stringColor)

        // Comments
        highlightPattern(#"#[^\n]*"#, in: result, color: commentColor)

        // Numbers
        highlightPattern(#"\b\d+\.?\d*\b"#, in: result, color: numberColor)

        // Keywords
        for keyword in pythonKeywords {
            highlightWord(keyword, in: result, color: keywordColor)
        }
    }

    private func highlightBash(_ result: NSMutableAttributedString) {
        // Strings
        highlightPattern(#""[^"\\]*(?:\\.[^"\\]*)*""#, in: result, color: stringColor)
        highlightPattern(#"'[^']*'"#, in: result, color: stringColor)

        // Comments
        highlightPattern(#"#[^\n]*"#, in: result, color: commentColor)

        // Variables
        highlightPattern(#"\$\w+"#, in: result, color: typeColor)
        highlightPattern(#"\$\{[^}]+\}"#, in: result, color: typeColor)

        // Keywords
        for keyword in bashKeywords {
            highlightWord(keyword, in: result, color: keywordColor)
        }
    }

    private func highlightSQL(_ result: NSMutableAttributedString) {
        // Strings
        highlightPattern(#"'[^']*'"#, in: result, color: stringColor)

        // Comments
        highlightPattern(#"--[^\n]*"#, in: result, color: commentColor)
        highlightPattern(#"/\*[\s\S]*?\*/"#, in: result, color: commentColor)

        // Numbers
        highlightPattern(#"\b\d+\.?\d*\b"#, in: result, color: numberColor)

        // Keywords (case-insensitive for SQL)
        let text = result.string as NSString
        for keyword in sqlKeywords {
            let pattern = "\\b\(keyword)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: text.length))
                for match in matches {
                    result.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
                }
            }
        }
    }

    private func highlightJSON(_ result: NSMutableAttributedString) {
        // Keys (strings before colons)
        highlightPattern(#""[^"]+"\s*:"#, in: result, color: typeColor)

        // String values
        highlightPattern(#":\s*"[^"]*""#, in: result, color: stringColor)

        // Numbers
        highlightPattern(#":\s*-?\d+\.?\d*"#, in: result, color: numberColor)

        // Booleans and null
        highlightPattern(#"\b(true|false|null)\b"#, in: result, color: keywordColor)
    }

    private func highlightHTML(_ result: NSMutableAttributedString) {
        // Tags
        highlightPattern(#"</?[\w-]+"#, in: result, color: typeColor)
        highlightPattern(#"/?\s*>"#, in: result, color: typeColor)

        // Attributes
        highlightPattern(#"\s[\w-]+="#, in: result, color: functionColor)

        // Attribute values
        highlightPattern(#""[^"]*""#, in: result, color: stringColor)

        // Comments
        highlightPattern(#"<!--[\s\S]*?-->"#, in: result, color: commentColor)
    }

    // MARK: - Helpers

    private func highlightPattern(_ pattern: String, in result: NSMutableAttributedString, color: NSColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let text = result.string as NSString
        let matches = regex.matches(in: result.string, range: NSRange(location: 0, length: text.length))

        for match in matches {
            result.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private func highlightWord(_ word: String, in result: NSMutableAttributedString, color: NSColor) {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        highlightPattern(pattern, in: result, color: color)
    }
}
