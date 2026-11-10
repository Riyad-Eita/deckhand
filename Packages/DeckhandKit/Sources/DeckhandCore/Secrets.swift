import Foundation

/// Finds tokens, keys and passwords in command output, so the chat can mask them and the model doesn't get them.
public enum Secrets {
    public struct Match: Sendable, Hashable {
        /// UTF-16 range in the text (for NSString / AttributedString).
        public var range: NSRange
        public var kind: String
    }

    struct Pattern {
        let regex: NSRegularExpression
        let kind: String
        /// Capture group holding the secret (0 = whole match).
        let group: Int
    }

    private static func p(_ pattern: String, _ kind: String, group: Int = 0, options: NSRegularExpression.Options = []) -> Pattern {
        // The patterns are constants; a typo is a programming error caught by the tests.
        Pattern(regex: try! NSRegularExpression(pattern: pattern, options: options), kind: kind, group: group)
    }

    static let patterns: [Pattern] = [
        p(#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#, "private key"),
        p(#"\bsk-ant-[A-Za-z0-9_\-]{20,}"#, "Anthropic key"),
        p(#"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{20,}"#, "OpenAI key"),
        p(#"\bsk-or-v1-[A-Za-z0-9]{32,}"#, "OpenRouter key"),
        p(#"\bgh[pousr]_[A-Za-z0-9]{30,}"#, "GitHub token"),
        p(#"\bgithub_pat_[A-Za-z0-9_]{40,}"#, "GitHub token"),
        p(#"\bglpat-[A-Za-z0-9_\-]{20,}"#, "GitLab token"),
        p(#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, "AWS key"),
        p(#"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#, "Slack token"),
        p(#"\b(?:sk|rk)_live_[A-Za-z0-9]{20,}"#, "Stripe key"),
        p(#"\bAIza[0-9A-Za-z_\-]{35}"#, "Google key"),
        p(#"\bhf_[A-Za-z0-9]{30,}"#, "Hugging Face token"),
        p(#"\bnpm_[A-Za-z0-9]{36}"#, "npm token"),
        p(#"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, "JWT"),
        // scheme://user:password@host — only the password.
        p(#"[a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s:@]+:([^@\s/]{3,})@"#, "password", group: 1),
        // PASSWORD=…, api_key: …, "client_secret": "…", Authorization: Bearer … — only the value.
        p(#"(?:^|[\s{,;"'(]|export\s+)["']?[A-Za-z0-9_.\-]*(?:password|passwd|pwd|secret|token|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|auth)[A-Za-z0-9_.\-]*["']?\s*[:=]\s*["']?([^\s"'#,;}{]{6,})"#,
          "secret", group: 1, options: [.caseInsensitive, .anchorsMatchLines]),
        p(#"(?i)\bauthorization:\s*(?:bearer|basic|token)\s+([A-Za-z0-9._~+/=\-]{8,})"#, "token", group: 1),
    ]

    /// Values that look like settings, not secrets (`PASSWORD_MIN_LENGTH=8` is fine, so are references).
    static func isPlaceholder(_ value: String) -> Bool {
        let v = value.lowercased()
        if v.hasPrefix("$") || v.hasPrefix("{{") || v.hasPrefix("<") || v.hasPrefix("%(") || v.hasPrefix("[redacted") { return true }
        if Set(v).isSubset(of: ["*", "x", "•", "."]) { return true }
        if ["true", "false", "null", "none", "required", "optional", "changeme", "password", "secret", "string",
            "example", "your-token", "your_token", "your-api-key", "your_api_key", "undefined", "yes", "no",
            "enabled", "disabled", "hidden", "redacted", "masked", "env", "prompt", "bearer", "basic"].contains(v) { return true }
        if Int(v) != nil { return true }   // numbers: lengths, ports, timeouts
        return false
    }

    /// All secrets in `text`, sorted and without overlaps.
    public static func find(in text: String) -> [Match] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [Match] = []
        for pattern in patterns {
            for m in pattern.regex.matches(in: text, range: all) {
                let r = m.range(at: pattern.group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                if pattern.group > 0, isPlaceholder(ns.substring(with: r)) { continue }
                found.append(Match(range: r, kind: pattern.kind))
            }
        }
        found.sort { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
        var merged: [Match] = []
        for m in found {
            if let last = merged.last, m.range.location < last.range.location + last.range.length { continue }
            merged.append(m)
        }
        return merged
    }

    /// For the model: each secret becomes `[REDACTED: kind]`.
    public static func redact(_ text: String) -> String {
        replace(text) { "[REDACTED: \($0.kind)]" }
    }

    /// For the screen: each secret becomes dots.
    public static func mask(_ text: String) -> String {
        replace(text) { _ in "••••••••" }
    }

    static func replace(_ text: String, with replacement: (Match) -> String) -> String {
        let matches = find(in: text)
        guard !matches.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for m in matches.reversed() { out.replaceCharacters(in: m.range, with: replacement(m)) }
        return out as String
    }
}
