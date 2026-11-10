import Foundation

/// A small, fast highlighter for reading code on the phone: keywords, strings, comments, numbers, types.
/// Not a parser — it scans line by line and carries block comments and multi-line strings across lines.
public enum SyntaxHighlighter {
    public enum Kind: String, Sendable, Hashable {
        case keyword, string, comment, number, type, key, tag, plain
    }

    /// One coloured run; `start`/`length` are UTF-16 offsets into the line (for NSString / AttributedString).
    public struct Token: Sendable, Hashable {
        public var kind: Kind
        public var start: Int
        public var length: Int
        public init(kind: Kind, start: Int, length: Int) {
            self.kind = kind
            self.start = start
            self.length = length
        }
    }

    public struct Language: Sendable {
        public var name: String
        public var keywords: Set<String> = []
        public var lineComments: [String] = []
        public var blockComment: (open: String, close: String)?
        /// Quote characters for one-line strings.
        public var quotes: [Character] = ["\"", "'"]
        /// Delimiters for strings that may span lines, e.g. `"""`.
        public var multilineStrings: [String] = []
        /// Words starting with an upper-case letter are types (Swift, Java, Go …).
        public var capitalizedTypes = false
        /// `key:` / `key =` at the start of a line (YAML, TOML, INI).
        public var lineKeys = false
        /// `"key":` (JSON).
        public var jsonKeys = false
        /// `<tag` / `</tag>` (HTML, XML).
        public var tags = false
        /// Shell: `$VAR`, `${VAR}`.
        public var variables = false
    }

    // MARK: - Languages

    static let cLike: Set<String> = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "struct", "enum", "union", "typedef", "const", "static", "extern", "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed", "sizeof", "true", "false", "NULL", "nullptr", "class", "public", "private", "protected", "virtual", "template", "typename", "namespace", "using", "new", "delete", "this", "try", "catch", "throw", "include", "define", "auto", "bool", "inline"]

    public static func language(forFileName name: String) -> Language? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        switch lower {
        case "dockerfile", "containerfile": return dockerfile
        case "makefile", "gnumakefile": return shell
        case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".env": return shell
        default: break
        }
        if lower.hasPrefix("dockerfile.") { return dockerfile }
        switch ext {
        case "swift": return swift
        case "py", "pyw": return python
        case "js", "mjs", "cjs", "jsx", "ts", "tsx", "mts": return javascript
        case "go": return go
        case "rs": return rust
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm": return c
        case "java", "kt", "kts", "scala", "groovy", "gradle", "cs", "dart": return java
        case "rb", "rake", "gemspec": return ruby
        case "php": return php
        case "sh", "bash", "zsh", "fish", "ksh", "env", "service", "timer", "socket": return shell
        case "json", "jsonc", "geojson": return json
        case "yml", "yaml": return yaml
        case "toml", "ini", "cfg", "conf", "properties": return toml
        case "html", "htm", "xml", "plist", "svg", "vue", "xhtml": return markup
        case "css", "scss", "less": return css
        case "sql": return sql
        case "lua": return lua
        default: return nil
        }
    }

    /// The language of a Markdown code fence: ```python, ```ts, ```bash, ```dockerfile …
    public static func language(forFence fence: String) -> Language? {
        let name = fence.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").first.map(String.init) ?? ""
        guard !name.isEmpty else { return nil }
        let aliases: [String: String] = [
            "python": "py", "python3": "py", "javascript": "js", "typescript": "ts", "node": "js",
            "bash": "sh", "shell": "sh", "console": "sh", "terminal": "sh", "shellscript": "sh", "zsh": "sh",
            "golang": "go", "rust": "rs", "ruby": "rb", "kotlin": "kt", "csharp": "cs", "c#": "cs", "c++": "cpp",
            "objective-c": "m", "objc": "m", "systemd": "service", "nginx": "conf", "dotenv": "env",
        ]
        if let ext = aliases[name] { return language(forFileName: "f.\(ext)") }
        return language(forFileName: "f.\(name)") ?? language(forFileName: name)
    }

    public static let swift = Language(
        name: "Swift",
        keywords: ["import", "let", "var", "func", "struct", "class", "enum", "protocol", "extension", "actor", "if", "else", "guard", "switch", "case", "default", "for", "in", "while", "repeat", "return", "break", "continue", "throw", "throws", "rethrows", "try", "catch", "do", "defer", "async", "await", "public", "private", "fileprivate", "internal", "open", "static", "final", "override", "mutating", "nonisolated", "init", "deinit", "self", "Self", "super", "nil", "true", "false", "where", "some", "any", "is", "as", "typealias", "associatedtype", "inout", "lazy", "weak", "unowned", "get", "set", "willSet", "didSet", "subscript", "operator", "convenience", "required", "indirect", "consuming", "borrowing", "sending"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], multilineStrings: ["\"\"\""], capitalizedTypes: true)

    public static let python = Language(
        name: "Python",
        keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "global", "nonlocal", "assert", "del", "async", "await", "None", "True", "False", "self", "match", "case"],
        lineComments: ["#"], multilineStrings: ["\"\"\"", "'''"], capitalizedTypes: true)

    public static let javascript = Language(
        name: "JavaScript",
        keywords: ["var", "let", "const", "function", "return", "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "new", "delete", "typeof", "instanceof", "in", "of", "class", "extends", "super", "this", "import", "export", "from", "as", "default", "async", "await", "yield", "try", "catch", "finally", "throw", "null", "undefined", "true", "false", "void", "static", "get", "set", "interface", "type", "enum", "implements", "private", "public", "protected", "readonly", "declare", "namespace", "abstract", "keyof"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], multilineStrings: ["`"], capitalizedTypes: true)

    public static let go = Language(
        name: "Go",
        keywords: ["package", "import", "func", "return", "var", "const", "type", "struct", "interface", "map", "chan", "if", "else", "for", "range", "switch", "case", "default", "break", "continue", "go", "defer", "select", "fallthrough", "goto", "nil", "true", "false", "iota", "make", "new", "len", "cap", "append", "error", "string", "int", "int64", "int32", "uint", "byte", "rune", "bool", "float64", "any"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], multilineStrings: ["`"], capitalizedTypes: true)

    public static let rust = Language(
        name: "Rust",
        keywords: ["fn", "let", "mut", "const", "static", "struct", "enum", "trait", "impl", "for", "in", "if", "else", "match", "loop", "while", "return", "break", "continue", "use", "mod", "pub", "crate", "self", "Self", "super", "as", "where", "move", "ref", "async", "await", "dyn", "unsafe", "extern", "type", "true", "false", "Some", "None", "Ok", "Err"],
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\""], capitalizedTypes: true)

    public static let c = Language(
        name: "C", keywords: cLike, lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], capitalizedTypes: true)

    public static let java = Language(
        name: "Java",
        keywords: cLike.union(["package", "import", "extends", "implements", "interface", "abstract", "final", "synchronized", "instanceof", "null", "fun", "val", "var", "object", "when", "is", "in", "override", "data", "sealed", "companion", "suspend", "def", "string", "record", "yield"]),
        lineComments: ["//"], blockComment: ("/*", "*/"), quotes: ["\"", "'"], multilineStrings: ["\"\"\""], capitalizedTypes: true)

    public static let ruby = Language(
        name: "Ruby",
        keywords: ["def", "end", "class", "module", "if", "elsif", "else", "unless", "case", "when", "while", "until", "for", "in", "do", "return", "yield", "begin", "rescue", "ensure", "raise", "require", "require_relative", "include", "extend", "attr_accessor", "attr_reader", "self", "nil", "true", "false", "and", "or", "not", "then", "puts"],
        lineComments: ["#"], capitalizedTypes: true)

    public static let php = Language(
        name: "PHP",
        keywords: ["function", "return", "if", "else", "elseif", "foreach", "for", "while", "as", "echo", "class", "public", "private", "protected", "static", "new", "use", "namespace", "require", "require_once", "include", "null", "true", "false", "array", "fn", "match", "try", "catch", "throw"],
        lineComments: ["//", "#"], blockComment: ("/*", "*/"), variables: true)

    public static let shell = Language(
        name: "Shell",
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "exit", "export", "local", "readonly", "set", "unset", "source", "echo", "cd", "sudo", "true", "false"],
        lineComments: ["#"], variables: true)

    public static let dockerfile = Language(
        name: "Dockerfile",
        keywords: ["FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS"],
        lineComments: ["#"], variables: true)

    public static let json = Language(name: "JSON", keywords: ["true", "false", "null"], quotes: ["\""], jsonKeys: true)

    public static let yaml = Language(
        name: "YAML", keywords: ["true", "false", "null", "yes", "no", "on", "off"], lineComments: ["#"], lineKeys: true)

    public static let toml = Language(name: "TOML", keywords: ["true", "false"], lineComments: ["#", ";"], lineKeys: true)

    public static let markup = Language(name: "HTML", blockComment: ("<!--", "-->"), quotes: ["\"", "'"], tags: true)

    public static let css = Language(
        name: "CSS", keywords: ["important", "media", "import", "from", "to", "inherit", "none", "auto"],
        blockComment: ("/*", "*/"), quotes: ["\"", "'"])

    public static let sql = Language(
        name: "SQL",
        keywords: Set(["select", "from", "where", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "add", "index", "join", "left", "right", "inner", "outer", "on", "as", "and", "or", "not", "null", "is", "in", "group", "by", "order", "having", "limit", "offset", "primary", "key", "foreign", "references", "unique", "default", "distinct", "union", "all", "case", "when", "then", "else", "end", "begin", "commit", "rollback", "int", "integer", "text", "varchar", "boolean", "timestamp", "serial", "true", "false"].flatMap { [$0, $0.uppercased()] }),
        lineComments: ["--"], blockComment: ("/*", "*/"), quotes: ["'", "\""])

    public static let lua = Language(
        name: "Lua",
        keywords: ["local", "function", "end", "if", "then", "else", "elseif", "for", "in", "do", "while", "repeat", "until", "return", "break", "nil", "true", "false", "and", "or", "not"],
        lineComments: ["--"])

    // MARK: - Scanning

    /// Carried from one line to the next.
    public enum State: Sendable, Hashable {
        case normal
        case blockComment
        case string(String)
    }

    /// Highlights all lines; the state flows from line to line.
    public static func highlight(_ lines: [Substring], language: Language) -> [[Token]] {
        var state = State.normal
        var out: [[Token]] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            let (tokens, next) = highlight(line: line, language: language, state: state)
            out.append(tokens)
            state = next
        }
        return out
    }

    /// Lines longer than this are left plain (minified files).
    public static let maxLineLength = 2000

    public static func highlight(line: Substring, language lang: Language, state start: State) -> ([Token], State) {
        let u = Array(line.utf16)
        guard u.count <= maxLineLength else { return ([], start) }
        var tokens: [Token] = []
        var i = 0
        var state = start
        let quotes = lang.quotes.compactMap { $0.utf16.first }

        func has(_ s: String, at p: Int) -> Bool {
            let su = Array(s.utf16)
            guard p + su.count <= u.count else { return false }
            for k in 0..<su.count where u[p + k] != su[k] { return false }
            return true
        }
        func find(_ s: String, from p: Int) -> Int? {
            var q = p
            while q < u.count { if has(s, at: q) { return q }; q += 1 }
            return nil
        }
        func add(_ kind: Kind, _ from: Int, _ to: Int) {
            guard to > from else { return }
            tokens.append(Token(kind: kind, start: from, length: to - from))
        }
        func isWord(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

        // Continue what the previous line left open.
        switch state {
        case .blockComment:
            guard let close = lang.blockComment?.close else { state = .normal; break }
            if let end = find(close, from: 0) {
                add(.comment, 0, end + close.utf16.count); i = end + close.utf16.count; state = .normal
            } else {
                return ([Token(kind: .comment, start: 0, length: u.count)], state)
            }
        case .string(let delim):
            if let end = find(delim, from: 0) {
                add(.string, 0, end + delim.utf16.count); i = end + delim.utf16.count; state = .normal
            } else {
                return ([Token(kind: .string, start: 0, length: u.count)], state)
            }
        case .normal: break
        }

        // Keys at the start of a line (YAML/TOML/INI): `  name:` or `name =`, also `[section]`.
        if lang.lineKeys && i == 0 {
            var p = 0
            while p < u.count, u[p] == 32 || u[p] == 9 || u[p] == 45 /* - */ { p += 1 }
            if p < u.count, u[p] == 91 /* [ */, let close = find("]", from: p) {
                add(.type, p, close + 1); i = close + 1
            } else {
                var q = p
                while q < u.count, u[q] != 58 /* : */, u[q] != 61 /* = */, u[q] != 35 /* # */, u[q] != 34, u[q] != 39 { q += 1 }
                // `key = value`, or YAML `key: value` / `key:` (a colon inside a value like a URL doesn't count).
                if q < u.count, q > p, u[q] == 61 || (u[q] == 58 && (q + 1 == u.count || u[q + 1] == 32)) {
                    var end = q
                    while end > p, u[end - 1] == 32 { end -= 1 }
                    add(.key, p, end); i = q + 1
                }
            }
        }

        while i < u.count {
            let c = u[i]
            // Comments
            if let open = lang.blockComment?.open, has(open, at: i) {
                let close = lang.blockComment!.close
                if let end = find(close, from: i + open.utf16.count) {
                    add(.comment, i, end + close.utf16.count); i = end + close.utf16.count; continue
                }
                add(.comment, i, u.count); return (tokens, .blockComment)
            }
            if lang.lineComments.contains(where: { has($0, at: i) }) {
                // `#` inside words (e.g. URLs, C# in YAML values) is no comment for # languages: need start or space before.
                let hashLike = u[i] == 35
                if !hashLike || i == 0 || u[i - 1] == 32 || u[i - 1] == 9 {
                    add(.comment, i, u.count); return (tokens, .normal)
                }
            }
            // Strings
            if let delim = lang.multilineStrings.first(where: { has($0, at: i) }) {
                let n = delim.utf16.count
                if let end = findClosing(u, delim: Array(delim.utf16), from: i + n) {
                    add(.string, i, end + n); i = end + n; continue
                }
                add(.string, i, u.count); return (tokens, .string(delim))
            }
            if quotes.contains(c) {
                let q = c
                var p = i + 1
                while p < u.count, u[p] != q {
                    if u[p] == 92 /* \ */ { p += 1 }
                    p += 1
                }
                let end = min(p + 1, u.count)
                // JSON key: string followed by optional spaces and a colon.
                var after = end
                while after < u.count, u[after] == 32 { after += 1 }
                add(lang.jsonKeys && after < u.count && u[after] == 58 ? .key : .string, i, end)
                i = end; continue
            }
            // Tags
            if lang.tags, c == 60 /* < */ {
                var p = i + 1
                if p < u.count, u[p] == 47 || u[p] == 33 || u[p] == 63 { p += 1 } // </ <! <?
                let s = p
                while p < u.count, isWord(u[p]) || u[p] == 45 || u[p] == 58 || u[p] == 46 { p += 1 }
                if p > s { add(.tag, i, p); i = p; continue }
            }
            // Shell-style variables
            if lang.variables, c == 36 /* $ */, i + 1 < u.count {
                var p = i + 1
                if u[p] == 123 /* { */, let close = find("}", from: p) { add(.type, i, close + 1); i = close + 1; continue }
                while p < u.count, isWord(u[p]) { p += 1 }
                if p > i + 1 { add(.type, i, p); i = p; continue }
            }
            // Numbers (not inside words)
            if isDigit(c) && (i == 0 || !isWord(u[i - 1])) {
                var p = i
                while p < u.count, isWord(u[p]) || u[p] == 46 { p += 1 }
                add(.number, i, p); i = p; continue
            }
            // Words: keywords and types
            if isWord(c) {
                var p = i
                while p < u.count, isWord(u[p]) || (lang.name == "CSS" && u[p] == 45) { p += 1 }
                let word = String(utf16CodeUnits: Array(u[i..<p]), count: p - i)
                if lang.keywords.contains(word) {
                    add(.keyword, i, p)
                } else if lang.capitalizedTypes, c >= 65 && c <= 90, word.count > 1 {
                    add(.type, i, p)
                }
                i = p; continue
            }
            i += 1
        }
        return (tokens, .normal)
    }

    /// End of a multi-line string, skipping escaped delimiters.
    private static func findClosing(_ u: [UInt16], delim: [UInt16], from start: Int) -> Int? {
        var p = start
        while p + delim.count <= u.count {
            if u[p] == 92 { p += 2; continue }
            if Array(u[p..<(p + delim.count)]) == delim { return p }
            p += 1
        }
        return nil
    }
}

/// Find in a file: which lines contain the query (case-insensitive), and where.
public enum TextSearch {
    public struct Match: Sendable, Hashable {
        public var line: Int
        /// UTF-16 offset and length inside the line.
        public var start: Int
        public var length: Int
    }

    public static func matches(in lines: [Substring], query: String, limit: Int = 5000) -> [Match] {
        guard !query.isEmpty else { return [] }
        var out: [Match] = []
        for (n, line) in lines.enumerated() {
            var range = line.startIndex..<line.endIndex
            while let r = line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
                let ns = NSRange(r, in: line)
                out.append(Match(line: n, start: ns.location, length: ns.length))
                if out.count >= limit { return out }
                range = r.upperBound..<line.endIndex
                if r.isEmpty { break }
            }
        }
        return out
    }
}
