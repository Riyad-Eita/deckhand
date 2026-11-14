import Foundation

/// How the file browser shows a file: images and PDFs with Quick Look, logs with a live follow, the rest as text.
public enum FilePreview {
    public enum Kind: Sendable, Equatable { case image, pdf, log, text }

    /// Images and PDFs larger than this aren't downloaded for preview.
    public static let maxPreviewBytes: Int64 = 25 * 1024 * 1024

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "ico", "svg"]
    static let logNames: Set<String> = ["syslog", "messages", "kern.log", "auth.log", "dmesg", "daemon.log", "mail.log", "secure"]

    public static func kind(forFileName name: String) -> Kind {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        // access.log, error.log.1, app.log.2024-11-01, syslog, out.txt? no.
        if lower.hasSuffix(".log") || lower.range(of: #"\.log\.\d+$"#, options: .regularExpression) != nil
            || lower.range(of: #"\.log\.\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            || logNames.contains(lower) || logNames.contains(where: { lower.hasPrefix($0 + ".") && !lower.hasSuffix(".gz") }) {
            return .log
        }
        return .text
    }

    /// Follows a log: the last `lines` lines, then every new one, through log rotation (`tail -F`).
    public static func followCommand(_ path: String, lines: Int = 200) -> String {
        "tail -n \(max(1, lines)) -F -- \(ShellQuote.quote(path)) 2>&1"
    }
}
